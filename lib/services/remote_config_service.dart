import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import '../constants.dart' as defaults;
import 'log_service.dart';

class RemoteConfigService {
  static final _rc = FirebaseRemoteConfig.instance;

  // Set to true in tests to skip all Firebase calls.
  static bool testMode = false;

  // Returns the todo input text color from Remote Config.
  // Set 'todo_input_text_color' in Firebase Console as a hex string, e.g. #ADADAD.
  // Change it there and restart the app — no rebuild needed.
  static Color get todoInputTextColor {
    if (testMode) return const Color(0xFFADADAD);
    final raw = _rc.getString('todo_input_text_color').trim().replaceAll('#', '');
    if (raw.length == 6) {
      final value = int.tryParse(raw, radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return const Color(0xFFADADAD); // default: low-contrast gray
  }

  static Future<void> init() async {
    // Defaults: if Firebase is unreachable, fall back to these
    await _rc.setDefaults({
      'agora_app_id': defaults.kDefaultAgoraAppId,
      'agora_app_certificate': '',
      'agora_channel': defaults.kDefaultAgoraChannel,
      'chat_room_id': defaults.kDefaultChatRoomId,
      'agora_token': '', // paste a console-generated temp token here to enable calls
      // 'agora' (default) or 'webrtc' — swap the call backend without a rebuild.
      'call_backend': defaults.kDefaultCallBackend,
      // TURN relay for the WebRTC backend (empty = STUN only). Needed when both
      // phones are on mobile data behind carrier-grade NAT.
      'webrtc_turn_url': '',
      'webrtc_turn_username': '',
      'webrtc_turn_credential': '',
      'todo_input_text_color': '#ADADAD',
      'enable_firestore_logging': false, // off by default — enable remotely to debug
    });

    await _rc.setConfigSettings(RemoteConfigSettings(
      fetchTimeout: const Duration(seconds: 10),
      minimumFetchInterval: Duration.zero, // always fetch fresh on startup
    ));

    try {
      await _rc.fetchAndActivate();
    } catch (_) {
      // use defaults if offline
    }

    // Push fetched values into runtime constants — fall back to code defaults
    // if Remote Config returns an empty string (key exists but value is blank).
    final appId = _rc.getString('agora_app_id');
    final channel = _rc.getString('agora_channel');
    final roomId = _rc.getString('chat_room_id');
    defaults.agoraAppId = appId.isNotEmpty ? appId : defaults.kDefaultAgoraAppId;
    defaults.agoraAppCertificate = _rc.getString('agora_app_certificate');
    defaults.agoraChannel = channel.isNotEmpty ? channel : defaults.kDefaultAgoraChannel;
    defaults.chatRoomId = roomId.isNotEmpty ? roomId : defaults.kDefaultChatRoomId;
    defaults.agoraToken = _rc.getString('agora_token'); // empty = no token (App ID only mode)
    final backend = _rc.getString('call_backend').trim().toLowerCase();
    defaults.callBackend =
        backend.isNotEmpty ? backend : defaults.kDefaultCallBackend;
    defaults.webrtcTurnUrl = _rc.getString('webrtc_turn_url').trim();
    defaults.webrtcTurnUsername = _rc.getString('webrtc_turn_username').trim();
    defaults.webrtcTurnCredential =
        _rc.getString('webrtc_turn_credential').trim();
    LogService.firestoreLoggingEnabled = _rc.getBool('enable_firestore_logging');
    LogService.i('RemoteConfig', 'call_backend=${defaults.callBackend}');
  }
}
