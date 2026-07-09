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
11. [Cloud Functions](#11-cloud-functions)

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
| Push messaging | Firebase Cloud Messaging | firebase_messaging 14.x |
| Server functions | Cloud Functions (Node 20, 1st gen) | firebase-functions 4.x |
| Audio/video calls | Agora RTC Engine | 6.3.x |
| Local notifications | flutter_local_notifications | 17.x |
| Background tasks | WorkManager | workmanager 0.9.x |
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
| `agora_app_certificate` | `""` | **Legacy fallback** — certificate now lives in Secret Manager (see §11). Blank this out once the `getAgoraToken` function is deployed |
| `agora_channel` | `my-call-channel-001` | Both users must share the same channel |
| `chat_room_id` | `my-chat-room-001` | Firestore document path segment |
| `agora_token` | `""` | **Legacy fallback** — tokens are now fetched from the `getAgoraToken` Cloud Function on app open (see §5 AgoraTokenService) |
| `todo_input_text_color` | `#ADADAD` | Hex color of the to-do input hint text |
| `enable_firestore_logging` | `false` | When true, LogService also writes to Firestore `app_logs/` |

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
│  ReminderService · FcmService · AgoraTokenService     │
│  CallService · CallLogService · AgoraTokenBuilder     │
├──────────────────────────────────────────────────────┤
│              Background Execution                     │
│  background_worker.dart (WorkManager, 15-min isolate) │
│  FCM background handler (fcm_service.dart)            │
├──────────────────────────────────────────────────────┤
│              Firebase / Agora SDKs                    │
│  Firestore · Storage · Auth · Remote Config · RTC     │
│  Cloud Messaging · Cloud Functions (see §11)          │
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
    │   ├── A: "android-id-A"            ← ANDROID_ID — survives app reinstall
    │   └── B: "android-id-B"               (UUID fallback for emulators)
    ├── fcmTokens/
    │   ├── A: "fcm-token..."            ← written by FcmService.init(); read by the
    │   └── B: "fcm-token..."               onReminderCreated Cloud Function
    ├── appLastOpened/
    │   ├── A: Timestamp                 ← heartbeat from ChatScreen.initState();
    │   └── B: Timestamp                    shows "other device last opened" info
    └── callSignal/
        ├── from: "A" | "B"
        ├── type: "audio" | "video"
        ├── status: "ringing" | "accepted" | "declined" | "ended"
        ├── token: string                ← Agora RTC token (may be empty in Test Mode)
        └── timestamp: Timestamp

rooms/{chatRoomId}/reminders/
└── {auto-id}                            ← one doc per reminder. EVERY reminder is stored
    │                                       here: cross-device ("Remind them") AND local
    │                                       "Remind me" self reminders (stored as a backup).
    ├── forUser: "A" | "B"               ← recipient. Equals createdBy for a self reminder.
    ├── title: string
    ├── scheduledAt: Timestamp           ← when the reminder should fire
    ├── addToList: bool                  ← true = also insert into recipient's todo list
    ├── done: bool                       ← synced both ways for shared tasks
    ├── locallyScheduled: bool           ← recipient sets true once its notification is
    │                                       scheduled (WorkManager skip guard). Created
    │                                       true for "Remind me" self reminders so the
    │                                       delivery paths AND onReminderCreated skip them
    │                                       (the creator already scheduled it locally).
    ├── createdBy: "A" | "B"
    ├── createdAt: Timestamp
    ├── updatedBy: "A" | "B"?            ← set by updateSharedTask()
    └── updatedAt: Timestamp?

  Deletion: deleting a task deletes its backing reminder doc. The local _Todo links
  the doc via `sharedId` (mirrored, addToList=true) or `reminderDocId` (stored-only:
  self reminders and remind-them-without-list). addToList tasks can be deleted by
  EITHER side (the mirror removes the other copy); stored-only reminders are owned by
  their creator.

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
 7. prefs.setString('_bgChatRoomId', chatRoomId)  ← for the background isolate
 8. [unawaited] FcmService.init(forUser: mySenderId)   ← FCM token + handlers
 9. ReminderService.pendingStream(mySenderId).listen() ← foreground reminder delivery
10. ReminderService.sharedTasksStream().listen()       ← shared-task two-way mirror
11. [unawaited] AgoraTokenService.init()  ← needs auth (step 3) AND Remote Config
                                            (fetched token must win over RC token)
12. Workmanager().registerPeriodicTask()  ← 15-min background reminder/sync worker
13. [unawaited] CallLogService.init()     ← phone/contacts permissions + call log sync
14. runApp(TasksApp())
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
| `get/setLastReadMsgId()` | Per-room SharedPreferences guard (`lastReadMsgId_{chatRoomId}`) — newest other-message already marked read; keeps the read time stable across app restarts |
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

**Stable device ID:** the primary identifier is Android's `ANDROID_ID` (via `device_info_plus`), which survives app reinstall — so a reinstalled device reclaims its original role instead of falling into the "both slots taken" path. A UUID persisted in SharedPreferences is the fallback for emulators/unusual OEM builds.

**Heartbeat:** `writeHeartbeat()` (called from `ChatScreen.initState()`) stamps `appLastOpened.{role}` on the room doc; `otherLastOpenedStream(otherId)` lets each device see when the other last opened the app.

**Test seam:** `DeviceService.testMode = true` makes `writeHeartbeat` a no-op and `otherLastOpenedStream` emit `null` — required to widget-test `ChatScreen` without Firebase.

**Reset both roles (e.g., after reinstalling on both devices):**

```dart
await DeviceService.resetAssignments();
// Then relaunch both devices. Launch A first to claim slot A.
// In debug builds: double-tap the TodoScreen AppBar title → reset dialog.
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
| `parseReminderTimestamp(String iso)` | Parses an FCM payload timestamp **into local time**. Payload strings are UTC (`...Z`); parsing without `.toLocal()` displayed UTC wall-clock time (a 22:30 IST reminder showed as 17:00) |

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

**Lifecycle hooks — presence debounce + call protection:**

Leaving the app does NOT immediately mark the user offline. A debounce timer
absorbs brief interruptions (system dialogs, notification shade, permission
prompts) and the navigation pop is skipped while a call is live:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _leaveTimer?.cancel();
    _ctrl.enter();                        // marks presence online
  } else if (state == AppLifecycleState.inactive) {
    // Some Android devices fire ONLY `inactive` for incoming-call overlays
    // (WhatsApp etc.) and never follow up with paused/hidden.
    // ??= starts the timer only if one isn't already running.
    _leaveTimer ??= Timer(const Duration(seconds: 8), () { ... });
  } else if (state == AppLifecycleState.hidden ||
             state == AppLifecycleState.paused) {
    _leaveTimer?.cancel();
    _leaveTimer = Timer(const Duration(seconds: 5), () {
      _ctrl.leave();                      // marks offline, clears typing
      // Pop back to TodoScreen — but NEVER during a live call:
      // callActiveNotifier covers minimized calls, CallService.inCall
      // covers full-screen calls (popping would dispose CallScreen and
      // release the Agora engine mid-call).
      if (mounted && !callActiveNotifier.value && !CallService.inCall) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  } else if (state == AppLifecycleState.detached) {
    _leaveTimer?.cancel();
    _ctrl.leave();
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

**Tappable links** — text messages are linkified: `splitLinks()` in
`lib/utils/link_utils.dart` (pure, unit-tested) splits the body into plain and
URL chunks (`https?://` and bare `www.`, trailing sentence punctuation
stripped); link chunks render as underlined `TextSpan`s with a
`TapGestureRecognizer` that calls `url_launcher`'s `launchUrl(mode:
externalApplication)`. Recognizers are tracked in `_linkRecognizers` and
disposed with the state. Long-press message actions still work — recognizers
only claim taps.

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
// Clock icon      = pending (optimistic, not yet confirmed by Firestore)
// Single tick     = sent but not read
// Green ticks     = other user has called markRead() after this timestamp
bool get _isRead {
  // isPending guard: optimistic messages use DateTime.now() (LOCAL clock).
  // If the device clock is behind Firebase's server clock, otherReadAt (a
  // server timestamp) can be later than a brand-new message's timestamp,
  // which falsely showed read ticks on unread messages. A message can only
  // be "read" once Firestore has confirmed it with a server timestamp.
  if (!isMe || widget.otherReadAt == null || widget.isPending) return false;
  return !widget.message.timestamp.isAfter(widget.otherReadAt!);
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

**Token priority chain** (in `CallScreen._startCall()`):

```
1. agoraToken global (non-empty)  → use directly
   ← normally set by AgoraTokenService from the getAgoraToken Cloud Function
     (fetch-on-app-open caching); falls back to the Remote Config agora_token
