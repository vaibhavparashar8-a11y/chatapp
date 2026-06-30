// lib/services/encryption_service.dart
//
// End-to-end encryption:
//   • X25519 ECDH key exchange — one key pair per device, stored in Android Keystore
//   • HKDF-SHA256 — derives a stable 256-bit AES key from the X25519 shared secret
//   • AES-256-GCM — authenticated encryption of every message and media file
//
// Flow:
//   1. initialize() — generate/restore key pair, publish public key to Firestore
//   2. ensureReady() / _sharedKeyOnce() — reads the other user's public key from
//      Firestore, runs ECDH + HKDF, caches the resulting AES key in memory.
//   3. All text and media bytes are encrypted before leaving the device.
//      Firebase never sees plaintext.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants.dart';

class EncryptionService {
  // Private key lives in Android Keystore-backed encrypted SharedPreferences.
  static const _store = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kPriv = 'e2ee_priv_v1';
  static const _kPub  = 'e2ee_pub_v1';

  static final _x25519 = X25519();
  static final _aes    = AesGcm.with256bits();
  static final _hkdf   = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  static final _dio    = Dio();

  static SimpleKeyPair? _keyPair;
  static SecretKey?     _sharedKey;

  static DocumentReference get _room =>
      FirebaseFirestore.instance.collection('rooms').doc(chatRoomId);

  // ── Initialisation ──────────────────────────────────────────────────────────

  /// Call once at app start (after Firebase + auth init).
  /// Generates or restores this device's X25519 key pair and publishes the
  /// public key to Firestore so the other user can derive the shared key.
  static Future<void> initialize() async {
    final privB64 = await _store.read(key: _kPriv);
    final pubB64  = await _store.read(key: _kPub);

    if (privB64 != null && pubB64 != null) {
      _keyPair = SimpleKeyPairData(
        base64Decode(privB64),
        publicKey: SimplePublicKey(base64Decode(pubB64), type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    } else {
      _keyPair = await _x25519.newKeyPair();
      final privBytes = await _keyPair!.extractPrivateKeyBytes();
      final pubKey    = await _keyPair!.extractPublicKey();
      await _store.write(key: _kPriv, value: base64Encode(privBytes));
      await _store.write(key: _kPub,  value: base64Encode(pubKey.bytes));
    }

    final pubKey = await _keyPair!.extractPublicKey();
    final publishB64 = base64Encode(pubKey.bytes);
    try {
      await _room.update({'e2eePublicKeys.$mySenderId': publishB64});
    } catch (_) {
      // Room doc doesn't exist yet — create it.
      await _room.set({'e2eePublicKeys': {mySenderId: publishB64}}, SetOptions(merge: true));
    }
  }

  // ── Key derivation ──────────────────────────────────────────────────────────

  static Future<SecretKey> _sharedKeyOnce() async {
    if (_sharedKey != null) return _sharedKey!;

    final otherId = mySenderId == 'A' ? 'B' : 'A';
    final snap = await _room.get();
    final data = (snap.data() as Map<String, dynamic>?) ?? {};
    final keys = (data['e2eePublicKeys'] as Map<String, dynamic>?) ?? {};
    final otherPubB64 = keys[otherId] as String?;

    if (otherPubB64 == null) throw const _KeyNotReadyException();

    final otherPub = SimplePublicKey(
      base64Decode(otherPubB64),
      type: KeyPairType.x25519,
    );
    final rawSecret = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: otherPub,
    );
    _sharedKey = await _hkdf.deriveKey(
      secretKey: rawSecret,
      nonce: [],
      info: utf8.encode('chatapp_e2ee_v1_$chatRoomId'),
    );
    return _sharedKey!;
  }

  // ── Text encryption ─────────────────────────────────────────────────────────

  /// Returns `(ciphertext: base64, iv: base64)`.
  static Future<({String ciphertext, String iv})> encryptText(String plain) async {
    final key = await _sharedKeyOnce();
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: key);
    return (
      ciphertext: base64Encode([...box.cipherText, ...box.mac.bytes]),
      iv: base64Encode(box.nonce),
    );
  }

