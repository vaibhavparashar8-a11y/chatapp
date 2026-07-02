// lib/services/chat_service.dart

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import '../models/message.dart';
import 'log_service.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;
  static const _uuid = Uuid();

  static CollectionReference get _messages =>
      _db.collection('rooms').doc(chatRoomId).collection('messages');

  /// Real-time stream of the most recent [limit] messages, oldest first.
  static Stream<List<Message>> messagesStream({int limit = 50}) {
    return _messages
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) {
          final out = snap.docs
              .map((d) => _parseMessage(d.data() as Map<String, dynamic>, d.id))
              .toList();
          return out.reversed.toList();
        });
  }

  /// Fetch up to [limit] messages sent before [before], oldest first.
  static Future<List<Message>> fetchOlderMessages(
    DateTime before, {
    int limit = 30,
  }) async {
    final snap = await _messages
        .orderBy('timestamp', descending: true)
        .where('timestamp', isLessThan: Timestamp.fromDate(before))
        .limit(limit)
        .get();
    return snap.docs
        .map((d) => _parseMessage(d.data() as Map<String, dynamic>, d.id))
        .toList()
        .reversed
        .toList();
  }

  static Message _parseMessage(Map<String, dynamic> map, String id) {
    final type = MessageType.values.firstWhere(
      (e) => e.name == (map['type'] ?? 'text'),
      orElse: () => MessageType.text,
    );
    final isMedia = type != MessageType.text;
    // Legacy: messages sent before encryption was removed have an `iv` field.
    // The key pair resets on reinstall so we can't decrypt them — show a label.
    final isLegacyEncrypted = map['iv'] != null;
    final text = isLegacyEncrypted && !isMedia
        ? '\u{1F512} Old encrypted message'
        : (map['text'] as String? ?? '');
    // For legacy encrypted media the filename was stored encrypted in `text`
    // (not in `fileName`), so this will be null — the UI handles that gracefully.
    final fileName = map['fileName'] as String?;

    return Message(
      id: id,
      sender: map['sender'] ?? '',
      text: text,
      type: type,
      mediaUrl: map['mediaUrl'] as String?,
      fileName: fileName,
      fileSize: map['fileSize'] as int?,
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] as dynamic).toDate()
          : DateTime.now(),
      replyToId: map['replyToId'] as String?,
      replyToText: map['replyToText'] as String?,
      replyToSender: map['replyToSender'] as String?,
      clientId: map['clientId'] as String?,
      edited: (map['edited'] as bool?) ?? false,
    );
  }

  static Future<void> sendText(
    String text, {
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    String? clientId,
  }) async {
    final map = <String, dynamic>{
      'sender': mySenderId,
      'type': MessageType.text.name,
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToSender != null) 'replyToSender': replyToSender,
      if (clientId != null) 'clientId': clientId,
    };
    await _messages.add(map);
  }

  static Future<void> sendMedia(
    File file,
    MessageType type, {
    String? fileName,
    void Function(double)? onProgress,
  }) async {
    final rawBytes = await file.readAsBytes();
    final name = fileName ?? file.path.split('/').last;
    LogService.i('Upload', 'Read ${rawBytes.length} bytes');

    final id  = _uuid.v4();
    final ext = name.contains('.') ? name.split('.').last : 'bin';
    final storagePath = 'chats/$chatRoomId/$id.$ext';
    final ref = _storage.ref(storagePath);

    LogService.i('Upload', 'Storage path: $storagePath');
    try {
      final uploadTask = ref.putData(rawBytes);
      uploadTask.snapshotEvents.listen((snap) {
        if (snap.totalBytes > 0) {
          onProgress?.call(snap.bytesTransferred / snap.totalBytes);
        }
      });
      await uploadTask;
      LogService.i('Upload', 'Upload complete');
    } catch (e, st) {
      LogService.e('Upload', 'putData failed: $e\n$st');
      rethrow;
    }

    final url = await ref.getDownloadURL();
    final map = <String, dynamic>{
      'sender': mySenderId,
      'type': type.name,
      'text': '',
      'mediaUrl': url,
      'fileName': name,
      'fileSize': rawBytes.length,
      'timestamp': FieldValue.serverTimestamp(),
    };
    await _messages.add(map);
    LogService.i('Upload', 'Message saved to Firestore');
  }

  static DocumentReference get _room =>
      _db.collection('rooms').doc(chatRoomId);

  static const _clearedAtKey = 'clearedAt';

  /// Call when entering the chat screen — marks this user as present.
  static Future<void> enterChat() async {
    try {
      // update() uses dot-notation so only our own sub-key is touched, never
      // overwriting the other user's presence entry.
      await _room.update({'presence.$mySenderId': true});
    } catch (_) {
      // Room doc doesn't exist yet on first launch — create it.
      try {
        await _room.set({'presence': {mySenderId: true}}, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  /// Call when leaving the chat screen — marks this user as offline and
  /// records the last-seen timestamp so the other side can display it.
  static Future<void> leaveChat() async {
    try {
      await _room.update({
        'presence.$mySenderId': false,
        'lastSeen.$mySenderId': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      LogService.e('ChatService', 'leaveChat failed: $e');
    }
  }

  /// Clear this user's chat view.
  /// Purely local — only this device is affected; the other user sees no change.
  static Future<void> clearMyView() async {
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_clearedAtKey, now.millisecondsSinceEpoch);
  }

  /// Returns the timestamp saved by the last leaveChat() call.
  /// ChatScreen filters messages older than this so the view appears cleared.
  static Future<DateTime?> getClearedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_clearedAtKey);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Update this user's read timestamp so the other side can show blue ticks.
  static Future<void> markRead() async {
    try {
      await _room.update({'readAt.$mySenderId': FieldValue.serverTimestamp()});
    } catch (e) {
      LogService.e('ChatService', 'markRead failed: $e');
    }
  }

  /// Tell Firestore whether this user is currently typing.
  static Future<void> setTyping(bool isTyping) async {
    try {
      await _room.update({'typing.$mySenderId': isTyping});
    } catch (_) {}
  }

  /// Emits the timestamp when the other user last left the chat, or null.
  static Stream<DateTime?> otherLastSeenStream() {
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    return _room.snapshots().map((doc) {
      if (!doc.exists) return null;
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final lastSeen = data['lastSeen'] as Map<String, dynamic>? ?? {};
      final ts = lastSeen[otherId];
      return ts != null ? (ts as dynamic).toDate() as DateTime : null;
    });
  }

  /// Emits true while the other user has the chat screen open.
  static Stream<bool> otherPresenceStream() {
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    return _room.snapshots().map((doc) {
      if (!doc.exists) return false;
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final presence = data['presence'] as Map<String, dynamic>? ?? {};
      return presence[otherId] == true;
    });
  }

  /// Emits true whenever the other user is actively typing.
  static Stream<bool> otherTypingStream() {
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    return _room.snapshots().map((doc) {
      if (!doc.exists) return false;
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final typing = data['typing'] as Map<String, dynamic>? ?? {};
      return typing[otherId] == true;
    });
  }

  /// Stream of the other user's last-read timestamp for tick display.
  static Stream<DateTime?> otherReadAtStream() {
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    return _room.snapshots().map((doc) {
      if (!doc.exists) return null;
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final readAt = data['readAt'] as Map<String, dynamic>? ?? {};
      final ts = readAt[otherId];
      return ts != null ? (ts as dynamic).toDate() as DateTime : null;
    });
  }

  static const _hiddenIdsKey = 'hiddenIds';

  static Future<void> hideMessage(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_hiddenIdsKey}_$chatRoomId';
    final existing = prefs.getStringList(key) ?? [];
    if (!existing.contains(messageId)) {
      existing.add(messageId);
      await prefs.setStringList(key, existing);
    }
  }

  static Future<Set<String>> getHiddenIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('${_hiddenIdsKey}_$chatRoomId') ?? []).toSet();
  }

  static Future<void> editMessage(String messageId, String newText) async {
    await _messages.doc(messageId).update({
      'text': newText,
      'edited': true,
    });
  }

  /// Delete a single message. If it has media, the storage file is removed too.
  static Future<void> deleteMessage(String messageId) async {
    final doc = await _messages.doc(messageId).get();
    if (doc.exists) {
      final data = doc.data() as Map<String, dynamic>;
      if (data['mediaUrl'] != null) {
        try {
          await _storage.refFromURL(data['mediaUrl'] as String).delete();
        } catch (_) {}
      }
    }
    await _messages.doc(messageId).delete();
  }

  // Legacy alias — now clears only this user's local view
  static Future<void> deleteAllMessages() async => clearMyView();

  // token generated by caller is embedded so receiver can use the same one
  static Future<void> signalCall(String callType, {String token = ''}) async {
    await _db.collection('rooms').doc(chatRoomId).set({
      'callSignal': {
        'from': mySenderId,
        'type': callType,
        'status': 'ringing',
        'token': token,
        'timestamp': FieldValue.serverTimestamp(),
      }
    }, SetOptions(merge: true));
  }

  static Future<void> updateCallStatus(String status) async {
    try {
      await _db.collection('rooms').doc(chatRoomId).update({
        'callSignal.status': status,
      });
    } catch (e) {
      LogService.e('ChatService', 'updateCallStatus($status) failed: $e');
    }
  }

  static Stream<Map<String, dynamic>?> callSignalStream() {
    return _db.collection('rooms').doc(chatRoomId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return (doc.data()?['callSignal']) as Map<String, dynamic>?;
    });
  }
}