2. agoraAppCertificate from Remote Config (non-empty, caller only)
   → build token locally with HMAC (legacy fallback)
3. Neither set → callee uses the token forwarded via callSignal;
   or join with empty token (Agora Test Mode — App ID only)
```

**Call-lifetime flags** — two globals with different scopes:

| Flag | True when | Used for |
|---|---|---|
| `CallService.inCall` | `joinCall()` → `leaveCall()` (entire call) | Blocks ChatScreen's background-leave navigation from popping CallScreen and killing the engine |
| `callActiveNotifier` | Call is **minimized** only | Shows the mini call bar / floating video overlay in ChatScreen |

**Foreground service:** `CallScreen` invokes `startForeground` /
`stopForeground` on a platform channel so Android keeps the process alive
while a call runs in the background. Native side:
`android/.../MainActivity.java` (channel handler) →
`android/.../CallForegroundService.java` (the service).

Android **requires** every foreground service to show a notification — it
cannot be removed. For discretion it is made as invisible as the OS allows:

- Channel `chatapp_bg_channel_v2` with `IMPORTANCE_MIN` — no status-bar
  icon; entry collapses to the bottom of the notification shade
- `VISIBILITY_SECRET` — hidden from the lock screen
- Neutral wording ("MyTask — Running", channel name "Background sync") and
  a generic checkmark icon — nothing references a call
- Channel IDs are **cached by the OS** once created: importance changes
  need a new channel ID; the legacy `chatapp_call_channel` is deleted on
  service create so it vanishes from the app's notification settings

**Minimize / restore call:**

```dart
// User taps minimize (or back) in CallScreen
callActiveNotifier.value = true;   // triggers FloatingVideoOverlay in ChatScreen
Navigator.pop(context);            // pops CallScreen

