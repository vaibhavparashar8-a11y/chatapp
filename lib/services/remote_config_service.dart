import 'package:firebase_remote_config/firebase_remote_config.dart';
import '../constants.dart' as defaults;

class RemoteConfigService {
  static final _rc = FirebaseRemoteConfig.instance;

  static Future<void> init() async {
    // Defaults: if Firebase is unreachable, fall back to these
    await _rc.setDefaults({
      'agora_app_id': defaults.kDefaultAgoraAppId,
      'agora_app_certificate': '',
      'agora_channel': defaults.kDefaultAgoraChannel,
      'chat_room_id': defaults.kDefaultChatRoomId,
      'agora_token': '', // paste a console-generated temp token here to enable calls
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

    // Push fetched values into the runtime constants
    defaults.agoraAppId = _rc.getString('agora_app_id');
    defaults.agoraAppCertificate = _rc.getString('agora_app_certificate');
    defaults.agoraChannel = _rc.getString('agora_channel');
    defaults.chatRoomId = _rc.getString('chat_room_id');
    defaults.agoraToken = _rc.getString('agora_token');
  }
}
