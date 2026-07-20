import 'package:flutter/foundation.dart';

// Hard-coded defaults — overwritten at startup by RemoteConfigService.
// To change any value without rebuilding: update it in Firebase Console →
// Remote Config, then publish. The app picks it up on next launch.

// ── Agora ────────────────────────────────────────────────────────────────────
const String kDefaultAgoraAppId = 'e1316d8ea2e347ec949f51b32173f319';
const String kDefaultAgoraAppCertificate = ''; // empty = App ID only (Test Mode)
const String kDefaultAgoraChannel = 'my-call-channel-001';

// ── Chat ─────────────────────────────────────────────────────────────────────
const String kDefaultChatRoomId = 'my-chat-room-001';

// ── Call backend ─────────────────────────────────────────────────────────────
// 'agora'  — hosted SFU, billed per minute (10k min/month free tier).
// 'webrtc' — direct peer-to-peer, no per-minute cost (ideal for 2 participants).
// Flip via Remote Config key `call_backend` — no rebuild needed. Anything other
// than 'webrtc' falls back to Agora, so a bad value can't break calling.
const String kDefaultCallBackend = 'agora';

// ── Runtime values (set by RemoteConfigService.init() on startup) ────────────
String agoraAppId = kDefaultAgoraAppId;
String agoraAppCertificate = kDefaultAgoraAppCertificate;
String agoraChannel = kDefaultAgoraChannel;
String chatRoomId = kDefaultChatRoomId;
// If set in Remote Config, this token is used directly (bypasses local builder).
// Paste a valid Agora Console token here to skip client-side HMAC generation.
String agoraToken = '';
// Which media backend calls use — see [kDefaultCallBackend].
String callBackend = kDefaultCallBackend;
// TURN relay for the WebRTC backend. STUN alone connects most networks, but two
// phones on mobile data behind carrier-grade NAT need a relay. Leave empty for
// STUN-only; set via Remote Config (webrtc_turn_url/_username/_credential).
String webrtcTurnUrl = '';
String webrtcTurnUsername = '';
String webrtcTurnCredential = '';

// ── Active call state (used by mini call bar in ChatScreen) ──────────────────
final ValueNotifier<bool> callActiveNotifier = ValueNotifier(false);
bool isCallVideo = false;
bool isCallCaller = false;
String activeCallToken = '';

// ── Per-session (set by DeviceService.initSenderId()) ────────────────────────
String mySenderId = '';

// ── Display ──────────────────────────────────────────────────────────────────
const String myDisplayName = 'You';
const String otherDisplayName = 'Them';

// ── Remote task arrival signal ────────────────────────────────────────────────
// Incremented whenever a remote reminder adds a task to the local todo list,
// so TodoScreen knows to reload from SharedPreferences immediately.
final ValueNotifier<int> todoRefreshNotifier = ValueNotifier(0);