// CallService._engine is NOT released — engine singleton survives screen pop
// FloatingVideoOverlay renders AgoraVideoView using the same running engine

// User taps restore in FloatingVideoOverlay
callActiveNotifier.value = false;
Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen()));
// CallScreen.initState() calls CallService.updateCallbacks(...) — no re-join needed
```

**Floating video overlay gestures** (`floating_video_overlay.dart`):

- Drag anywhere → moves the overlay (clamped to screen bounds)
- Drag from the bottom-right 24×24 corner handle → resizes (80–260 × 100–340)
- Fast upward flick (velocity < −600 px/s) → restores full-screen call
- Tap → restores full-screen call. Position alone NEVER triggers restore —
  an earlier `_y < 35% of screen` check fired on every drag release because
  the overlay starts at y=80.

**AgoraVideoView blank-screen fix:**

```dart
// In ChatScreen._onLifecycleResumed():
_surfaceKey = UniqueKey();   // forces widget tree to dispose+recreate AgoraVideoView
// The platform view's SurfaceTexture goes stale after backgrounding on Android.
// Recreating the widget from scratch re-attaches it to the running engine.
```

---

### `lib/services/notification_service.dart`

Local notifications via `flutter_local_notifications` (channel `task_reminders`).

| Method | What it does |
|---|---|
| `init()` | Creates the channel, requests permission, sets up timezone data |
| `scheduleReminder({id, title, scheduledTime})` | Exact-time scheduled notification; returns `false` if permission/alarm unavailable |
| `cancelReminder(int id)` | Cancels a scheduled notification |
| `showNow({id, title, body})` | Immediate notification — used by the FCM handler for the "Reminder set" confirmation |

`NotificationService.testMode = true` makes everything a no-op in tests.

**Notification ID convention:** a reminder may be scheduled under either
`todo.id.hashCode` (self-set via the alarm button) or
`reminderDocId.hashCode.abs() % 0x7FFFFFFF` (FCM/WorkManager delivery path).
Code that cancels/reschedules a shared task's notification must cancel **both**.

---

### `lib/services/reminder_service.dart`

Cross-device reminders AND two-way shared-task sync — both built on the
`rooms/{roomId}/reminders` collection.

**Reminder delivery (A sets a reminder for B):**

| Method | Role |
|---|---|
| `createReminder({forUser, title, scheduledAt, addToList})` | A writes the doc; returns the doc ID so A can link its local task copy |
| `pendingStream(forUser)` | Foreground path — B's app (if open) schedules the notification within seconds |
| `fetchPending(forUser, roomId)` + `markScheduled(docId, roomId)` | Background path — WorkManager worker picks up unprocessed docs every 15 min |
| `insertTodoToPrefs(prefs, r)` | Inserts the task into B's local list (id `reminder_{docId}`, duplicate-guarded, `sharedId` linked) |

The third delivery path is FCM push (see FcmService below) — so B gets the
reminder whether the app is open, backgrounded, or killed.

**Shared-task sync (tasks created with "Add to their task list"):**

The reminder doc is the source of truth. Both devices link their local copy
via a `sharedId` field (legacy `reminder_*` IDs are backfilled automatically).

| Method | Role |
|---|---|
| `updateSharedTask(docId, {title, scheduledAt, done})` | Local edits write through to the doc |
| `deleteSharedTask(docId)` | Deleting on either phone deletes for both |
| `sharedTasksStream()` | Live mirror — main.dart listener applies remote changes within seconds |
| `fetchSharedTasks(roomId)` | Server-forced one-shot for the background worker (offline throws instead of returning a partial cache) |
| `applySharedSnapshot(prefs, docs, {applyDeletes})` | The reconcile: applies title/done/dueDate changes, removes deleted tasks, reschedules notifications |

**Reconcile safety rules:**
- Deletions apply only from **server-confirmed** snapshots (`applyDeletes` =
  `!snapshot.isFromCache`) — an offline cache can never mass-delete tasks
- Remote due-date changes apply only to copies that already track a due date
  (a creator who declined "Remind me" never gets surprise alarms)
- Docs without a `done` field (pre-feature) never revert local done state

---

### `lib/services/fcm_service.dart`

Firebase Cloud Messaging wiring — makes reminder delivery instant even when
the app is killed.

- `init(forUser:)` — registers the background handler, requests permission,
  writes the device's FCM token to `rooms/{roomId}/fcmTokens.{forUser}`
  (refreshed on token rotation), and listens for foreground messages
- `_onBackgroundMessage` — top-level `@pragma('vm:entry-point')` handler;
  runs in a separate isolate when the app is backgrounded/terminated
- `_processReminderPayload` — shared by both paths: parses the payload
  (**UTC → local via `parseReminderTimestamp`**), shows an immediate
  "Reminder set — [task] today at HH:mm" confirmation, schedules the real
  notification for the exact time, and inserts the task into the local list
  when `addToList` is true

The push itself is sent by the `onReminderCreated` Cloud Function (§11).

---

### `lib/services/agora_token_service.dart`

Fetch-on-open caching of the Agora RTC token — replaces manually pasted
Remote Config temp tokens.

```
App opens → restore cached token into `agoraToken` immediately
          → if cache older than 12h: call getAgoraToken Cloud Function
            (mints a 24h wildcard uid-0 token) → cache + replace