  /// Decrypts. Returns `'[Encrypted message]'` on any failure (e.g., key not ready).
  static Future<String> decryptText(String ciphertext, String iv) async {
    try {
      final key      = await _sharedKeyOnce();
      final combined = base64Decode(ciphertext);
      final box = SecretBox(
        combined.sublist(0, combined.length - 16),
        nonce: base64Decode(iv),
        mac: Mac(combined.sublist(combined.length - 16)),
      );
      return utf8.decode(await _aes.decrypt(box, secretKey: key));
    } catch (_) {
      return '[Encrypted message]';
    }
  }

  // ── Bytes encryption (media) ────────────────────────────────────────────────

  /// Encrypts raw bytes for upload to Firebase Storage.
  static Future<({Uint8List bytes, String iv})> encryptBytes(Uint8List plain) async {
    final key = await _sharedKeyOnce();
    final box = await _aes.encrypt(plain, secretKey: key);
    return (
      bytes: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      iv: base64Encode(box.nonce),
    );
  }

  /// Decrypts bytes downloaded from Firebase Storage.
  static Future<Uint8List> decryptBytes(Uint8List encrypted, String iv) async {
    final key = await _sharedKeyOnce();
    final box = SecretBox(
      encrypted.sublist(0, encrypted.length - 16),
      nonce: base64Decode(iv),
      mac: Mac(encrypted.sublist(encrypted.length - 16)),
    );
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: key));
  }

  // ── In-memory media cache ───────────────────────────────────────────────────

  static final Map<String, Uint8List> _mediaCache = {};

  /// Download the encrypted blob at [url], decrypt it, and cache by [cacheKey].
  static Future<Uint8List> fetchDecrypted(
    String cacheKey,
    String url,
    String mediaIv,
  ) async {
    final cached = _mediaCache[cacheKey];
    if (cached != null) return cached;

    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final encrypted = Uint8List.fromList(response.data!);
    final decrypted = await decryptBytes(encrypted, mediaIv);
    _mediaCache[cacheKey] = decrypted;
    return decrypted;
  }

  static void evictCache(String cacheKey) => _mediaCache.remove(cacheKey);

  // ── Status ──────────────────────────────────────────────────────────────────

  static bool get isReady => _sharedKey != null;

  /// Try to derive the shared key immediately. Returns true on success.
  static Future<bool> ensureReady() async {
    try {
      await _sharedKeyOnce();
      return true;
    } catch (_) {
      return false;
    }
  }

  static void resetCache() => _sharedKey = null;

  // ── Key rotation detection ─────────────────────────────────────────────────

  /// Called whenever the other user publishes a new public key (e.g. after reinstall).
  /// The controller should re-subscribe to the message stream to force re-decryption.
  static void Function()? onKeyRotated;

  static String? _lastOtherPubKey;
  static StreamSubscription<DocumentSnapshot>? _keyChangeSub;

  /// Watches Firestore for the other person's public key changing.
  /// On change: invalidates the cached shared key so the next encrypt/decrypt
  /// re-derives it from the updated public keys.
  static void listenForKeyChanges() {
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    _keyChangeSub?.cancel();
    _keyChangeSub = _room.snapshots().listen((snap) {
      if (!snap.exists) return;
      final data = (snap.data() as Map<String, dynamic>?) ?? {};
      final keys = (data['e2eePublicKeys'] as Map<String, dynamic>?) ?? {};
      final otherPub = keys[otherId] as String?;
      if (otherPub != null && otherPub != _lastOtherPubKey && _lastOtherPubKey != null) {
        // Other person's key changed — shared secret is now stale.
        _sharedKey = null;
        onKeyRotated?.call();
      }
      if (otherPub != null) _lastOtherPubKey = otherPub;
    });
  }

  static void stopListening() {
    _keyChangeSub?.cancel();
    _keyChangeSub = null;
    onKeyRotated = null;
    _lastOtherPubKey = null;
  }
}

class _KeyNotReadyException implements Exception {
  const _KeyNotReadyException();
  @override
  String toString() => 'E2EE: other user public key not yet available';
}
