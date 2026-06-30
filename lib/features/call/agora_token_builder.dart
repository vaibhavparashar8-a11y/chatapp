// Agora Access Token 2 builder — client-side generation.
// Format verified by decoding an Agora Console-generated temp token:
//   token = "007" + base64(zlib( sigLen(u16) + sig(32) + msg ))
//   msg   = packString(appId) + issueTs(u32) + expireSecs(u32) + salt(u32)
//           + serviceCount(u16)
//           + serviceType(u16) + privCount(u16) + N×(privType(u16)+privExpire(u32))
//           + packString(channelName) + packString(uid)
// packString(s) = u16(len) + UTF-8 bytes
// sig = HMAC-SHA256( HMAC-SHA256(appCert, issueTs||salt), msg )

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class AgoraTokenBuilder {
  static const int _kServiceRtc = 1;
  static const int _kPrivJoinChannel = 1;

  static String buildRtcToken({
    required String appId,
    required String appCertificate,
    required String channelName,
    int uid = 0,
    int expireSecs = 86400 * 30,
  }) {
    final nowTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final salt = Random.secure().nextInt(0x7FFFFFFF) + 1;
    final uidStr = uid == 0 ? '' : uid.toString();

    // Build message (everything after the signature in the content)
    final msg = <int>[
      ..._packStr(appId),
      ..._u32(nowTs),
      ..._u32(expireSecs),
      ..._u32(salt),
      ..._u16(1),               // 1 service
      ..._u16(_kServiceRtc),    // serviceType = RTC
      ..._u16(1),               // 1 privilege
      ..._u16(_kPrivJoinChannel),
      ..._u32(0),               // privExpire = 0 → inherit token lifetime
      ..._packStr(channelName),
      ..._packStr(uidStr),
    ];
    final msgBytes = Uint8List.fromList(msg);

    // signing_key = HMAC-SHA256(appCertificate, issueTs || salt)
    final tsAndSalt = Uint8List.fromList([..._u32(nowTs), ..._u32(salt)]);
    final signingKey = Uint8List.fromList(
      Hmac(sha256, utf8.encode(appCertificate)).convert(tsAndSalt).bytes,
    );

    // signature = HMAC-SHA256(signingKey, msg)
    final sig = Uint8List.fromList(
      Hmac(sha256, signingKey).convert(msgBytes).bytes,
    );

    // content = sigLen(u16) + sig + msg
    final content = Uint8List.fromList([..._u16(sig.length), ...sig, ...msgBytes]);

    // token = "007" + base64(zlib(content))  — appId is INSIDE content, not prepended
    final compressed = ZLibCodec().encode(content);
    return '007${base64Encode(Uint8List.fromList(compressed))}';
  }

  static List<int> _packStr(String s) {
    final b = utf8.encode(s);
    return [..._u16(b.length), ...b];
  }

  static List<int> _u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

  static List<int> _u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
}