```

- The Cloud Function cold start (~1–3 s) happens during app open — **never
  at call time**, so calls start instantly
- Fetch failure keeps the cached token (still valid 12–24 h)
- `fetchOverride` static is the test seam
- Runs after anonymous sign-in (callable requires auth) and after
  `RemoteConfigService.init()` (fetched token must win over the RC value)

---

### `lib/background_worker.dart`

WorkManager entry point (`callbackDispatcher`, `@pragma('vm:entry-point')`) —
runs every 15 minutes in a separate Dart isolate, even after reboot:

```
1. Firebase.initializeApp() (isolate has no app state)
2. Read role + room ID from SharedPreferences ('sender_role', '_bgChatRoomId')
3. fetchPending() → schedule notifications for unprocessed reminders
   → insertTodoToPrefs when addToList → markScheduled
4. fetchSharedTasks() → applySharedSnapshot(applyDeletes: true)
   → mirrors shared-task edits/deletes made while the app was killed
```

Being a separate isolate it shares NO memory with the app — everything goes
through SharedPreferences and Firestore.

---

### `lib/screens/todo_screen.dart`

The home screen — a personal to-do list with cross-device features.

| Feature | How |
|---|---|
| Add task | Bottom input bar → "Set a reminder?" prompt → unified Set Reminder dialog |
| Rename task | **Long-press** the tile → Edit Task dialog (shared tasks push the new title to the other phone) |
| Complete / delete | Checkbox / swipe-left — both write through to Firestore for shared tasks |
| Sub-tasks | Expand a tile → add/check/delete; progress bar on the tile |
| Search | AppBar search icon — filters by title and subtask text |
| Reminders | One alarm button per task → date/time picker → unified dialog |
| Open chat | Type `flutter` in the add-task field (hidden trigger) |
| Role reset | Debug builds: double-tap the AppBar title |

**Unified Set Reminder dialog** (single entry point `_setReminder`):

```
Pick date/time → dialog:
  ☑ Remind me            (pre-checked — local notification on this phone)
  ☐ Remind Them          (creates a reminder doc → FCM push to other phone)
      ☐ Add to their task list   (only visible when Remind Them is checked;
                                  makes it a synced shared task)
