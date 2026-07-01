# ChatApp — Developer Guide

A two-person real-time chat application built with Flutter, Firebase, and Agora RTC.  
This guide covers every module with code examples, data flow diagrams, and runnable recipes.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Quick Start](#2-quick-start)
3. [Architecture](#3-architecture)
4. [Firestore Schema](#4-firestore-schema)
5. [Module Reference](#5-module-reference)
6. [Data Flow Diagrams](#6-data-flow-diagrams)
7. [Common Issues & Fixes](#7-common-issues--fixes)
8. [Enhancement Guide](#8-enhancement-guide)
9. [Testing Guide](#9-testing-guide)
10. [Build & Release](#10-build--release)

---

## 1. Project Overview

A private, two-person mobile chat app. Both users install the same APK; the app auto-assigns them roles (A and B) via a Firestore transaction on first launch. No backend servers — Firebase handles everything.

### Tech Stack

| Layer | Technology | Version |
|---|---|---|
| UI framework | Flutter | 3.44.3 |
| Language | Dart | 3.12.2 |
| Realtime database | Firebase Firestore | SDK 5.x |
| File storage | Firebase Storage | SDK 12.x |
| Authentication | Firebase Auth (anonymous) | SDK 5.x |
| Runtime config | Firebase Remote Config | SDK 5.x |
| Audio/video calls | Agora RTC Engine | 6.3.x |
| Local storage | SharedPreferences | — |
| HTTP client | Dio | — |
| Platform | Android (arm64-v8a) | minSdk 21 |

### Two-Role System

Both users install an identical APK. On first launch each device runs a Firestore transaction that claims either slot **A** or slot **B** in `rooms/{chatRoomId}/roleAssignments`. The assigned role is cached in `SharedPreferences` and reused on every subsequent launch.

- `mySenderId` = `'A'` or `'B'` — set globally by `DeviceService.initSenderId()`
- The role never changes unless the user calls `DeviceService.resetAssignments()` or clears app data

---

## 2. Quick Start

### Prerequisites

- Flutter SDK 3.44+ (`flutter --version`)
- Android SDK / Android Studio (for device/emulator)
- A Firebase project with Firestore, Storage, Auth, and Remote Config enabled
- (Optional) Agora account + App ID for audio/video calls

### Firebase Setup

1. Create a project at <https://console.firebase.google.com>
2. Add an Android app — package name `com.example.chatapp`
3. Download `google-services.json` → place it at `android/app/google-services.json`
4. **Never commit this file.** It is listed in `.gitignore`.

### Firestore Security Rules (minimal for dev)

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if request.auth != null;
    }
  }
}
```

### Remote Config Keys

Set these in Firebase Console → Remote Config → Add parameter:

| Key | Default | Purpose |
|---|---|---|
| `agora_app_id` | (your App ID) | Identifies your Agora project |
| `agora_app_certificate` | `""` | Leave empty for Test Mode (no token required) |
| `agora_channel` | `my-call-channel-001` | Both users must share the same channel |
| `chat_room_id` | `my-chat-room-001` | Firestore document path segment |
| `agora_token` | `""` | Paste a temp token from Agora Console to enable calls |

### Build & Run

```powershell
# From D:\Projects\chatapp
.\build_release.ps1        # produces build\app\outputs\flutter-apk\MyTask.apk (~105 MB)
```

Or for development:
```powershell
$env:GRADLE_USER_HOME = "D:\gradle"
$env:PUB_CACHE = "D:\pub-cache"
flutter run
```

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────┐
│                      UI Layer                         │
│  TodoScreen → ChatScreen (+ part files) → CallScreen  │
│  MessageBubble · MediaViewerScreen · LogScreen        │
├──────────────────────────────────────────────────────┤
│                  Controller Layer                     │
│              ChatController (ChangeNotifier)          │
│  All business logic — knows nothing about Firebase    │
├──────────────────────────────────────────────────────┤
│                 Repository Layer                      │
│  IChatRepository (abstract interface)                 │
│  └── FirebaseChatRepository (adapter)                 │
├──────────────────────────────────────────────────────┤
│                  Service Layer                        │
│  ChatService · DeviceService · LogService             │
│  RemoteConfigService · NotificationService            │
│  CallService · AgoraTokenBuilder                      │
├──────────────────────────────────────────────────────┤
│              Firebase / Agora SDKs                    │
│  Firestore · Storage · Auth · Remote Config · RTC     │
└──────────────────────────────────────────────────────┘
```

### Dependency Injection

`ChatScreen` creates `FirebaseChatRepository` and passes it to `ChatController`.  
`ChatController` only talks to `IChatRepository` — it cannot import Firebase directly.

```dart
// In ChatScreen.initState()
final repo = FirebaseChatRepository();
_controller = ChatController(repo, onUploadError: _showSnackBar);
await _controller.init();
```

To swap the backend (e.g. for tests), pass a different `IChatRepository` implementation.

---

## 4. Firestore Schema

```
rooms/
└── {chatRoomId}                         ← single shared document
    ├── presence/
    │   ├── A: bool                      ← true = user A has chat screen open
    │   └── B: bool
    ├── typing/
    │   ├── A: bool                      ← true = user A is currently typing
    │   └── B: bool
    ├── readAt/
    │   ├── A: Timestamp                 ← when A last called markRead()
    │   └── B: Timestamp                 ← used to show blue ticks on B's messages
    ├── lastSeen/
    │   ├── A: Timestamp                 ← set by leaveChat()
    │   └── B: Timestamp                 ← shown as "Last seen HH:MM" in app bar
    ├── roleAssignments/
    │   ├── A: "device-uuid-A"           ← stable device UUID (SharedPreferences)
    │   └── B: "device-uuid-B"
    └── callSignal/
        ├── from: "A" | "B"
        ├── type: "audio" | "video"
        ├── status: "ringing" | "accepted" | "declined" | "ended"
        ├── token: string                ← Agora RTC token (may be empty in Test Mode)
        └── timestamp: Timestamp

rooms/{chatRoomId}/messages/
└── {auto-id}                            ← one document per message
    ├── sender: "A" | "B"               ← who sent it
    ├── type: "text"|"image"|"video"
    │        |"audio"|"file"|"gif"
    ├── text: string                     ← plaintext body (or "" for media)
    ├── mediaUrl: string?                ← Firebase Storage download URL
    ├── fileName: string?                ← original filename for files
    ├── fileSize: number?                ← bytes
    ├── timestamp: Timestamp             ← server-side (FieldValue.serverTimestamp())
    ├── clientId: string?                ← "pending_<microseconds>" for optimistic UI
    ├── edited: bool                     ← true after editMessage()
    ├── replyToId: string?               ← message ID being replied to
    ├── replyToText: string?             ← preview text of the quoted message
    ├── replyToSender: string?           ← "A" | "B" for quote styling
    └── iv: string?                      ← LEGACY ONLY — presence means the message
                                            was sent by the old encrypted app.
                                            New app never writes this field.

app_logs/
└── {auto-id}
    ├── device: string                   ← UUID from DeviceService.deviceId
    ├── level: "INFO"|"WARN"|"ERROR"
    ├── tag: string                      ← e.g. "Upload", "Call"
    ├── message: string
    └── time: Timestamp
```

---

## 5. Module Reference

### `lib/main.dart`

Entry point. Startup runs in this order — order matters due to dependencies:

```
1. WidgetsFlutterBinding.ensureInitialized()
2. Firebase.initializeApp()
3. [parallel] FirebaseAuth.signInAnonymously()  +  RemoteConfigService.init()
4. DeviceService.initSenderId()    ← needs auth for Firestore transaction
5. LogService.setDeviceId(...)     ← needs device ID from step 4
6. NotificationService.init()
7. runApp(TasksApp())
```

**How to add a new init step:**

```dart
// In main() after DeviceService.initSenderId():
await MyNewService.init();
```

Auth and Remote Config are parallelized with `Future.wait`. Any new service that requires auth must go after `DeviceService.initSenderId()`.

---

### `lib/constants.dart`

Runtime globals. Hard-coded defaults that are overwritten by `RemoteConfigService.init()` at startup.

```dart
// Hard-coded defaults — changed by Remote Config on next launch
String agoraAppId = kDefaultAgoraAppId;   // writable global
String chatRoomId = kDefaultChatRoomId;

// Call state notifier — listen anywhere without a BuildContext
final ValueNotifier<bool> callActiveNotifier = ValueNotifier(false);

// Set by DeviceService — available globally after main()
String mySenderId = '';  // 'A' or 'B'
```

**Override a value via Remote Config without rebuilding:**

1. Firebase Console → Remote Config → Add parameter `chat_room_id`
2. Set value to `my-new-room-002` → Publish
3. Next app launch fetches it and `chatRoomId` is updated

---

### `lib/models/message.dart`

Plain Dart data class. No Firebase imports.

**`MessageType` enum:**

| Value | UI behavior |
|---|---|
| `text` | Rendered as a text bubble |
| `image` | `EncryptedImage` widget with tap-to-fullscreen |
| `video` | `BubbleVideoPlayer` with play button |
| `audio` | `AudioTile` with waveform player |
| `file` | `DownloadButton` + filename + size |
| `gif` | Same as image but loops |

**Parsing a Firestore document manually:**

```dart
final doc = await FirebaseFirestore.instance
    .collection('rooms')
    .doc('my-chat-room-001')
    .collection('messages')
    .doc('someId')
    .get();

final msg = Message.fromMap(doc.data()!, doc.id);
print(msg.type);   // MessageType.text
print(msg.sender); // 'A' or 'B'
```

**Legacy encrypted message detection** — the `iv` field:

```dart
// In chat_service.dart _parseMessage()
final isLegacyEncrypted = map['iv'] != null;
final text = isLegacyEncrypted && !isMedia
    ? '\u{1F512} Old encrypted message'
    : (map['text'] as String? ?? '');
```

Old messages written by the previous app version store AES-GCM ciphertext in `text` and a base64 nonce in `iv`. The key was ephemeral and is now gone — so they are irrecoverable. The `iv` field is detected and replaced with a lock-icon label.

---

### `lib/services/chat_service.dart`

All Firestore and Storage operations — only static methods, no instance state.

**Key methods:**

| Method | What it does |
|---|---|
| `messagesStream({int limit})` | Real-time stream, newest 50, oldest-first |
| `fetchOlderMessages(DateTime before)` | One-shot fetch for pagination |
| `sendText(text, {replyToId, clientId, ...})` | Writes plaintext document |
| `sendMedia(File, MessageType, {onProgress})` | Uploads to Storage, then writes Firestore doc |
| `markRead()` | Updates `readAt.{mySenderId}` on the room doc |
| `setTyping(bool)` | Updates `typing.{mySenderId}` on the room doc |
| `enterChat()` / `leaveChat()` | Sets `presence` and `lastSeen` |
| `signalCall(type, {token})` | Writes `callSignal` map to room doc |
| `updateCallStatus(status)` | Updates `callSignal.status` |
| `editMessage(id, newText)` | Updates `text` and sets `edited: true` |
| `deleteMessage(id)` | Deletes Firestore doc + Storage file if media |

**Send a text message with a reply:**

```dart
await ChatService.sendText(
  'Got it!',
  replyToId: 'abc123',
  replyToText: '[Image]',
  replyToSender: 'A',
  clientId: 'pending_${DateTime.now().microsecondsSinceEpoch}',
);
```

**Upload with progress:**

```dart
await ChatService.sendMedia(
  File('/path/to/video.mp4'),
  MessageType.video,
  fileName: 'video.mp4',
  onProgress: (p) => setState(() => _progress = p),  // 0.0 → 1.0
);
```

**Signal an incoming call:**

```dart
await ChatService.signalCall('video', token: agoraToken);
// On the other device, callSignalStream() emits the new map.
// Receiver shows IncomingCallDialog.
```

---

### `lib/services/device_service.dart`

Assigns and persists the A/B role. Called once in `main()`.

**Role assignment algorithm (Firestore transaction):**

```
1. Read roleAssignments from room doc
2. Is my deviceId already in slot A? → return 'A'
3. Is my deviceId already in slot B? → return 'B'
4. Is slot A free? → claim A
5. Is slot B free? → claim B
6. Both taken (reinstall scenario) → overwrite B, return 'B'
```

The entire check-and-write runs in a single atomic Firestore transaction — two simultaneous installs cannot both claim A.

**Reset both roles (e.g., after reinstalling on both devices):**

```dart
await DeviceService.resetAssignments();
// Then relaunch both devices. Launch A first to claim slot A.
```

---

### `lib/services/log_service.dart`

Structured logging — writes to in-memory buffer AND to Firestore `app_logs/`.  
`LogScreen` reads the in-memory buffer; Firestore logs are queryable remotely.

```dart
LogService.i('Upload', 'Read 204800 bytes');   // INFO
LogService.w('Call',   'Token missing');        // WARN
LogService.e('Upload', 'putData failed: ...');  // ERROR
```

**Query device logs from Firestore (e.g., Firestore Console or a script):**

```javascript
// Firebase Console → Firestore → app_logs
// Filter: device == "your-device-uuid" AND level == "ERROR"
// Order by: time DESC
```

**Listen to live logs in-app:**

```dart
ValueListenableBuilder<int>(
  valueListenable: LogService.notifier,
  builder: (_, __, ___) => ListView(
    children: LogService.logs.reversed
        .map((e) => Text(e.toString()))
        .toList(),
  ),
);
```

---

### `lib/services/remote_config_service.dart`

Fetches Firebase Remote Config on every startup (`minimumFetchInterval: Duration.zero`).  
Falls back to hard-coded defaults if offline.

**Add a new Remote Config key:**

```dart
// 1. Add a constant default in constants.dart:
String myFeatureFlag = 'off';

// 2. Add to RemoteConfigService.init() setDefaults():
await _rc.setDefaults({
  ...existingDefaults,
  'my_feature_flag': 'off',
});

// 3. After fetchAndActivate(), read it:
myFeatureFlag = _rc.getString('my_feature_flag');
```

---

### `lib/utils/time_utils.dart`

Shared time-formatting helpers extracted so they can be unit-tested independently of any Flutter widget.

| Function | Purpose |
|---|---|
| `formatLastSeen(DateTime ts)` | Formats chat app-bar subtitle — "just now", "today at HH:MM", "yesterday at HH:MM", "DD/MM at HH:MM" |
| `formatDue(DateTime dt)` | Formats to-do tile subtitle — "Due today/tomorrow/DD/MM at HH:MM", "Was due ..." for overdue |

**Key invariant** — both functions compare **calendar days**, not elapsed hours:

```dart
final today = DateTime(now.year, now.month, now.day);
final calendarDiff = today.difference(DateTime(ts.year, ts.month, ts.day)).inDays;
```

This fixes the issue where 22:00 yesterday seen at 08:00 today (10 h elapsed, `inDays == 0`) was displayed as "today".

---

### `lib/repositories/i_chat_repository.dart`

Abstract interface — `ChatController` only ever imports this file.

```dart
abstract class IChatRepository {
  Stream<List<Message>> messagesStream({int limit = 50});
  Future<void> sendText(String text, {String? replyToId, String? clientId, ...});
  Future<void> sendMedia(File file, MessageType type, {void Function(double)? onProgress, ...});
  Future<void> markRead();
  Future<void> enterChat();
  Future<void> leaveChat();
  Future<List<Message>> fetchOlderMessages(DateTime before, {int limit = 30});
  Future<void> editMessage(String messageId, String newText);
  Future<void> deleteMessage(String messageId);
  // ... (see file for full contract)
}
```

**Write a mock for unit tests:**

```dart
class FakeChatRepository implements IChatRepository {
  final _controller = StreamController<List<Message>>.broadcast();
  bool throwOnSend = false;
  int sendCount = 0;

  void emit(List<Message> msgs) => _controller.add(msgs);

  @override
  Stream<List<Message>> messagesStream({int limit = 50}) => _controller.stream;

  @override
  Future<void> sendText(String text, {String? replyToId, String? clientId,
      String? replyToText, String? replyToSender}) async {
    sendCount++;
    if (throwOnSend) throw Exception('network error');
  }

  @override Future<void> markRead() async {}
  @override Future<void> enterChat() async {}
  @override Future<void> leaveChat() async {}
  // ... implement remaining methods as no-ops or stubs
}
```

---

### `lib/controllers/chat_controller.dart`

All chat business logic. Owns five stream subscriptions and the message list.

**State managed:**

| Field | Type | Purpose |
|---|---|---|
| `_streamMessages` | `List<Message>` | Latest 50 from Firestore stream |
| `_olderMessages` | `List<Message>` | Prepended via `loadMoreMessages()` |
| `_pendingEntries` | `List<_PendingEntry>` | Optimistic / failed messages |
| `_otherReadAt` | `DateTime?` | Drives blue tick display |
| `_otherTyping` | `bool` | Drives typing indicator |
| `_otherOnline` | `bool` | Drives "Online" in app bar |

**Optimistic UI flow:**

```
1. sendText() called
2. _PendingEntry added to _pendingEntries → notifyListeners() → message appears instantly
3. repo.sendText() writes to Firestore (async)
4. Firestore stream emits updated list with clientId on the new doc
5. _subscribeMessages() removes matching _PendingEntry → pending indicator disappears
```

**Debounced read receipt:**

```dart
void _scheduleMarkRead() {
  _markReadTimer?.cancel();
  _markReadTimer = Timer(const Duration(milliseconds: 500), _repo.markRead);
}
```

Called on every stream emission where the other person has messages. At most one Firestore write per 500 ms regardless of how many messages arrive.

**Pagination trigger** (from `ChatScreen`'s scroll controller):

```dart
_scrollController.addListener(() {
  if (_scrollController.position.pixels <= 200) {
    _controller.loadMoreMessages();
  }
});
```

**Edit/delete permission check:**

```dart
// Only your own messages, sent within the last hour
if (ChatController.canModify(msg)) {
  // show edit / delete options
}
```

---

### `lib/screens/chat_screen.dart` and part files

`ChatScreen` is split using Dart `part`/`part of` into four files to keep each under ~300 lines:

| Part file | Responsibility |
|---|---|
| `chat_screen.dart` | State class, lifecycle, `build()` scaffold |
| `screens/chat/load_more_indicator.dart` | Scroll-triggered history loader |
| `screens/chat/attach_option.dart` | Attach menu item widget |
| `screens/chat/typing_indicator.dart` | Three-dot animated bubble |
| `screens/chat/floating_video_overlay.dart` | Minimized call pip overlay |

**Widget tree (simplified):**

```
ChatScreen (StatefulWidget)
├── Scaffold
│   ├── AppBar (presence, typing, last-seen)
│   ├── Body: Column
│   │   ├── FloatingVideoOverlay (if call active)
│   │   ├── ListView (messages + load-more at top)
│   │   │   └── MessageBubble × N
│   │   └── TypingIndicator (if otherTyping)
│   └── BottomBar
│       ├── ReplyPreview (if replyingTo != null)
│       ├── TextField
│       └── Send / Attach buttons
└── IncomingCallDialog (overlay, shown by callSignalStream)
```

**Lifecycle hooks:**

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _controller.enter();          // marks presence, fires markRead
    _surfaceKey = UniqueKey();    // forces AgoraVideoView reconstruction (see §5.10)
  } else if (state == AppLifecycleState.paused) {
    _controller.leave();          // marks offline, clears typing
  }
}
```

---

### `lib/widgets/message_bubble.dart` and bubble parts

`MessageBubble` dispatches to the correct content widget based on `msg.type`:

```dart
Widget _buildContent(Message msg) {
  switch (msg.type) {
    case MessageType.text:  return _TextContent(msg);
    case MessageType.image: return EncryptedImage(url: msg.mediaUrl!);
    case MessageType.video: return BubbleVideoPlayer(url: msg.mediaUrl!);
    case MessageType.audio: return AudioTile(url: msg.mediaUrl!);
    case MessageType.gif:   return EncryptedImage(url: msg.mediaUrl!, isGif: true);
    case MessageType.file:  return DownloadButton(msg: msg);
  }
}
```

**Swipe to reply** — gesture threshold:

```dart
GestureDetector(
  onHorizontalDragUpdate: (d) {
    _dragOffset += d.delta.dx;
    if (_dragOffset > 40 && !_triggered) {
      _triggered = true;
      HapticFeedback.lightImpact();
      widget.onReply();
    }
  },
)
```

**Status icon logic** (sent messages only):

```dart
// Single grey tick = sent but not read
// Double blue tick = other user has called markRead() after this message's timestamp
Icon _statusIcon(Message msg, DateTime? otherReadAt) {
  if (otherReadAt != null && msg.timestamp.isBefore(otherReadAt)) {
    return const Icon(Icons.done_all, color: Colors.blue, size: 14);
  }
  return const Icon(Icons.done, color: Colors.grey, size: 14);
}
```

---

### `lib/features/call/`

| File | Responsibility |
|---|---|
| `call_service.dart` | Singleton Agora RTC engine — join/leave/mute/camera |
| `call_screen.dart` | Full-screen call UI with timer, mute/camera buttons |
| `incoming_call_dialog.dart` | Bottom-sheet shown when `callSignal.status == 'ringing'` |
| `agora_token_builder.dart` | Client-side HMAC-SHA256 token builder (Test Mode fallback) |

**Token priority chain** (in `CallScreen._joinCall()`):

```
1. agoraToken from Remote Config (non-empty)  → use directly
2. agoraAppCertificate from Remote Config (non-empty) → build token locally with HMAC
3. Neither set → join with empty token (Agora Test Mode — App ID only)
```

**Minimize / restore call:**

```dart
// User taps minimize button in CallScreen
callActiveNotifier.value = true;   // triggers FloatingVideoOverlay in ChatScreen
Navigator.pop(context);            // pops CallScreen

// CallService._engine is NOT released — engine singleton survives screen pop
// FloatingVideoOverlay renders AgoraVideoView using the same running engine

// User taps restore in FloatingVideoOverlay
callActiveNotifier.value = false;
Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen()));
// CallScreen.initState() calls CallService.updateCallbacks(...) — no re-join needed
```

**AgoraVideoView blank-screen fix:**

```dart
// In ChatScreen._onLifecycleResumed():
_surfaceKey = UniqueKey();   // forces widget tree to dispose+recreate AgoraVideoView
// The platform view's SurfaceTexture goes stale after backgrounding on Android.
// Recreating the widget from scratch re-attaches it to the running engine.
```

---

## 6. Data Flow Diagrams

### 6.1 Message Send (Optimistic)

```
User types "Hello" → taps Send
        │
        ▼
ChatController.sendText("Hello")
        │
        ├─ Creates _PendingEntry{clientId: "pending_123", failed: false}
        ├─ _pendingEntries.add(entry)
        ├─ notifyListeners()             ← message appears instantly in UI
        │
        └─ repo.sendText("Hello", clientId: "pending_123")
                │
                ▼
         Firestore write
         messages/{new-id} = {text: "Hello", clientId: "pending_123", ...}
                │
                ▼
         messagesStream() emits updated list
                │
                ▼
         _subscribeMessages() sees clientId "pending_123" in confirmed list
                │
                └─ _pendingEntries.remove(entry)
                   notifyListeners()      ← pending indicator removed
```

### 6.2 Media Send

```
User picks file (image/video/audio/file)
        │
        ▼
ChatController.sendMedia(file, MessageType.image)
        │
        ├─ _uploadProgress = 0.0 → notifyListeners() (progress bar appears)
        │
        └─ repo.sendMedia(file, type, onProgress: (p) { _uploadProgress = p; notifyListeners(); })
                │
                ├─ file.readAsBytes() → rawBytes
                ├─ Storage.ref("chats/{roomId}/{uuid}.jpg").putData(rawBytes)
                │       snapshotEvents → onProgress(bytesTransferred / totalBytes)
                ├─ ref.getDownloadURL() → mediaUrl
                └─ messages.add({type: "image", mediaUrl: url, fileSize: N, ...})
                        │
                        ▼
                 _uploadProgress = null → notifyListeners() (progress bar hides)
```

### 6.3 Read Receipt (Blue Ticks)

```
New message arrives from B
        │
        ▼
ChatService.messagesStream() emits new list
        │
        ▼
_subscribeMessages() runs:
  if (msgs.any((m) => m.sender == otherId)) _scheduleMarkRead()
        │
        ▼
_scheduleMarkRead():
  cancel existing 500ms timer
  start new 500ms timer → repo.markRead()
        │
        ▼
ChatService.markRead():
  room.update({'readAt.A': FieldValue.serverTimestamp()})
        │
        ▼
otherReadAtStream() on B's device emits new DateTime
        │
        ▼
ChatController._readAtSub:
  _otherReadAt = newTimestamp → notifyListeners()
        │
        ▼
MessageBubble._statusIcon():
  msg.timestamp.isBefore(otherReadAt) → Icon(Icons.done_all, color: Colors.blue)
```

### 6.4 Incoming Call

```
A taps "Video Call"
        │
        ▼
ChatService.signalCall('video', token: agoraToken)
  room.set({callSignal: {from:'A', type:'video', status:'ringing', token: ...}})
        │
        ▼ (on B's device)
callSignalStream() emits {status: 'ringing'}
        │
        ▼
ChatScreen listener shows IncomingCallDialog
        │
   ┌────┴────┐
   │Accept   │Decline
   ▼         ▼
updateCallStatus('accepted')    updateCallStatus('declined')
Navigator.push(CallScreen)      dialog dismissed
        │
        ▼ (on A's device)
callSignalStream() emits {status: 'accepted'}
A's CallScreen._awaitAccept() unblocks → joins Agora channel
        │
        ▼
Both devices: CallService.joinCall(videoEnabled, token, ...)
Agora onUserJoined fires → video/audio streams active
```

### 6.5 App Startup

```
main()
  │
  ├─ Firebase.initializeApp()
  │
  ├─ [parallel] signInAnonymously() + RemoteConfigService.init()
  │       RemoteConfig fetches: agoraAppId, chatRoomId, agoraToken, ...
  │       Overwrites globals in constants.dart
  │
  ├─ DeviceService.initSenderId()
  │       SharedPreferences has saved role? → use it (fast path)
  │       No saved role → Firestore transaction → claim 'A' or 'B'
  │       mySenderId = 'A' or 'B'
  │
  ├─ LogService.setDeviceId(DeviceService.deviceId)
  │
  ├─ NotificationService.init()
  │
  └─ runApp(TasksApp()) → MaterialApp → TodoScreen → ChatScreen
```

---

## 7. Common Issues & Fixes

| Symptom | Root Cause | Fix |
|---|---|---|
| Messages show base64 text | Old APK with encryption still installed | Uninstall old APK on both devices; reinstall `MyTask.apk` |
| Messages show "🔒 Old encrypted message" | Legacy Firestore docs have `iv` field; key is gone | Expected behavior — these messages are irrecoverable |
| `e2eePublicKeys` updating in Firestore | Old APK's `EncryptionService.initialize()` still running | Force-uninstall old app; new app has no encryption init |
| Single tick permanently, no blue tick | (Fixed) Was: `limit(50)` sliding window reduced `otherCount` | Now: controller calls `markRead()` on any stream emit |
| Last seen shows "today" for yesterday's timestamp | `diff.inDays` counts 24-hour periods, not calendar days | Fixed: strip time components and compare calendar dates in `formatLastSeen()` |
| Both devices get role 'B' | Both reinstalled simultaneously — race condition | Call `DeviceService.resetAssignments()` on one device, relaunch A first then B |
| APK is 260 MB | Building fat APK (`flutter build apk`) | Use `.\build_release.ps1` — passes `--split-per-abi`; arm64 APK = ~105 MB |
| Video overlay blank after minimize | Platform view surface goes stale on Android | `_surfaceKey = UniqueKey()` on `AppLifecycleState.resumed` forces AgoraVideoView reconstruction |
| R8 build warning about "split" classes | Missing ProGuard dontwarn for Play Core split classes | Already in `android/app/proguard-rules.pro` — warning is harmless |
| Call ends immediately, no remote user | 45-second timeout fired before other user accepted | Other user must accept before timeout; check `callSignal.status` in Firestore Console |
| `flutter test` fails after `flutter clean` | Clean removes `.dart_tool/package_config.json` | Run `flutter build apk` (or `flutter pub get`) first to regenerate |
| Notification not received | NotificationService stub not fully wired | See Enhancement Guide §8.2 for FCM integration |

---

## 8. Enhancement Guide

### 8.1 Add a New Message Type (e.g., Sticker)

**Step 1** — Extend the enum in `lib/models/message.dart`:
```dart
enum MessageType { text, image, video, file, gif, audio, sticker }
```

**Step 2** — Handle it in `chat_service.dart _parseMessage()`:
```dart
// No special handling needed unless sticker has an iv field
```

**Step 3** — Add a branch in `message_bubble.dart _buildContent()`:
```dart
case MessageType.sticker:
  return Image.network(msg.mediaUrl!, width: 120, height: 120);
```

**Step 4** — Add a send method in `chat_service.dart`:
```dart
static Future<void> sendSticker(String stickerUrl) async {
  await _messages.add({
    'sender': mySenderId,
    'type': 'sticker',
    'text': '',
    'mediaUrl': stickerUrl,
    'timestamp': FieldValue.serverTimestamp(),
  });
}
```

**Step 5** — Wire up the UI in `ChatScreen` attach menu.

---

### 8.2 Enable Push Notifications

The `lib/services/notification_service.dart` stub is already called in `main()`.  
Fill in the implementation:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';

class NotificationService {
  static Future<void> init() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token = await messaging.getToken();
    LogService.i('FCM', 'Token: $token');

    // Subscribe to room topic so both devices receive messages
    await messaging.subscribeToTopic(chatRoomId);

    FirebaseMessaging.onMessage.listen((msg) {
      // Show in-app banner when foregrounded
    });
  }
}
```

You'll also need a Cloud Function or Firebase Extension to fan out messages to the topic.

---

### 8.3 Swap the Backend (e.g., Supabase)

1. Implement `IChatRepository` in a new file `lib/repositories/supabase_chat_repository.dart`
2. Implement all methods using Supabase Realtime + Storage
3. In `ChatScreen.initState()`, change one line:
   ```dart
   // Before:
   final repo = FirebaseChatRepository();
   // After:
   final repo = SupabaseChatRepository();
   ```

No other files change. `ChatController` is backend-agnostic.

---

### 8.4 Add Group Chat

The current design has exactly two slots (A and B) in `roleAssignments`. To support groups:

1. Replace the two-slot model in `device_service.dart` with a dynamic list:
   ```dart
   // roleAssignments: { "device-uuid-1": "member", "device-uuid-2": "member" }
   ```
2. `mySenderId` becomes the device UUID, not 'A' or 'B'
3. Update Firestore security rules to validate membership
4. Update `presence`, `typing`, `readAt` maps to use device UUIDs as keys
5. Update `MessageBubble` — `msg.sender == mySenderId` check still works

---

### 8.5 Add Message Reactions

1. Add a `reactions` field to the Message model:
   ```dart
   final Map<String, String>? reactions;  // {'A': '👍', 'B': '❤️'}
   ```
2. Add to `Message.fromMap()`:
   ```dart
   reactions: (map['reactions'] as Map<String, dynamic>?)
       ?.map((k, v) => MapEntry(k, v as String)),
   ```
3. Add a Firestore update method in `ChatService`:
   ```dart
   static Future<void> reactToMessage(String msgId, String emoji) async {
     await _messages.doc(msgId).update({'reactions.$mySenderId': emoji});
   }
   ```
4. Render in `MessageBubble._buildContent()` with a long-press gesture.

---

### 8.6 Add Google Calendar Reminders (already implemented)

This feature is live. Each to-do tile has a calendar icon button. The implementation is in `lib/screens/todo_screen.dart` and uses `add_2_calendar ^3.0.1` (no OAuth — uses Android's native calendar intent).

Key points for future changes:
- `_Todo.dueDate` (nullable `DateTime`) is persisted as ISO-8601 in SharedPreferences
- `formatDue(DateTime)` lives in `lib/utils/time_utils.dart` — test it there, not in the widget
- Tapping the icon → `DatePicker` → `TimePicker` → `Add2Calendar.addEvent2Cal(Event(...))`
- Overdue tasks: subtitle turns red, calendar icon turns red

### 8.7 Re-Enable End-to-End Encryption

`lib/services/encryption_service.dart` is still present but has no callers.

1. Add back to `main()`:
   ```dart
   await EncryptionService.initialize();  // generates/loads key pair
   ```
2. In `ChatController.init()`, call key exchange:
   ```dart
   await EncryptionService.listenForKeyChanges();
   ```
3. In `chat_service.dart sendText()`, wrap text before writing:
   ```dart
   final encrypted = await EncryptionService.encrypt(text);
   map['text'] = encrypted.ciphertext;
   map['iv'] = encrypted.iv;
   ```
4. In `_parseMessage()`, decrypt when `iv != null`:
   ```dart
   final text = isLegacyEncrypted
       ? await EncryptionService.decrypt(map['text'], map['iv'])
       : map['text'];
   ```
   Note: `_parseMessage` is currently sync — you'd need to make it async or move decryption to the stream map step.

---

## 9. Testing Guide

### Test Locations

```
test/
├── helpers/
│   └── fake_chat_repository.dart   ← in-memory IChatRepository, no Firebase
├── controllers/
│   └── chat_controller_test.dart   ← optimistic UI, pagination, markRead, canModify,
│                                      hideMessage, editMessage, deleteMessage, presence
├── models/
│   └── message_test.dart           ← fromMap/toMap, all MessageTypes, legacy iv field
├── utils/
│   └── time_utils_test.dart        ← formatLastSeen (issue #1 regression), formatDue
└── screens/
    └── todo_screen_test.dart       ← widget tests: add/complete/delete tasks, calendar button
integration_test/
└── chat_screen_test.dart           ← end-to-end smoke tests (requires physical device)
```

**Run all unit tests (no device needed):**
```powershell
$env:PUB_CACHE = "D:\pub-cache"
flutter test                        # 87 tests, ~10 seconds
```

### How FakeChatRepository Works

`ChatController` depends only on `IChatRepository`. In tests, pass a `FakeChatRepository` that uses `StreamController` instead of Firestore:

```dart
class FakeChatRepository implements IChatRepository {
  final _msgController = StreamController<List<Message>>.broadcast();
  final _readAtController = StreamController<DateTime?>.broadcast();

  bool throwOnSend = false;
  int markReadCallCount = 0;

  // Inject test messages at will
  void emitMessages(List<Message> msgs) => _msgController.add(msgs);
  void emitReadAt(DateTime ts) => _readAtController.add(ts);

  @override
  Stream<List<Message>> messagesStream({int limit = 50}) => _msgController.stream;

  @override
  Stream<DateTime?> otherReadAtStream() => _readAtController.stream;

  @override
  Future<void> sendText(String text, {String? replyToId, String? clientId,
      String? replyToText, String? replyToSender}) async {
    if (throwOnSend) throw Exception('simulated network error');
  }

  @override Future<void> markRead() async { markReadCallCount++; }
  @override Future<void> enterChat() async {}
  @override Future<void> leaveChat() async {}
  @override Future<void> setTyping(bool _) async {}
  @override Stream<bool> otherTypingStream() => const Stream.empty();
  @override Stream<bool> otherPresenceStream() => const Stream.empty();
  @override Stream<DateTime?> otherLastSeenStream() => const Stream.empty();
  @override Future<void> clearMyView() async {}
  @override Future<DateTime?> getClearedAt() async => null;
  @override Future<Set<String>> getHiddenIds() async => {};
  @override Future<void> hideMessage(String _) async {}
  @override Future<void> editMessage(String _, String __) async {}
  @override Future<void> deleteMessage(String _) async {}
  @override Future<List<Message>> fetchOlderMessages(DateTime _, {int limit = 30}) async => [];
}
```

### Copy-Paste Test Example

```dart
// test/chat_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/controllers/chat_controller.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/constants.dart';

import 'fake_chat_repository.dart';  // file above

void main() {
  setUp(() => mySenderId = 'A');  // fix role for tests

  test('sendText adds optimistic message before Firestore write', () async {
    final repo = FakeChatRepository();
    final ctrl = ChatController(repo);
    await ctrl.init();

    int notifyCount = 0;
    ctrl.addListener(() => notifyCount++);

    await ctrl.sendText('Hello');

    // Message appears immediately in the pending list
    expect(ctrl.messages.length, 1);
    expect(ctrl.messages.first.text, 'Hello');
    expect(notifyCount, greaterThan(0));
  });

  test('failed send marks message as failed', () async {
    final repo = FakeChatRepository()..throwOnSend = true;
    final ctrl = ChatController(repo);
    await ctrl.init();

    await ctrl.sendText('Hello');

    expect(ctrl.failedIds, isNotEmpty);
  });

  test('markRead fires when other person has messages', () async {
    final repo = FakeChatRepository();
    final ctrl = ChatController(repo);
    await ctrl.init();

    // Simulate a message from B
    repo.emitMessages([
      Message(
        id: '1', sender: 'B', text: 'Hi', type: MessageType.text,
        timestamp: DateTime.now(),
      ),
    ]);

    await Future.delayed(const Duration(milliseconds: 600)); // debounce expires
    expect(repo.markReadCallCount, greaterThan(0));
  });
}
```

**Run all tests:**
```powershell
$env:PUB_CACHE = "D:\pub-cache"
flutter test
```

---

## 10. Build & Release

### `build_release.ps1` — Walkthrough

```powershell
# 1. Force all Gradle and pub caches to D: drive (CRITICAL — never write to C:)
$env:GRADLE_USER_HOME = "D:\gradle"
$env:PUB_CACHE         = "D:\pub-cache"

# 2. Build three split APKs (armeabi-v7a, arm64-v8a, x86_64)
#    --split-per-abi avoids the ~260 MB "fat" APK
flutter build apk --release --split-per-abi

# 3. Copy the arm64 APK (the one that runs on all modern Android phones)
#    to a friendly name
$src = "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
$dst = "build\app\outputs\flutter-apk\MyTask.apk"

if (Test-Path $src) {
    Copy-Item $src $dst -Force
    $mb = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Host "`nMyTask.apk ready — $mb MB`n$((Resolve-Path $dst).Path)"
} else {
    Write-Host "Build failed — arm64 APK not found"
}
```

**Run it:**
```powershell
cd D:\Projects\chatapp
.\build_release.ps1
```

**Expected output:**
```
Building with sound null safety
...
✓  Built build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (105.5 MB)

MyTask.apk ready — 105.5 MB
D:\Projects\chatapp\build\app\outputs\flutter-apk\MyTask.apk
```

### D: Drive Requirement

Gradle and pub download gigabytes of dependencies. The env vars redirect all caches:

| Variable | Path | What it stores |
|---|---|---|
| `GRADLE_USER_HOME` | `D:\gradle` | Gradle wrapper, Android SDK components, compiled classes |
| `PUB_CACHE` | `D:\pub-cache` | Dart/Flutter package cache |

Without these variables Flutter falls back to `%USERPROFILE%\AppData` (C: drive).

### ProGuard Warnings vs Errors

The build prints warnings like:
```
Warning: com.google.android.play.core.splitcompat.SplitCompatApplication...
```

These are **warnings**, not errors. The `android/app/proguard-rules.pro` file already contains the necessary `-dontwarn` directives. The build succeeds and the APK runs correctly.

### APK Output Paths

| File | ABI | Size | Use |
|---|---|---|---|
| `app-arm64-v8a-release.apk` | arm64 | ~105 MB | Modern phones (2017+) — **use this** |
| `app-armeabi-v7a-release.apk` | arm32 | ~98 MB | Older 32-bit devices |
| `app-x86_64-release.apk` | x86_64 | ~106 MB | Emulators |
| `MyTask.apk` | arm64 | ~105 MB | Friendly alias of arm64 APK |

### Install on Device

```powershell
adb install -r "build\app\outputs\flutter-apk\MyTask.apk"
```

Or transfer the APK file directly to the phone via USB/cloud and open it.