```

Tasks persist as JSON in SharedPreferences under `todos_v1`
(`id`, `title`, `done`, `dueDate?`, `sharedId?`, `subtasks[]`).
`todoRefreshNotifier` (in constants.dart) signals the screen to reload when
a remote task arrives or the shared-task mirror changes something.

---

### `lib/screens/calls_screen.dart` + `lib/services/call_log_service.dart`

- `CallsScreen` — the "Calls" tab inside ChatScreen: renders call history from
  `ChatService.callEventsStream()` (call-event messages in the messages
  collection), with audio/video call buttons. `callsStream` parameter is the
  test seam.
- `CallLogService.init()` — requests phone/contacts permissions on startup
  and syncs the device call log to Firestore (runs last in startup so its
  permission dialogs don't block the app).

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
  ├─ FcmService.init() · reminder streams · AgoraTokenService.init()
  │  Workmanager registration · CallLogService.init()   (see §5 main.dart)
  │
  └─ runApp(TasksApp()) → MaterialApp → TodoScreen → ChatScreen
```

### 6.6 Cross-Device Reminder (3 delivery layers)

```
A: task → alarm button → picks time → checks "Remind Them" (+ "Add to their task list")
        │
        ▼
ReminderService.createReminder()
  reminders/{id} = {forUser:'B', title, scheduledAt, addToList, locallyScheduled:false}
        │
        ├────────────── LAYER 1: FCM (app killed or backgrounded) ──────────────┐
        │   onReminderCreated Cloud Function fires onCreate                     │
        │   → reads rooms/{roomId}/fcmTokens.B → sends high-priority push       │
        │   → B's _onBackgroundMessage → _processReminderPayload                │
        │                                                                       │
        ├────────────── LAYER 2: Firestore stream (app open) ───────────────────┤
        │   pendingStream('B') emits within seconds → schedule + insert         │
        │   → markScheduled(locallyScheduled: true)                             │
        │                                                                       │
        └────────────── LAYER 3: WorkManager (fallback, ≤15 min) ───────────────┘
            background worker fetches locallyScheduled==false docs

B's phone (all layers converge):
  1. NOW:  "Reminder set — [title] today at HH:mm"   (immediate confirmation)
  2. AT scheduledAt:  "[title]"                       (the actual reminder)
  3. If addToList: task appears in B's list (duplicate-guarded by id)
```

### 6.7 Shared-Task Sync (edit/delete on either phone)

```
Either phone edits/completes/deletes a task with sharedId != null
        │
        ▼
updateSharedTask() / deleteSharedTask()  → reminders/{sharedId} updated/deleted
        │
        ▼ (other phone)
App open:   sharedTasksStream() snapshot → applySharedSnapshot()
App killed: next WorkManager run → fetchSharedTasks() → applySharedSnapshot()
        │
        ├─ title/done/dueDate applied to the linked local task
        ├─ doc gone (+server-confirmed) → local copy removed
        ├─ notifications cancelled/rescheduled (both ID variants)
        └─ todoRefreshNotifier++ → TodoScreen reloads
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
| Call drops when app goes to background | (Fixed) ChatScreen's leave-timer popped CallScreen; `callActiveNotifier` only covers minimized calls | `CallService.inCall` (true for the whole call) added to both pop guards |
| Reminder notification shows time 5:30 h off | (Fixed) FCM payload timestamps are UTC; formatting without `.toLocal()` printed UTC wall-clock | `parseReminderTimestamp()` converts at the single parse point |
| Read ticks appear on just-sent messages | (Fixed) Optimistic messages use the local clock; device clock behind server time made `otherReadAt` look newer | `_isRead` returns false while `isPending` |
| "Read HH:mm" time changes on already-read messages after the reader restarts the app | (Fixed) The read guard `_lastSeenOtherMsgId` was in-memory only; on restart it reset to null, so re-opening a chat with no new messages re-fired `markRead()` and re-stamped `readAt` | Persist the last-read message id per room (`ChatService.get/setLastReadMsgId`, key `lastReadMsgId_{chatRoomId}`); `ChatController.init()` restores it so an idle re-open never advances `readAt` |
| Presence flips offline during WhatsApp call overlay | Some devices fire only `inactive` for overlays | 8s debounce timer on `inactive` (`??=` so it never restarts mid-sequence) |
| Overlay drag snapped back to full screen | `_y < 35% of screen` was always true (overlay starts at y=80) | Restore only on tap or upward flick; corner handle resizes |
| Reminder for other person never arrives | Recipient's phone has no FCM token registered | Check `rooms/{roomId}/fcmTokens` in Firestore Console — open the app once on that phone to register |
| Reminder docs pile up in Firestore after deleting tasks | (Fixed) Self reminders were never stored, and "remind them, no list" docs were created but not linked to the local task, so deletion never removed them | Every created doc is linked (`sharedId` or `reminderDocId`) and `_delete` deletes `backingDocId`; self reminders are stored with `locallyScheduled=true` and the Cloud Function skips them |
| Calls fail with token error | Cached token expired and `getAgoraToken` unreachable at last app open | Open the app once with network (token refreshes), or check function logs: `firebase functions:log` |
| "Call in progress" notification visible during background calls | Foreground service notification (required by Android) was IMPORTANCE_LOW with call-specific wording | (Fixed) IMPORTANCE_MIN channel + VISIBILITY_SECRET + neutral "MyTask — Running" text. A notification cannot be removed entirely — MIN importance is the OS maximum for discretion |

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

### 8.2 Push Notifications (already implemented for reminders)

FCM is fully wired for reminder delivery — see `lib/services/fcm_service.dart`
(§5) and the `onReminderCreated` Cloud Function (§11).

**To extend push to chat messages:** add a second Cloud Function triggered on
`rooms/{roomId}/messages/{messageId}` onCreate that reads the *other* user's
token from `fcmTokens` and sends a push with the message preview. The client
token registration and background handler already exist — only the function
and a new `type: 'message'` branch in `_processReminderPayload`'s dispatcher
are needed.

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

### 8.6 Task Reminders (already implemented — replaced calendar intents)

The original `add_2_calendar` calendar-intent approach was replaced by the
in-app reminder system: local notifications + cross-device delivery + shared
task sync. See §5 (NotificationService, ReminderService, FcmService),
§6.6/§6.7 (data flows) and §11 (Cloud Function).

Key points for future changes:
- `_Todo.dueDate` (nullable `DateTime`) is persisted as ISO-8601 in SharedPreferences
- `_Todo.sharedId` links a task to its `reminders/{id}` doc — presence of a
  `sharedId` means every edit/delete must write through to Firestore
- `formatDue(DateTime)` lives in `lib/utils/time_utils.dart` — test it there, not in the widget
- Overdue tasks: subtitle turns red, alarm icon turns red

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
│   └── fake_chat_repository.dart        ← in-memory IChatRepository, no Firebase
├── controllers/
│   └── chat_controller_test.dart        ← optimistic UI, pagination, markRead, canModify,
│                                           hideMessage, editMessage, deleteMessage, presence
├── models/
│   └── message_test.dart                ← fromMap/toMap, all MessageTypes, legacy iv field
├── utils/
│   ├── time_utils_test.dart             ← formatLastSeen, formatDue,
│   │                                       parseReminderTimestamp (UTC→local regression)
│   └── link_utils_test.dart             ← splitLinks URL detection (www, punctuation,
│                                           multiple links, plain text)
├── services/
│   ├── reminder_service_test.dart       ← applySharedSnapshot reconcile rules,
│   │                                       insertTodoToPrefs sharedId link
│   └── agora_token_service_test.dart    ← needsRefresh thresholds, cache behavior,
│                                           fetch-failure fallback
├── widgets/
│   └── message_bubble_test.dart         ← tick states, pending/failed rendering,
│                                           tappable link spans
└── screens/
    ├── todo_screen_test.dart            ← add/complete/delete/search tasks, subtasks,
    │                                       long-press edit dialog, unified reminder dialog
    ├── calls_screen_test.dart           ← call history rendering
    └── chat_screen_lifecycle_test.dart  ← background-leave navigation vs live calls
                                            (uses DeviceService.testMode seam)
integration_test/
└── chat_screen_test.dart                ← end-to-end smoke tests (requires physical device)
```

**Run all unit tests (no device needed):**
```powershell
$env:PUB_CACHE = "D:\pub-cache"
flutter test                        # 170 tests, ~20 seconds
```

**Test-mode seams** — every service that touches Firebase/platform APIs has a
static flag or injectable, set them in `setUp()`:

| Seam | Effect |
|---|---|
| `NotificationService.testMode` | schedule/cancel/show become no-ops |
| `RemoteConfigService.testMode` | skips fetch, returns defaults |
| `ReminderService.testMode` | Firestore methods no-op / return null |
| `DeviceService.testMode` | heartbeat no-op, last-opened stream emits null |
| `AgoraTokenService.fetchOverride` | replaces the Cloud Function call |
| `ChatScreen(repository:, callSignalProvider:)` | constructor injection |
| `CallsScreen(callsStream:)` | constructor injection |

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

### Known Build Warnings (safe to ignore — for now)

Two warnings appear on every build. Neither affects the produced APK:

**1. Kotlin Gradle Plugin (KGP) deprecation**

```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP):
device_info_plus, flutter_timezone, package_info_plus, video_compress,
wakelock_plus, workmanager_android
Future versions of Flutter will fail to build ...
```

Harmless with the current Flutter SDK. It becomes a **build failure only
when the Flutter SDK is upgraded** past the removal point. The fix is a
full dependency migration — tracked as a GitHub issue ("dependency
migration: Firebase majors + Built-in Kotlin plugins"). Scale of the jump
(as of July 2026): firebase_core 2.x→4.x, cloud_firestore 4.x→6.x,
firebase_messaging 14→16, flutter_local_notifications 17→22,
device_info_plus 10→13 — breaking API changes across most service files,
so it needs a dedicated chore PR series with on-device retesting of calls,
reminders, FCM, and notifications.

**Rule until that migration lands: do NOT upgrade the Flutter SDK.**

**2. `open_file` macOS default-plugin complaint**

```
Package open_file:macos references open_file_macos:macos as the default plugin,
but the package does not exist ...
```

Upstream packaging noise about a missing macOS implementation. This app is
Android-only, so it is irrelevant; it disappears when `open_file` is bumped
to 4.x during the same migration.

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

---

## 11. Cloud Functions

Two 1st-gen Node 20 functions live in `functions/` (firebase-functions v4 —
1st gen deliberately, to avoid the Eventarc permission delay 2nd-gen deploys
hit on first use). Deployed to `us-central1` on project `my-chat-app-963fa`.

**Requires the Blaze plan** (pay-as-you-go), but this app's usage is far
inside the free tier: ~tens of invocations/day vs 2M/month free, and
`getAgoraToken` performs **zero** Firestore reads/writes.

### `onReminderCreated` — Firestore trigger

Fires when a doc is created in `rooms/{roomId}/reminders/{reminderId}`:
reads the recipient's token from the room doc's `fcmTokens` map and sends a
high-priority FCM push (notification + data payload, channel
`task_reminders`). This is what makes reminders instant when the recipient's
app is killed. `scheduledAt` is serialized with `toISOString()` — always
UTC, which is why the client parses with `parseReminderTimestamp()`.

**Skips `locallyScheduled === true` docs.** "Remind me" self reminders are
stored as a backup but the creator has already scheduled the local
notification, so pushing to them (`forUser === createdBy`) would duplicate it.
The guard at the top of the trigger returns early for these.

### `getAgoraToken` — HTTPS callable

Mints a 24h wildcard (uid 0) Agora RTC token using the official
`agora-token` npm package. Requires Firebase Auth (anonymous is fine).
Request `{appId, channel}` → response `{token, expiresAt}`.

The App Certificate is read from **Secret Manager**
(`defineSecret('AGORA_APP_CERTIFICATE')`) — it never ships in the APK and
should be removed from Remote Config once all devices run the new APK.

### Deployment

```bash
cd functions
npm install                        # once, or after dependency changes

# One-time: store the Agora App Certificate as a secret
firebase functions:secrets:set AGORA_APP_CERTIFICATE --project my-chat-app-963fa

# Deploy both functions
firebase deploy --only functions --project my-chat-app-963fa

# Tail logs
firebase functions:log --project my-chat-app-963fa
```

Notes:
- `firebase.json` points the functions source at `functions/`; `.firebaserc`
  pins the default project
- `engines.node` in `functions/package.json` must be an exact version string
  (`"20"`) — ranges like `">=20"` fail deploy
- The deploy automatically grants the App Engine service account access to
  the secret
