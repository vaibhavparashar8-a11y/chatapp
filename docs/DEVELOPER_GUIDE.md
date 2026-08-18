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
| `call_backend` | `agora` | Which media backend calls use: `agora` (hosted, per-minute) or `webrtc` (peer-to-peer, free). Any other value falls back to Agora. Flip it here and relaunch — no rebuild |
| `webrtc_turn_url` | `turn:openrelay.metered.ca:80` | TURN relay for the WebRTC backend. Empty = STUN only, which fails whenever either phone is behind carrier-grade/symmetric NAT. Currently set to the free Open Relay Project — swap for self-hosted coturn if you need something you don't depend on a third party for |
| `webrtc_turn_username` | `openrelayproject` | TURN credential (must be a static, non-expiring credential — the engine has no code path to refresh time-limited tokens) |
| `webrtc_turn_credential` | `openrelayproject` | TURN credential |
| `giphy_api_key` | *(empty)* | API key for the in-app GIF picker (free at developers.giphy.com). Empty disables **only** the GIF tab, which then shows a "not set up" note — emoji, keyboard stickers and everything else keep working. Note this is the one feature that sends user input (search terms) to a third party |
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
    ├── presenceAt/
    │   ├── A: Timestamp                 ← presence heartbeat — re-stamped every 20s
    │   └── B: Timestamp                    while the chat is open; reader shows
    │                                       "online" only while beats keep arriving
    │                                       (≤45s stale window), so a force-killed
    │                                       app can't stay "online" forever
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
    ├── todoLastOpened/
    │   ├── A: Timestamp                 ← DeviceService.writeTodoOpened(), written
    │   └── B: Timestamp                    on TodoScreen open + app resume
    └── callSignal/
        ├── from: "A" | "B"
        ├── type: "audio" | "video"
        ├── status: "ringing" | "accepted" | "declined" | "ended"
        ├── delivered: bool              ← set true by the callee the instant its
        │                                  incoming-call UI appears; reset false by
        │                                  signalCall(). Separate from `status` so it
        │                                  never triggers ChatScreen's caller-cancelled
        │                                  auto-dismiss (see §6.4)
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
    ├── subtasks: [{id,title,done}]?     ← sub-tasks, synced both ways for shared
    │                                       (addToList) tasks. Absent on docs that
    │                                       predate subtask-sync → "don't touch".
    ├── recurrence: string?              ← Recurrence.storage ("daily"/"weekly"/
    │                                       "weekdays"/"weekends"). Absent = does not
    │                                       repeat, which is also how docs written
    │                                       before recurrence-sync parse. Carried in
    │                                       the FCM payload so the recipient arms the
    │                                       same repeat, and synced both ways for
    │                                       shared tasks (updateSharedTask writes it
    │                                       even for `none`, so clearing a repeat
    │                                       reaches the other phone).
    ├── locallyScheduled: bool           ← recipient sets true once its notification is
    │                                       scheduled (WorkManager skip guard). Created
    │                                       true for "Remind me" self reminders so the
    │                                       delivery paths AND onReminderCreated skip them
    │                                       (the creator already scheduled it locally).
    │                                       ALSO the sender's delivery signal: the
    │                                       creator watches this flip true to show
    │                                       "Delivered" (§6.7).
    ├── createdBy: "A" | "B"
    ├── createdAt: Timestamp
    ├── updatedBy: "A" | "B"?            ← set by updateSharedTask()
    └── updatedAt: Timestamp?

  Deletion: deleting a task deletes its backing reminder doc. The local _Todo links
  the doc via `sharedId` (mirrored, addToList=true) or `reminderDocId` (stored-only:
  self reminders and remind-them-without-list). addToList tasks can be deleted by
  EITHER side (the mirror removes the other copy); stored-only reminders are owned by
  their creator.

rooms/{chatRoomId}/webrtc/
└── current                             ← signalling for the ONE active WebRTC call
    ├── offer:  {type, sdp}                (only used when call_backend = webrtc)
    ├── answer: {type, sdp}
    ├── callerCandidates/{auto}          ← trickled ICE from the caller
    └── calleeCandidates/{auto}          ← trickled ICE from the callee
    The caller resets this doc before offering, so a previous call's SDP/ICE can
    never be mistaken for the current one. See §5 WebRtcCallEngine.

rooms/{chatRoomId}/todoBackups/
└── {role}                              ← "A" | "B" — this device's FULL local todo
    ├── data: string                       list as one JSON blob (SharedPreferences
    │                                       `todos_v2`), mirrored on every save.
    │                                       A blob in either format restores fine —
    │                                       `Task.fromJson` reads v1 and v2.
    └── updatedAt: Timestamp
    Restore: SharedPreferences is wiped on uninstall, so on a fresh install (role
    reclaimed via ANDROID_ID) `_loadTodos` fetches this doc when local is empty and
    repopulates the list — local reminders survive reinstall. See §5 todo_screen.

rooms/{chatRoomId}/messages/
└── {auto-id}                            ← one document per message
    ├── sender: "A" | "B"               ← who sent it
    ├── type: "text"|"image"|"video"
    │        |"audio"|"file"|"gif"
    ├── text: string                     ← plaintext body (or "" for media)
    ├── mediaUrl: string?                ← Firebase Storage download URL
    ├── thumbUrl: string?                ← video poster frame (uploaded beside the
    │                                       video) so the receiver shows it instantly
    ├── fileName: string?                ← original filename for files
    ├── fileSize: number?                ← bytes
    ├── timestamp: Timestamp             ← server-side (FieldValue.serverTimestamp())
    ├── clientId: string?                ← "pending_<microseconds>" for optimistic UI
    │                                       (text AND media — see §6.2)
    ├── edited: bool                     ← true after editMessage()
    ├── replyToId: string?               ← message ID being replied to
    ├── replyToText: string?             ← preview text of the quoted message
    ├── replyToSender: string?           ← "A" | "B" for quote styling
    ├── deletedFor: ["A"|"B"]?           ← two-sided delete: roles that deleted this
    │                                       message from their own view. A user in the
    │                                       list doesn't see it; once BOTH are present
    │                                       the doc is deleted from Firestore.
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

app_call_log_A/   (and app_call_log_B/)  ← per-role call history (CallLogService)
└── {docId}
    └── … call metadata (direction, type, timestamps, duration)
```

**Firestore cleanup:** `app_logs`, `app_call_log_A/B`, `rooms/{room}/messages`
and `rooms/{room}/reminders` accumulate over time. `scripts/cleanup.js` is a
`firebase-admin` CLI that selectively bulk-deletes any of them (interactive or
`node cleanup.js <category…>`, with a `--dry-run` preview). Needs a
service-account key at `scripts/serviceAccountKey.json` (gitignored). Full
instructions in `scripts/README.md`. Note the in-app "clear" actions do **not**
delete from Firestore — `LogService.clear()` clears only the in-memory buffer,
and `deleteAllMessages()` just sets a per-device `clearedAt` view marker.

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

### `lib/models/task.dart`

`Task` + `SubTask` — one item on the todo list. Promoted out of
`screens/todo/todo_models.dart`, where it was a private `_Todo` inside a `part`
file, so neither unit-testable nor reachable from the services.

| Field | Notes |
|---|---|
| `id`, `title`, `done`, `subtasks` | unchanged from `_Todo` |
| `start` | the reminder time. **Was `dueDate`** |
| `recurrence` | a `Recurrence` — the five-value enum |
| `createdBy` | `'A'` / `'B'`, which role made it. Drives `isMine` — the calendar's **Mine** box |
| `involvesOther(me)` | derived, not stored: they made it, **or** it is mirrored to their list (`sharedId`), **or** it doesn't ring here (`remindsMe` false). Drives the **Theirs** box. Not the negation of `isMine` — see the calendar section |
| `remindsMe` | whether **this phone** rings for `start` — the "Remind me" tick box. Defaults true (and is only written to JSON when false, so older stored tasks read as true). False = the time is real and is drawn on the calendar / tile, but no local alarm is armed and the daily digest skips it: the reminder exists to notify the *other* person |
| `sharedId` / `reminderDocId` / `backingDocId` | unchanged — see §4 |

> **A task is a title plus at most one instant.** There are deliberately no
> start/end spans, durations or all-day flags: the calendar screen renders these
> same reminders on a month grid rather than introducing a separate event type.
> An earlier revision (#97) carried `end`/`allDay`/`alerts` and an RRULE-based
> rule; they were removed in #99 once the calendar scope was settled, before any
> device had written them.

**`createdBy` is set in three places** and the filter is only correct if all
three hold: `_submit` stamps `mySenderId` on new tasks, `insertTodoToPrefs`
copies the doc's `createdBy` onto a reminder arriving from the other phone, and
`applySharedSnapshot` backfills it onto copies stored before the field existed.
`Task.isMine(role)` treats null as *mine* — a task without it can only have been
written on this phone.

`Task.fromJson` reads **both** storage formats: v2 (`start`) and v1 (`dueDate`),
and backfills `sharedId` from a legacy `reminder_<docId>` local id. That
tolerance is what lets the Firestore todo backup, written at any point in the
app's history, always restore.

### `lib/services/task_store.dart`

The single owner of the locally-stored todo list. The list is read/written from
four places — the todo screen, the shared-task mirror, the FCM handler and the
WorkManager isolate — so the key and its migration live here instead of being a
`_todosKey` constant repeated in each (it was, in three).

| Member | What it does |
|---|---|
| `key` | `todos_v2` — current storage key |
| `legacyKey` | `todos_v1` — kept on disk after migrating, as a rollback snapshot |
| `load(prefs)` | the list, migrating v1 → v2 on first read. **Throws** on corrupt JSON rather than returning `[]`, so callers can tell "no tasks" from "could not read tasks" |
| `save(prefs, tasks)` | persists, and returns the JSON so the Firestore backup doesn't re-encode |
| `decode` / `encode` | format helpers; `decode` accepts both formats |

**Migration:** first `load` after the update reads `todos_v1`, parses it through
`Task.fromJson` (which understands the old field names), writes `todos_v2`, and
leaves v1 untouched. It is idempotent — once v2 exists, v1 is never read again.
Anything that touches the list must go through this class, or the migration only
half-applies and the two keys silently diverge.

### `lib/services/chat_service.dart`

All Firestore and Storage operations — only static methods, no instance state.

**Key methods:**

| Method | What it does |
|---|---|
| `messagesStream({int limit})` | Real-time stream, newest 50, oldest-first |
| `fetchOlderMessages(DateTime before)` | One-shot fetch for pagination |
| `sendText(text, {replyToId, clientId, ...})` | Writes plaintext document |
| `sendMedia(File, MessageType, {fileName, onProgress, clientId})` | Uploads to Storage, then writes the Firestore doc — with `clientId`, so the optimistic bubble can be retired |
| `markRead()` | Updates `readAt.{mySenderId}` on the room doc |
| `get/setLastReadMsgId()` | Per-room SharedPreferences guard (`lastReadMsgId_{chatRoomId}`) — newest other-message already marked read; keeps the read time stable across app restarts |
| `setTyping(bool)` | Updates `typing.{mySenderId}` on the room doc |
| `enterChat()` / `leaveChat()` | Sets `presence`, `presenceAt` heartbeat, and `lastSeen` |
| `refreshPresence()` | Re-stamps `presence`+`presenceAt` — called every 20s by ChatController's presence timer while the chat is open |
| `signalCall(type, {token})` | Writes `callSignal` map to room doc (resets `delivered: false`) |
| `updateCallStatus(status)` | Updates `callSignal.status` |
| `markCallDelivered()` | Sets `callSignal.delivered = true` — callee → caller "my incoming-call UI is showing" signal |
| `editMessage(id, newText)` | Updates `text` and sets `edited: true` |
| `deleteMessage(id)` | Deletes Firestore doc + Storage file if media (immediate "delete for everyone") |
| `deleteForMe(id, deletedFor)` | Two-sided delete: adds this role to the message's `deletedFor`; deletes the doc once the other side is already there (media file left in Storage) |
| `clearChatForMe()` | Batched two-sided "clear chat" — `deletedFor += me` on every message, deletes any the other side already deleted |

**Two-sided deletion:** the chat-clear button and the per-message "Delete" (for a
message that isn't your own recent one) use `deletedFor`. A message with your role
in `deletedFor` is hidden by `ChatController.messages`; the Firestore doc only goes
away once **both** A and B have deleted it. Your own message within the 1-hour
window still uses `deleteMessage` (immediate delete-for-everyone).

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

### `lib/services/giphy_service.dart`

Backs the GIF tab of the composer panel. Trending by default,
`/search` once the user types (debounced 450 ms in `_GifPicker`, so a word is
one request rather than one per letter).

- **Key**: Remote Config `giphy_api_key`. `isConfigured` is false when it is
  blank, and the tab renders a "not set up" note instead of an error — every
  other part of the composer is unaffected.
- **`parseResponse` is pure and lenient** (unit-tested): Giphy omits `images`
  variants unpredictably, so it walks a preference list — small preview for the
  grid, `downsized` for the send — and skips unusable entries rather than
  dropping the whole grid.
- **Sending**: the picker never posts a Giphy URL into the chat. The GIF is
  downloaded to the cache and sent through `ChatController.sendMedia` as a
  normal `MessageType.gif`, so it lives in Firebase Storage like any other
  media and the other phone needs nothing from Giphy.
- **Test seam**: `GiphyService.testMode = true` returns `searchResults`.

**Emoji and stickers need no service.** Emoji come from
`lib/utils/emoji_data.dart` — a curated, categorised list, deliberately not the
full Unicode set (no dependency, no font-coverage surprises). Stickers and GIFs
sent from the system keyboard (Gboard's GIF/sticker key, and any sticker pack
installed from the Play Store) arrive through Android's `commitContent` API,
surfaced by the message field's `contentInsertionConfiguration` and handled by
`_onKeyboardContent` — without that configuration the keyboard greys those keys
out as "not supported".

---

### `lib/services/media_store_service.dart`

Puts every downloaded chat file in one place the user can actually find:
**Internal storage / Download / MyTask**.

Downloads previously went to `getExternalStorageDirectory()` —
`Android/data/com.example.chatapp/files/`. That path is writable without
permission, but it is hidden from Files/My Files on modern Android and is
deleted with the app, which is why saved files appeared to vanish. Images and
videos additionally went to the Gallery via `gal`; that package is gone now, so
chat media no longer lands in the camera roll (which the discreteness
requirement prefers anyway).

The app targets SDK 36, where a plain write into shared storage is ignored, so
the save is done natively:

```
_downloadToMyTask(url, fileName)          ← widgets/bubbles/shared.dart
  ├─ Dio().download(url, <cache>/fileName)         staging copy (for OpenFile)
  └─ MediaStoreService.saveToMyTask(temp, name, mimeType)
        └─ MethodChannel com.example.chatapp/storage → "saveToMyTask"
              └─ MyTaskStorage.java (off the main thread)
                   ├─ API 29+  MediaStore.Downloads insert,
                   │           RELATIVE_PATH = Download/MyTask,
                   │           IS_PENDING while the bytes are copied
                   └─ API ≤28  direct write + MediaScannerConnection.scanFile
```

| Behaviour | Detail |
|---|---|
| Return value | `content://` URI (API 29+) or absolute path (≤28); **null on failure** |
| Failure handling | Callers show "Download failed" — a null must never be reported as saved, since the user would go looking in MyTask for a file that is not there |
| Name clashes | MediaStore renames to `photo (1).jpg`; the legacy path does the same in `uniqueFile()` |
| Opening a file | Uses the staged cache copy — `OpenFile` needs a real path, not a `content://` URI |
| Test seam | `MediaStoreService.testMode = true` records into `savedInTestMode` and never calls the platform |

Used by all four download sites: `_DownloadButton` (photos/GIFs),
`_InlineVideoPlayer._openExternal`, `_FileMessageTile`, `_AudioMessageTile`.

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
| `monthYearLabel(DateTime month)` | "August 2026" — the calendar app-bar title |
| `monthCells(DateTime month)` | The cells of a **Monday-first** month grid as a flat `List<DateTime?>`, padded with nulls to a whole number of weeks. Nulls render as blanks rather than neighbouring months' days, so "which month am I looking at" stays unambiguous |

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
  Future<void> sendMedia(File file, MessageType type, {void Function(double)? onProgress, String? clientId, ...});
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

All chat business logic. Owns six stream subscriptions and the message list,
plus the presence heartbeat timer (20s: re-affirms own `presenceAt` and
re-checks the other side's staleness — a stale heartbeat can't be observed by
a stream listener alone since no new snapshot arrives).

**State managed:**

| Field | Type | Purpose |
|---|---|---|
| `_streamMessages` | `List<Message>` | Latest 50 from Firestore stream |
| `_olderMessages` | `List<Message>` | Prepended via `loadMoreMessages()` |
| `_pendingEntries` | `List<_PendingEntry>` | Optimistic / failed messages, text and media alike. A media entry also carries `sourceFile` (for retry) and `progress` (its upload ring) |
| `_otherReadAt` | `DateTime?` | Drives blue tick display |
| `_otherTyping` | `bool` | Drives typing indicator |
| `_otherOnline` | `bool` | Drives "Online" in app bar |
| `_lastWriteAckAt` | `DateTime` | Last time the backend acknowledged a write — the stuck-write watchdog's liveness signal |

**Stuck-write watchdog (a wedged connection is worse than a broken one).**
The stream self-heal below reacts to an *error*. A wedged Firestore connection
never produces one: it goes **silent**. Writes are accepted into the local
queue and never sent, their futures never complete, no callback fires — so this
phone happily shows its own messages from cache while the other phone receives
nothing at all, not even the presence heartbeat. `presence` stays `true` with a
frozen `presenceAt` and no `lastSeen`, which is the signature to look for in the
room doc. Before this, only an app relaunch recovered it.

The heartbeat doubles as the probe: it runs every `presenceRefreshInterval`
regardless of what the user does, so `_lastWriteAckAt` stops advancing the
moment the connection dies. When nothing has been acknowledged for
`stuckWriteAfter` (60 s = three missed beats), `_checkWriteWatchdog` calls
`IChatRepository.resetConnection()` → `ChatService.resetConnection()`
(`disableNetwork()` then `enableNetwork()`), which rebuilds the connection and
flushes the queued writes. `connectionResetCooldown` (60 s) stops a merely
offline phone from thrashing it. A *failed* write still counts as alive — what
matters is whether the connection answers at all — as does a successful send.
All three durations are injectable for tests.

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

Called on every stream emission where the other person has messages **and the
chat is actually in the foreground** (`!_markReadPaused && !_didLeave`). The
message stream stays live while the app is backgrounded, so without the
`_didLeave` gate an incoming message would mark itself read and advance the
sender's "Read HH:mm" even though this user left and never saw it. `enter()`
calls `_markReadLatestIfNew()` to mark the missed message read on return. At
most one Firestore write per 500 ms regardless of how many messages arrive.

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
| `screens/chat/aurora_background.dart` | Static aurora backdrop, gradient `_SendButton`, `_DateSeparator` chip |
| `screens/chat/attach_option.dart` | Attach sheet: the rounded card (`_AttachSheet`) and its gradient tiles (`_AttachOption`) |
| `screens/chat/emoji_panel.dart` | Emoji grid + GIF picker behind two tabs (`_EmojiGifPanel`, `_GifPicker`). `initialTab` opens it straight on GIF, so the attach sheet's GIF tile does not land the user on emoji |
| `screens/chat/composer_input.dart` | `extension ChatComposerInput` — emoji insert/backspace, GIF send, keyboard sticker handling |
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

### `lib/theme/chat_theme.dart` — visual language

Every colour, gradient, radius and animation duration on the chat and call
surfaces comes from `ChatTheme`. Before this they were raw `Color(0xFF…)`
literals in each file, which is how three files ended up with three different
"panel purple" and the UI drifted into looking flat.

| Group | What is in it |
|---|---|
| Surfaces | `surface0` (page), `surface1` (panels), `surface2` (raised: input pill, chips, incoming bubbles), `hairline` |
| Brand | `violet`, `violetLight`, `violetDeep`, `accent`, `success`, `danger` |
| Text | `textPrimary`, `textSecondary`, `textFaint` |
| Gradients | `myBubble`, `theirBubble`, `appBar`, `sendButton` |
| Glow | `bubbleGlow`, `panelShadow`, `glow(color)` — **tinted** shadows; a violet shadow under a violet bubble is most of what makes it read as lit rather than pasted on |
| Shape | `bubbleRadius` 20, `bubbleTailRadius` 6, `panelRadius`, `pillRadius` |
| Motion | `fast` 140ms, `base` 240ms, `slow` 380ms, `enter` (decelerate), `press` (slight overshoot) |

Two deliberate constraints:

- **The aurora backdrop is static.** `_AuroraBackground` layers three
  off-screen radial pools behind the message list. An animated full-screen
  gradient repaints every frame, and one of the two phones already struggles
  with video decode (§7) — depth is free, continuous motion is not.
- **Motion is attached to interaction.** Bubbles fade+rise as they build
  (140 ms), buttons dip under the finger, the call avatar pulses *only* while
  waiting. Nothing loops behind a conversation.

**Grouped bubbles and date chips** are decided by
`lib/utils/message_grouping.dart` — pure, Flutter-free, unit-tested:

```
layoutMessages(messages) → per message: showDateChip, isFirstInGroup, isLastInGroup
```

Consecutive messages from one sender, within 5 minutes and on the same calendar
day, form one run. Only the **last** of a run draws a tail and the time/status
row, so a burst reads as one block instead of repeating the clock. Runs never
span midnight (a date chip lands between), and call events never join one —
they are centred dividers, and grouping across one would hide a real message's
tail.

---

### `lib/widgets/message_bubble.dart` and bubble parts

`MessageBubble` dispatches to the correct content widget based on `msg.type`:

```dart
Widget _buildContent(Message msg) {
  // Photo/video/GIF with no mediaUrl yet = still uploading: show the local
  // preview (msg.previewPath) under a progress ring instead. Skipping this
  // check is what made the old code throw on `msg.mediaUrl!`.
  if (msg.mediaUrl == null && isVisualMedia(msg.type)) {
    return _UploadPreview(previewPath: msg.previewPath, type: msg.type,
                          progress: widget.uploadProgress);
  }
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
| `call_service.dart` | Backend-agnostic facade — wakelock, overlay geometry, mute/camera/speaker flags, call timer, swappable UI callbacks. Delegates media to a `CallEngine` |
| `call_engine.dart` | The `CallEngine` interface both backends implement |
| `agora_call_engine.dart` | Agora RTC implementation (hosted SFU, billed per minute) |
| `webrtc_call_engine.dart` | Peer-to-peer WebRTC implementation (no per-minute cost) |
| `webrtc_signaling.dart` | Firestore offer/answer/ICE exchange for the WebRTC backend |
| `call_screen.dart` | Full-screen call UI with timer, mute/camera buttons |
| `end_minimized_call.dart` | Hang-up teardown for the mini call bar / floating overlay — the minimized twin of `CallScreen._endCall` |
| `call_avatar.dart` | `PulsingAvatar` — expanding rings while a call is connecting; shared by CallScreen and the incoming-call dialog. Pulse stops once connected |
| `incoming_call_dialog.dart` | Bottom-sheet shown when `callSignal.status == 'ringing'` |
| `agora_token_builder.dart` | Client-side HMAC-SHA256 token builder (Test Mode fallback) |

**Pluggable backend.** `CallService.joinCall()` builds the engine from the
`call_backend` Remote Config key — `agora` (default) or `webrtc`. Anything else
falls back to Agora, so a typo can never leave calling without a backend
(`createEngineForBackend`, unit-tested). The UI is backend-agnostic: it renders
`CallService.localVideoView()` / `remoteVideoView(uid)` rather than any
SDK-specific widget, so neither `CallScreen` nor the floating overlay imports an
SDK. `CallService.activeBackend` records which one the live call is using.

**Why WebRTC is viable here:** the app is always exactly two participants, which
is the one topology needing no media server — the phones connect directly, so
there is no per-minute billing. `isCallCaller` (already set by the existing call
flow) decides which side creates the offer. NAT traversal uses free Google STUN;
two phones on mobile data behind carrier-grade NAT additionally need a **TURN**
relay (`webrtc_turn_*` keys) — without it those calls fail to connect, logged as
`webrtc: connection FAILED`.

**Video encoder profile** — set explicitly in `AgoraCallEngine.join()` (video
calls only): 640×360 @ 15 fps, `standardBitrate`, adaptive orientation, and
`DegradationPreference.maintainFramerate`. The last one is the load-bearing
choice: the SDK default (`maintainQuality`) keeps resolution and drops frames
when a weak encoder chip can't keep up, which froze video on the
lower-capability phone; `maintainFramerate` lowers resolution under load
instead so motion stays smooth. `onLocalVideoStateChanged` /
`onRemoteVideoStateChanged` handlers log failed/frozen states to `app_logs`
for diagnosis (observability only, no behavior).

**Screen wakelock during calls** — two different mechanisms:
- **Audio** calls acquire the native `PROXIMITY_SCREEN_OFF_WAKE_LOCK`
  (`proximity` channel, from `CallScreen`), so the screen turns off when the
  phone is held to the ear.
- **Video** calls instead keep the screen on via `FLAG_KEEP_SCREEN_ON`
  (`call` channel `keepScreenOn`/`allowScreenOff`, driven by
  `CallService.joinCall`/`leaveCall` gated on `videoEnabled`). Tied to the call
  lifecycle, not the widget, so the display stays awake for the whole call —
  full-screen **and** minimized — and is released on every teardown path.
  Without this the OS screen-timeout dimmed/locked the display mid-video-call.

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

The mini bar and floating overlay require **both** flags (`callActiveNotifier
&& CallService.inCall`) — the notifier is a process-wide global that a botched
teardown can leave stale-true, while `inCall` is tied to the actual engine
lifetime. `leaveCall()` also resets `callActiveNotifier` itself, so every
teardown path (error, timeout, remote hangup) hides the call UI.

**Floating overlay geometry** — `CallService.overlayX/Y/W/H` hold the
overlay's position and size, written on every drag/resize and read back in
`_FloatingVideoOverlayState.initState()`. They live in CallService (not widget
State) because returning from CallScreen bumps `_floatingVideoEpoch`, which
recreates the overlay State — local fields would reset the overlay to defaults
mid-call. `joinCall()` calls `resetOverlayGeometry()` so each NEW call starts
at the default small size. A resize drag whose delta is fully absorbed by the
min/max size clamps (size pinned) falls back to a move, so the overlay never
feels "stuck" at its largest size.

**Ending a call — two surfaces, one teardown:**

| Surface | Entry point | What it does |
|---|---|---|
| Full-screen `CallScreen` | `_endCall()` | Writes the callEvent (caller only), sets `callSignal.status = ended`, then `CallService.leaveCall()` and pops |
| Mini call bar / floating video overlay | `endMinimizedCall()` (`features/call/end_minimized_call.dart`) | Same three steps, minus the navigation |

Both build the chat entry with `callEndEventText()`
(`utils/call_event_text.dart`) so the two paths cannot word it differently.
Missed vs. ended is decided by `CallService.connectedAt` — the timestamp of
the first remote join, which (unlike `currentRemoteUid` or CallScreen's
`_callConnected`) is *not* cleared when the peer leaves, so a teardown
triggered by the remote hang-up still knows the call was answered.
`connectedAt` is cleared in `joinCall()` and `leaveCall()`.

**Foreground service:** `CallScreen` invokes `startForeground` on a platform
channel so Android keeps the process alive while a call runs in the
background; the matching `stopForeground` is issued centrally by
`CallService.leaveCall()`, so it fires on *every* teardown path. Native side:
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
- Drag from the bottom-right 36×36 corner handle → resizes (80–260 × 100–340).
  The handle is its own `GestureDetector` (`HitTestBehavior.opaque`, with an
  empty `onTap` that absorbs taps), not a painted hint the parent hit-tests —
  otherwise grabbing the corner falls through to restore-on-tap and throws the
  user into the full-screen call.
- Fast upward flick (velocity < −600 px/s) → restores full-screen call
- Tap → restores full-screen call, but only when the gesture did not move the
  overlay (`_moved`). Position alone NEVER triggers restore — an earlier
  `_y < 35% of screen` check fired on every drag release because the overlay
  starts at y=80.

> Testing gestures here: drag in **small steps** (`startGesture` + repeated
> `moveBy`). A single big `tester.drag` move is swallowed as the pan
> recognizer's slop and never reaches `onPanUpdate`.

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
| `scheduleReminder({id, title, scheduledTime, recurrence})` | Scheduled notification. `recurrence: Recurrence.none` (default) = one-shot; `daily`/`weekly` repeat natively via `matchDateTimeComponents`; `weekdays`/`weekends` schedule one weekly notification per day under ids derived from `id`. Returns `false` if any schedule fails |
| `cancelReminder(int id)` | Cancels a single scheduled notification |
| `cancelReminderGroup(int baseId)` | Cancels `baseId` + all 7 weekday-derived ids + all `maxDailySlots` interval slot ids — use for reminders that may be recurring |
| `docNotifId(String docId)` | The notification id a Firestore reminder doc is armed under by the delivery paths (`docId.hashCode.abs() % 0x7FFFFFFF`). **Single definition** — see the two-id-families note below |
| `showDigest({id, title, body})` | BigText checklist notification for the daily digest ([DigestService]) |
| `showNow({id, title, body})` | Immediate notification — used by the FCM handler for the "Reminder set" confirmation |

`NotificationService.testMode = true` makes everything a no-op in tests.

**Recurrence** (`lib/models/recurrence.dart`): the repeat is owned by the OS
(AlarmManager), so it survives app-kill and reboot. The day/time come from the
task's picked due date. Weekdays/weekends have no native equivalent, so they
become several `dayOfWeekAndTime` weekly notifications — hence `cancelReminderGroup`.
Recurrence is stored both locally (SharedPreferences todo list) **and** on the
reminder doc, and rides along in the FCM payload — so a repeating reminder sent
to the other person arms as the same repeat on their phone, and a repeat change
on either side of a shared task reaches the other.

**Two notification-id families — cancel both.** A reminder can be armed under
*two different ids*:

| Armed by | Under id |
|---|---|
| The todo screen (`_setReminder`, `_rearmReminders`) | `todoId.hashCode`, **plus** derived ids: weekday `(base % 1e8) * 10 + wd` for weekdays/weekends, and slot `(base % 1e6) * 1000 + 100 + i` for interval rules |
| The delivery paths (FCM handler, WorkManager worker, `pendingStream`) | `NotificationService.docNotifId(reminderDocId)` |

`cancelReminderGroup(baseId)` clears the base plus **both** derived families
(7 weekday ids + `maxDailySlots` slot ids) precisely because the caller usually
no longer knows what the reminder used to be. Missing the slot family would
leave an "every 90 minutes" reminder nagging all day after it was cleared —
covered by `test/services/notification_service_test.dart`.

A task received from the other phone hits *both*: the delivery path arms it
under the doc id, and its local copy (`id = "reminder_<docId>"`) would be armed
under the todo-id hash on the next launch. So **every** re-arm / re-time /
delete path must clear both families — `_rearmReminders`, `_setReminder`,
`_delete` and `ReminderService._cancelNotificationsFor` all do. Missing the
second cancel is what made received reminders fire twice (§7).

**Re-arm on launch** (`screens/todo/todo_reminders.dart`): Android clears an
app's scheduled AlarmManager alarms when the APK is **updated** (the boot
receiver only restores them on reboot). So `_TodoScreenState.initState` calls
`_rearmReminders()` once after the todo list loads — it re-schedules every
still-pending local reminder (future one-shots + all recurring; elapsed
one-shots and done tasks are skipped so nothing re-fires). Without it, updating
the app would silently drop pending reminders until each was re-set. Tests
assert this via `NotificationService.debugScheduled` (a `@visibleForTesting`
record of `scheduleReminder` calls made while `testMode` is on).

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
| `fetchPending(forUser, roomId)` + `markScheduled(docId, roomId)` | Background path — WorkManager worker picks up unprocessed docs every 15 min. The FCM push handler (`_processReminderPayload`) also calls `markScheduled` right after scheduling, so delivery confirmation flips to "Delivered" immediately instead of waiting for the next worker run |
| `insertTodoToPrefs(prefs, r)` | Inserts the task into B's local list (id `reminder_{docId}`, duplicate-guarded, `sharedId` linked) |

The third delivery path is FCM push (see FcmService below) — so B gets the
reminder whether the app is open, backgrounded, or killed.

**Shared-task sync (tasks created with "Add to notify task list"):**

The reminder doc is the source of truth. Both devices link their local copy
via a `sharedId` field (legacy `reminder_*` IDs are backfilled automatically).

| Method | Role |
|---|---|
| `updateSharedTask(docId, {title, scheduledAt, done, subtasks})` | Local edits write through to the doc. Adding/toggling/deleting a sub-task on a `sharedId` task pushes the whole subtask list (last-write-wins) |
| `deleteSharedTask(docId)` | Deleting on either phone deletes for both |
| `outgoingDeliveryStream()` | Live `{docId: locallyScheduled}` for reminders THIS phone sent (`createdBy==me`, `forUser!=me`) — the todo tile shows "Delivered" once the value flips true. Index-free (single `createdBy` filter; `deliveryMapFromDocs` splits `forUser` in memory) |
| `sharedTasksStream()` | Live mirror — main.dart listener applies remote changes within seconds |
| `fetchSharedTasks(roomId)` | Server-forced one-shot for the background worker (offline throws instead of returning a partial cache) |
| `applySharedSnapshot(prefs, docs, {applyDeletes})` | The reconcile: applies title/done/dueDate/subtasks changes, removes deleted tasks, reschedules notifications |

**Reconcile safety rules:**
- Deletions apply only from **server-confirmed** snapshots (`applyDeletes` =
  `!snapshot.isFromCache`) — an offline cache can never mass-delete tasks
- Remote due-date changes apply only to copies that already track a due date,
  and only a copy with `remindsMe` re-arms an alarm — a creator who declined
  "Remind me" sees the new time on their calendar but never gets a surprise
  notification when the other side moves it
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

Two payload types arrive here:

| `data.type` | Foreground | Background isolate |
|---|---|---|
| `reminder` | `_processReminderPayload` — confirmation + schedule + optional list insert | same |
| `message` | Bumps `chatRefreshNotifier` → `ChatController` re-subscribes its stream if the listener didn't deliver (see §11 `onMessageCreated`) | Nothing, by design — waking the process is the point; the notifier belongs to the UI isolate |

A `message` push **never displays anything** (no `notification` block is sent)
and carries no text or sender. It exists so chat delivery does not depend on a
live Firestore listener inside a live process.

The pushes themselves are sent by the `onReminderCreated` and
`onMessageCreated` Cloud Functions (§11).

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
5. DigestService.maybeShowDigest() → the daily task summary (see below)
```

Being a separate isolate it shares NO memory with the app — everything goes
through SharedPreferences and Firestore.

### `lib/services/digest_service.dart`

The **daily task summary** — a free, fully on-device replacement for the
removed WhatsApp digest. Once a day, at or after the user's chosen local time,
a single local notification (via `NotificationService.showDigest`, a
`BigTextStyle` so it expands) lists the day's not-done tasks as a ☐ checklist.

Driven entirely by the background worker's `maybeShowDigest()` — no server, no
account. State lives in SharedPreferences: `digest_enabled` (bool),
`digest_hour` / `digest_minute` (int, local wall clock), and
`digest_last_shown` ("YYYY-MM-DD"). The last-shown guard means it fires at most
once per day and a missed slot catches up on the next worker run the same day.
Configured in-app via the app-bar bell (`_showDigestSettings`). Because it
rides the ~15-min WorkManager worker, it appears within one interval of the set
time — good enough for a morning summary, and subject to the same OEM
battery-optimization caveats as the reminders themselves.

`titlesFor` / `buildBody` are pure (unit-tested); `maybeShowDigest` is the
worker entry point. Both parse through `TaskStore.decode`, so they read either
storage format — and `maybeShowDigest` falls back to `TaskStore.legacyKey`
when the worker runs before the screen has ever migrated the list.

---

### `lib/screens/todo_screen.dart`

The home screen — a personal to-do list with cross-device features.

Split into `part` files under `screens/todo/` to stay approachable:
`todo_theme.dart` (the dark-violet palette + dialog/picker helpers, mirrored
from the chat screen so both halves feel like one product), `todo_tile.dart`
(the `_TodoTile` card + sub-task rows), `todo_widgets.dart` (header stats,
empty/no-results/section-header, input bar, `_EditTaskDialog`),
`todo_dialogs.dart` (the `setState`-free `_showDigestSettings` /
`_pickDateTime` / `_askSetReminder` / `_showRoleResetDialog` as an extension),
and `todo_reminder_dialog.dart` (the `_SetReminderDialog` widget plus the
`_armLocalReminder` / `_persistReminderDoc` extension behind it).
The task model is **not** a part file any more — `todo_models.dart` is gone and
`Task`/`SubTask` live in `lib/models/task.dart`, so they can be unit-tested and
used by the services. `_TodoScreenState`
keeps all state and orchestration; the tile widgets route mutations back
through callbacks (they can't call `setState` directly). The screen renders a
dark theme (gradient app bar, `_kTodoBg` scaffold, `_kTodoCard` tiles) with all
dialogs/pickers themed dark explicitly, independent of the system light/dark
setting.

| Feature | How |
|---|---|
| Add task | Bottom input bar → "Set a reminder?" prompt → unified Set Reminder dialog |
| Rename task | **Long-press** the tile → Edit Task dialog (shared tasks push the new title to the other phone) |
| Complete / delete | Checkbox / swipe-left — both write through to Firestore for shared tasks |
| Sub-tasks | Expand a tile → add/check/delete/**rename** (tap the text or pencil); progress bar on the tile. Shared-task sub-task edits sync both ways |
| Search | AppBar search icon — filters by title and subtask text |
| Reminders | One alarm button per task → date/time picker → unified dialog (incl. a Repeat picker) |
| Delivery confirmation | A reminder you send the other person shows **"Not delivered"** → **"Delivered"** once their device receives and arms it (`locallyScheduled` flips true). Both the FCM push handler and the 15-min worker flip it, so "Delivered" appears as soon as their phone processes the push — not only on the next worker run. "Actually fired" isn't tracked — Android has no reliable background "notification shown" callback |
| Recurring reminders | Repeat = Every day / **Every hour** / **Every 90 minutes** / **Every 2 hours** / Every week / Weekdays / Weekends (`Recurrence`); tile shows the repeat label. Still no "every N *days*" or monthly (those need reschedule-on-fire). **Syncs cross-device**: written to the reminder doc, carried in the FCM payload, and mirrored both ways for shared tasks. "done" keeps repeating until Repeat = None or the task is deleted |
| Intra-day intervals | An interval rule is **not** a new kind of alarm. `Recurrence.daySlotMinutes(h, m)` expands it into one *ordinary daily* notification per slot — 08:00 with `every90m` gives 08:00, 09:30 … 21:30 — each repeating natively, so the OS still owns every repeat and they survive reboot and app-kill like any other. Slots stop at `Recurrence.dayEndMinutes` (22:00) so nothing fires overnight; a time picked past the cutoff still fires once rather than scheduling nothing |
| Clearing a reminder | Re-open the dialog and untick **both** boxes → the local alarm is cancelled and `start`/`recurrence` cleared ("Reminder cleared") |
| Notify without "Remind me" | The task **keeps the time** (so your calendar shows the reminder you set for them) but `remindsMe` goes false: no alarm on this phone, no daily-digest entry, and the tile reads "· no alarm here" instead of showing an armed bell |
| Calendar | AppBar calendar icon → [`CalendarScreen`](#libscreenscalendar_screendart-and-part-files), a month view over these same reminders. The list reloads on return, since the calendar can add/edit/delete |
| Open chat | Type `flutter` in the add-task field (hidden trigger) |
| Role reset | Debug builds: double-tap the AppBar title |

**Unified Set Reminder dialog** (single entry point `_setReminder`):

```
Pick date/time → dialog:
  ☑ Remind me            (pre-checked — local notification on this phone)
  ☐ Notify               (creates a reminder doc → FCM push to other phone)
      ☐ Add to notify task list   (only visible when Notify is checked;
                                   makes it a synced shared task)
```

Tasks persist as JSON in SharedPreferences under **`todos_v2`**, via
[`TaskStore`](#libservicestask_storedart) — which also migrates the old
`todos_v1` list on first read. `todoRefreshNotifier` (in constants.dart)
signals the screen to reload when a remote task arrives or the shared-task
mirror changes something.

---

### `lib/screens/calendar_screen.dart` and part files

A month view over **the same reminders the todo list shows** — opened from the
calendar icon in the todo AppBar. Deliberately not a separate "events" feature:
it reads and writes the very same `Task` list through `TaskStore`, so anything
added here appears on the todo screen and vice versa. There are no start/end
times, durations or all-day events; a task is a title plus one instant.

Split into `part` files under `screens/calendar/`: `calendar_grid.dart` (the
`_OwnerFilter` tick boxes + `_MonthGrid`), `calendar_day_list.dart` (the
selected day's `_DayTimeline`), and `calendar_edit.dart` (the add/edit/delete
mutations as an extension, plus the `_TaskEditDialog` widget).

| Feature | How |
|---|---|
| Month grid | Monday-first, built from `monthCells()`. Up to three dots per day for the reminders on it; today is outlined, the selected day filled |
| Day timeline | Tap a day → a 24-hour ruler with each reminder drawn at its own time (`_DayTimeline`) |
| Add | FAB → title / time / repeat → creates a task on the **selected** day, stamped `createdBy: mySenderId` |
| Edit | Tap a row → same dialog. Re-arms the alarm and writes through to the reminder doc for shared tasks |
| Complete / delete | Checkbox / swipe-left — both write through, exactly like the todo screen |
| Month navigation | Chevrons step a month; **Today** returns to the current month and selects today |
| Mine / Theirs | Tick boxes filtering by `Task.isMine(mySenderId)` |

**The day view is a timeline, not a list.** `_DayTimeline` draws a 24-hour
ruler (`_kHourHeight` = 64 px per hour, hour labels in a `_kGutter`-wide left
column) and positions every reminder at `(hour * 60 + minute)` on it, so the
time is spatial and the shape of the day is visible at a glance. Details worth
knowing before editing it:

- **Auto-scroll on open.** `_scrollToAnchor` (post-frame, so the scroll view
  has clients) lands on *now* for today, the first reminder for any other day,
  else 08:00 — anchored a third of the way down the viewport so what is coming
  next is on screen. The screen keys `_DayTimeline` on the selected day, so
  choosing another day remounts it and re-anchors.
- **A live now line**, redrawn by a one-minute `Timer.periodic` (cancelled in
  `dispose`). Both it and the hour ruler sit inside a `Positioned.fill`
  `IgnorePointer` — they span the full width and would otherwise swallow taps
  meant for the cards they cross.
- **Overlapping reminders split into lanes.** `_layoutDay` groups cards whose
  fixed `_kCardHeight` boxes overlap into clusters and hands each a lane,
  reusing a lane as soon as its previous card ends — so two reminders at the
  same time sit side by side instead of one hiding the other. Tasks have no
  duration, so every card is the same height; only its position means anything.
- Tap edits, swipe-left deletes, the checkbox completes — the same gestures as
  the todo tiles. A `remindsMe: false` reminder carries a muted-bell icon.

**Repeating reminders are expanded for display only.** `Task.occursOn(day)`
decides which days a task is drawn on (daily → every day from its start;
weekly → the start's weekday; weekdays/weekends → those days), and
`occurrenceOn(day)` places the start's time-of-day on that date. Nothing here
schedules anything — the alarms stay owned by AlarmManager via
`NotificationService`, which repeats them natively. The two therefore can't
drift into disagreeing about when a reminder *fires*; they only agree on which
days to *draw*.

**Editing a repeat moves the whole series.** The model has no per-occurrence
overrides, so `_editTask` keeps the task's original start *date* and changes
only the time — otherwise editing a reminder from a day you happened to be
viewing would silently move the series to that day.

**The Mine/Theirs filter only spans what is already on this device**: your own
tasks plus ones explicitly shared ("Add to notify task list"). Ticking
**Theirs** shows reminders that *involve the other person* — **not** their whole
list, which this device never receives. The last ticked box cannot be cleared,
so the calendar is never inexplicably empty. `isMine` treats a null `createdBy`
as mine (see §5 `Task`), so tasks stored before that field existed don't vanish
under the filter.

**The two boxes overlap on purpose.** A task is matched by `isMine` *and*
`involvesOther` independently, and shows if **either** ticked box matches:

| Reminder | Mine | Theirs |
|---|:--:|:--:|
| Set for yourself | ✓ | |
| Set for them, added to their list (`sharedId`) | ✓ | ✓ |
| Set for them, "Remind me" off (`remindsMe` false) | ✓ | ✓ |
| Arrived from their phone (`createdBy` is them) | | ✓ |

Filing each task under exactly one box — by its **creator** — meant a reminder
you set *for* them was Mine only, so unticking Mine to review what you had set
for them showed nothing. That is the one place you would look, so it read as
the reminder never having been created. `involvesOther` is deliberately not the
negation of `isMine`: a reminder you set for them rings on your phone *and*
lives on their list, so it genuinely belongs to both. The day row says which —
**· for them** when you set it, **· from them** when they did.

---

### `lib/theme/app_palette.dart`

The dark-violet palette, shared by every screen. It used to live as private
`_kTodo*` constants inside `screens/todo/todo_theme.dart` — a `part` file, so
nothing outside the todo screen could reach it. The todo parts still refer to
the old private names, now aliased to these, so the move is behaviour-neutral
and no todo call site changed.

---

### `lib/screens/calls_screen.dart` + `lib/services/call_log_service.dart`

- `CallsScreen` — the "Calls" tab inside ChatScreen: renders call history from
  `ChatService.callEventsStream()` (call-event messages in the messages
  collection), with audio/video call buttons. `callsStream` parameter is the
  test seam.
- `CallLogService.init()` — requests phone/contacts permissions on startup
  and syncs the device call log to Firestore (runs last in startup so its
  permission dialogs don't block the app).
- **Two cadences, and why.** This collection is **write-only** — nothing in the
  app reads `app_call_log_{role}` (the Calls tab renders `callEvent` *messages*),
  so it is a Firestore archive with no UX latency requirement. It must therefore
  never compete with the chat, which shares the same Firestore client and the
  same **ordered write queue**:

  | Path | Gap | Does |
  |---|---|---|
  | Ordinary sync | `_minSyncGap` = 6 h | Scans the device log from the `callLogSyncedUpToMs` high-water mark and uploads what is new. **No Firestore read at all** — past the mark nothing has been uploaded yet |
  | Reconcile | `_reconcileGap` = 24 h | Re-scans the whole 30-day `_window`, reads the existing doc IDs, uploads the missing ones |

  The reconcile is what preserves #82's guarantee: doc IDs are stable
  (`docIdFor` = `<ts>_<type>_<number>`), so re-scanning **restores logs deleted
  externally** — e.g. by the cleanup script — idempotently. Only the last 30
  days repopulate; older deleted history stays gone. It now happens within a
  day rather than within a minute.

  `windowStartMs`, `shouldSync` and `shouldReconcile` are pure and unit-tested;
  the throttle state is persisted (`callLogLastSyncAtMs`,
  `callLogReconciledAtMs`) so a relaunch doesn't reset it. Note
  `callLogLastSyncAtMs` is **not** the old `callLogLastSyncMs` watermark removed
  in #82 — it only throttles; what was already uploaded is tracked separately by
  `callLogSyncedUpToMs`, which is safe because the reconcile re-checks Firestore.
- **Sync on resume:** `init()` (cold start) requests permission then syncs;
  `TodoScreen` (the always-present home) calls `CallLogService.sync()` on
  `AppLifecycleState.resumed`. It is a no-op without permission (never pops a
  dialog) and, thanks to the gap above, a no-op almost every time.

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
        ├─ _PendingEntry(clientId, message: previewPath=file.path, progress: 0)
        │       → notifyListeners()  ← bubble with local preview appears instantly
        │  (video: VideoCompress.getFileThumbnail fills previewPath a moment later)
        │
        └─ _upload(entry)
                ├─ video only: VideoCompress.compressVideo(...)
                └─ repo.sendMedia(file, type, clientId, onProgress: (p) {
                       entry.progress = p; notifyListeners();  ← ring on THAT bubble
                   })
                        │
                        ├─ file.readAsBytes() → rawBytes
                        ├─ Storage.ref("chats/{roomId}/{uuid}.jpg").putData(rawBytes)
                        │       snapshotEvents → onProgress(bytesTransferred / totalBytes)
                        ├─ ref.getDownloadURL() → mediaUrl
                        └─ messages.add({type, mediaUrl, clientId, fileSize, ...})
                                │
                                ▼
                     stream emits the doc → clientId matches → _PendingEntry
                     dropped, bubble switches to the uploaded media
```

Uploads are **optimistic, like text** (§6.1) and share the same
`_PendingEntry` / `clientId` confirmation machinery — hence `clientId` on media
docs too. Consequences:

- The composer is never disabled. It used to be: a single `_uploadProgress`
  field drove a screen-wide "Uploading… 42%" banner and `sending` greyed out
  the send button, so no text could be sent until the file finished.
- Progress is per message (`ChatController.uploadProgressFor(messageId)`), so
  several uploads can be in flight at once, each with its own ring.
- `Message.previewPath` is the local image shown until `mediaUrl` exists — the
  picked file for a photo, a generated thumbnail for a video. It is
  **client-side only**: never written to or read from Firestore.
- A failed upload keeps its bubble in `failedIds`; `retryMessage()` re-uploads
  from `_PendingEntry.sourceFile` instead of re-sending it as text.

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

A's `CallScreen` rings the other side and joins its own engine in parallel
(see the comment on `_startCall()` in `call_screen.dart` — gating the ring on
`joinCall()` finishing first used to eat the whole 20s setup window). So A's
side of the flow is really two independent things happening at once: joining
the media engine, and watching `callSignal` to drive the "Calling.../
Ringing.../Connecting..." label via `interpretCallSignal()`
(`utils/call_signal_interpreter.dart`):

```
A taps "Video Call"
        │
        ▼
ChatService.signalCall('video', token: agoraToken)
  room.set({callSignal: {from:'A', type:'video', status:'ringing',
                          delivered:false, token: ...}})
CallScreen(isCaller:true) joins its own engine + subscribes to callSignalStream
  label: "Calling..."
        │
        ▼ (on B's device)
callSignalStream() emits {status: 'ringing', delivered:false}
        │
        ▼
ChatScreen listener calls ChatService.markCallDelivered() → shows IncomingCallDialog
  room.update({'callSignal.delivered': true})
        │
        ▼ (on A's device)
callSignalStream() emits {status:'ringing', delivered:true}
A's CallScreen: interpretCallSignal → CallSignalEvent.delivered
  label: "Ringing..."
        │
   ┌────┴────┐
   │Accept   │Decline
   ▼         ▼
updateCallStatus('accepted')    updateCallStatus('declined')
Navigator.push(CallScreen           dialog dismissed
  (isCaller:false)) — its own
  label is always "Connecting..."
  until its engine's onUserJoined
        │                            │
        ▼ (on A's device)            ▼ (on A's device)
callSignalStream() emits            callSignalStream() emits
  {status:'accepted'}                 {status:'declined'}
A's CallScreen: interpretCallSignal  A's CallScreen: interpretCallSignal
  → CallSignalEvent.accepted           → CallSignalEvent.declined
  label: "Connecting..."               → _endCall(errorMsg:'Call rejected')
        │                               → SnackBar + Navigator.pop back to chat
        ▼
Both devices: CallService.joinCall(videoEnabled, token, ...)
onUserJoined fires on both → _callConnected=true → label replaced by duration
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
A: task → alarm button → picks time → checks "Notify" (+ "Add to notify task list")
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
        ├─ title/done/dueDate/subtasks applied to the linked local task
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
| Call logs don't repopulate in Firestore after a cleanup / bulk delete | (Fixed) `_sync` only uploaded calls newer than a local `callLogLastSyncMs` marker, which assumes the Firestore data still exists — so externally-deleted logs never came back | Sync re-scans a rolling 30-day window and uploads any doc IDs missing from `app_call_log_{role}` (idempotent via stable `docIdFor`); deleted logs within the window restore on the next app launch. (Also confirm the phone/call-log permission is granted — a denied permission skips the sync entirely.) |
| Local reminders/tasks vanish after uninstall + reinstall | (Fixed) The todo list lived only in SharedPreferences, which the OS wipes on uninstall | Each save mirrors the full list to `rooms/{room}/todoBackups/{role}` (`ReminderService.backupTodos`); on a fresh install `_loadTodos` restores from it when local is empty (`fetchTodoBackup`). Role is reclaimed via ANDROID_ID so the right backup is picked |
| Screen dims / locks during a video call | (Fixed) Only audio calls held a wakelock (proximity); video calls held none, so the OS screen-timeout fired | `CallService.joinCall` sets `FLAG_KEEP_SCREEN_ON` (native `call` channel `keepScreenOn`) for video calls; `leaveCall` clears it. Spans full-screen + minimized |
| Call drops when app goes to background | (Fixed) ChatScreen's leave-timer popped CallScreen; `callActiveNotifier` only covers minimized calls | `CallService.inCall` (true for the whole call) added to both pop guards |
| Reminder notification shows time 5:30 h off | (Fixed) FCM payload timestamps are UTC; formatting without `.toLocal()` printed UTC wall-clock | `parseReminderTimestamp()` converts at the single parse point |
| Can't send a message while a photo/video is uploading; nothing to look at but a banner | (Fixed) `sendMedia` set one screen-wide `_uploadProgress`, and the send button was disabled whenever `sending` (`_uploadProgress != null`) was true | Media is sent optimistically like text: the bubble appears at once with a local preview and its own progress ring (`uploadProgressFor(messageId)`), and the composer is never gated. See §6.2 |
| Read ticks appear on just-sent messages | (Fixed) Optimistic messages use the local clock; device clock behind server time made `otherReadAt` look newer | `_isRead` returns false while `isPending` |
| "Read HH:mm" time changes on already-read messages after the reader restarts the app | (Fixed) The read guard `_lastSeenOtherMsgId` was in-memory only; on restart it reset to null, so re-opening a chat with no new messages re-fired `markRead()` and re-stamped `readAt` | Persist the last-read message id per room (`ChatService.get/setLastReadMsgId`, key `lastReadMsgId_{chatRoomId}`); `ChatController.init()` restores it so an idle re-open never advances `readAt` |
| Sender sees "Read HH:mm" advance while the reader is away (offline) | (Fixed) `leave()` (app backgrounded) cleared presence but did not pause read receipts, and the message stream stays live — so an incoming message hit `_subscribeMessages` and advanced `readAt` even though the reader had left | Gate auto-mark-read on `!_didLeave` too; `enter()` calls `_markReadLatestIfNew()` to mark the missed message read on return |
| Presence flips offline during WhatsApp call overlay | Some devices fire only `inactive` for overlays | 8s debounce timer on `inactive` (`??=` so it never restarts mid-sequence) |
| "online" stuck forever after force-kill / crash | (Fixed) `presence` boolean was only cleared by in-memory debounce timers; a killed process never runs them, and Firestore has no onDisconnect | `presenceAt` heartbeat re-stamped every 20s while chat open; reader shows "online" only while heartbeats keep arriving (45s stale window, measured by local receive time — clock-skew immune). `ChatController.dispose()` also leaves as defense-in-depth |
| One phone receives no messages for minutes; `readAt` frozen, `presenceAt` updating only sporadically, `typing` still working | The app's process is being **killed by the OS** (OEM battery management), or its `messages` watch target died silently. Chat had no push path at all — delivery depended entirely on a live listener in a live process, so a killed app received nothing until reopened. **How to confirm:** `node scripts/peek.js` — repeated `App: Started — role: X` lines minutes apart in `app_logs` mean the process is being killed, not that Firestore is broken | `onMessageCreated` (§11) sends a silent, data-only FCM push to the other phone on every message: it wakes a killed process, and in the foreground it makes `ChatController` re-subscribe a stream that stopped delivering. **Also exempt the app from battery optimisation on that phone** (Settings → Apps → Battery → Unrestricted) — no code can keep a killed process alive |
| One phone's messages never reach the other, and its presence heartbeat stops, with no error anywhere | (Fixed) The self-heal in the row below only fires on a listener **error**. A wedged Firestore connection instead goes *silent*: writes queue locally and are never sent, their futures never complete, and no callback runs — so the sending phone shows its own messages from cache and looks fine. Seen again right after a bulk deletion of `messages` / `app_call_log_*`. **Signature in the room doc:** `presence.X == true`, `presenceAt.X` frozen minutes ago, no `lastSeen.X` | `ChatController` watches whether writes are still being acknowledged (the presence heartbeat is the probe) and calls `ChatService.resetConnection()` — `disableNetwork()` + `enableNetwork()` — after `stuckWriteAfter`, which rebuilds the connection and flushes the queue. Cooldown-limited so an offline phone doesn't thrash it. Diagnose with `node scripts/peek.js` |
| Messages and call signals arrive ~10 s late, everywhere, regardless of screen | (Fixed) `CallLogService.sync()` ran on **every app resume, throttled only to 1/min**, and each run did a 30-day Firestore read (hundreds of docs) plus — right after the cleanup script deleted `app_call_log_*` — a several-hundred-document batch write. Firestore commits pending writes **in order on one queue per client**, so a chat message sent during that window waited behind the batch | Ordinary syncs run at most every 6 h from a persisted high-water mark and do **no** Firestore read; the full 30-day reconcile that restores externally deleted logs runs at most daily. See the CallLogService section in §5 |
| Chat frozen (no new messages / presence / read receipts) until app restart — often after a bulk server-side deletion | (Fixed) A Firestore listener error was fatal: the room stream did `_roomBcast.addError(...)`, which cancelled the presence/typing/readAt listeners (they have no `onError`), and the message stream had no `onError` either — so any listener drop wedged the chat permanently | Both streams now **self-heal**: `ChatService._listenRoom()` logs and re-subscribes instead of forwarding the error downstream; `ChatController._subscribeMessages` re-subscribes after `messageResubscribeDelay` (2s, injectable). No restart needed |
| Overlay drag snapped back to full screen | `_y < 35% of screen` was always true (overlay starts at y=80) | Restore only on tap or upward flick; corner handle resizes |
| No way to send emoji, GIFs or Play Store stickers | (Added) The composer had a text field and an attach menu, nothing else. Flutter text fields also reject keyboard-inserted images unless configured, so Gboard greyed out its GIF/sticker keys | Emoji/GIF panel behind a smiley button (`_EmojiGifPanel`), and `contentInsertionConfiguration` on the message field so keyboard stickers/GIFs insert and send. GIF search needs `giphy_api_key` in Remote Config |
| Received photos take seconds to appear, every time you scroll back | (Fixed) The bubble used `Image.network`, which has **no disk cache** — so scrolling back re-fetched the whole file from Storage — and decoded at full resolution: a 12 MP photo decoded into memory to be drawn 220 px wide | `CachedNetworkImage` with `memCacheWidth`/`maxWidthDiskCache` capped at the bubble's real pixel size, plus a placeholder tile so the bubble holds its shape while loading |
| A received video shows a blank tile until it is opened | (Fixed) There was nothing to show without initialising a network `VideoPlayerController` purely to obtain a first frame | The sender already generates a preview frame for its own upload bubble; it is now uploaded next to the video (`chats/{room}/{id}_thumb.jpg`) and stored as `thumbUrl`, so the receiver paints the frame immediately. Videos sent before this fall back to the old tile |
| The message field is cramped; the composer icons eat the width | (Fixed) Two default `IconButton`s sat outside the pill, each reserving a 48×48 tap target plus its own padding | The attach button is hand-sized (40×40, zero padding) and the emoji button moved **inside** the pill as a `prefixIcon`, freeing a whole slot for text |
| Tapping GIF in the attach sheet lands on the emoji tab | (Fixed) The tile only opened the panel, which always started at index 0 | `setShowEmojiPanel(true, onGifTab: true)` → `_EmojiGifPanel.initialTab`. The panel is keyed on the tab so re-opening on the other side rebuilds it — `TabController.initialIndex` only applies at construction |
| The GIF panel wastes vertical space | (Fixed) Default tab-bar height and search-field padding, in a panel that replaces the keyboard | Tab bar 38→30 px with zero label padding, tighter search field and grid insets |
| Attach sheet tiles are enormous / the sheet overflows the composer | (Fixed) `GridView.count` with `childAspectRatio` derives tile **height** from screen width, so a wide layout produced 226 px tiles and a RenderFlex overflow | `SliverGridDelegateWithMaxCrossAxisExtent` with an explicit `mainAxisExtent` pins row height independently of width. Tile labels are `maxLines: 1` |
| A downloaded photo/video/file cannot be found anywhere on the phone | (Fixed) Downloads went to `getExternalStorageDirectory()` = `Android/data/com.example.chatapp/files/`, which modern Android hides from file managers and wipes on uninstall. Only images/videos escaped it, via `gal`, into the Gallery | Everything is exported to **Download/MyTask** through MediaStore (`MediaStoreService` → `MyTaskStorage.java`). The cache copy is kept only so `OpenFile` has a real path to open. A failed export now says "Download failed" instead of silently reporting success |
| Grabbing the pip's resize corner opens the full-screen call instead | (Fixed) The corner was only a painted hint; the parent `GestureDetector` hit-tested the whole overlay, so a touch there that didn't travel far enough to win the pan arena was delivered as a tap → restore | The handle is its own opaque `GestureDetector` owning the resize pan, with an empty `onTap` that absorbs the touch, and is 36×36 instead of 24×24. The parent additionally refuses to restore when the gesture moved the overlay (`_moved`) |
| Overlay "stuck" — won't move when enlarged | (Fixed) Resize mode latched at pan-down; at max size the clamps absorbed every delta, so the drag neither resized nor moved | Resize gesture falls back to move when the size is pinned at its clamp bounds |
| Overlay resets to small size after returning from CallScreen | (Fixed) Geometry was widget State, wiped by the `_floatingVideoEpoch` key-bump reconstruction | Geometry hoisted to `CallService.overlayX/Y/W/H`; reset only in `joinCall()` (new call) |
| Hanging up from the mini call bar or floating video overlay leaves no trace in the chat | (Fixed) Those two surfaces only flipped `callActiveNotifier` and called `leaveCall()` — no callEvent was written and `callSignal.status` was never set to `ended`, so the same call cut from the full screen logged an entry while one cut from the minimized UI logged nothing | Both surfaces call the shared `endMinimizedCall()` (`features/call/end_minimized_call.dart`), which mirrors `CallScreen._endCall`: callEvent + status + `leaveCall()` |
| A call ended from the pip **still** leaves no entry in the chat | (Fixed, second pass) `endMinimizedCall` was wired to both minimized surfaces, but only the **caller** writes the entry — and `CallScreen._minimize` installed an `onCallEnded` that tore down *silently*. So when the callee hung up while the caller sat minimized, neither side logged it | `_minimize` routes the remote hang-up through `endMinimizedCall()` too. Exactly one write still happens per call (the callee's own path no-ops the write), now guarded against two teardowns racing |
| Foreground-service notification ("MyTask — Running") stays in the tray after the call ends | (Fixed) `stopForeground` was invoked only from `CallScreen`, so ending from the mini bar/overlay — or any dispose path that skipped `_endCall` — never stopped the service | `CallService.leaveCall()` invokes `stopForeground` centrally, alongside the screen-wakelock release it already owned |
| The caller's chat logs an answered call as "Missed" when the other side hangs up first | (Fixed) `_endCall` picked the wording from `_callConnected`, which the `onUserLeft` handler sets to false immediately before calling it | Wording comes from `callEndEventText()` keyed on `CallService.connectedAt`, which is not cleared when the peer leaves |
| Mini bar / video overlay appears with no live call | (Fixed) Visibility trusted `callActiveNotifier` alone, which atypical teardowns left stale-true | Gate on `callActiveNotifier && CallService.inCall`; `leaveCall()` centrally resets the notifier |
| Reminder for other person never arrives | Recipient's phone has no FCM token registered | Check `rooms/{roomId}/fcmTokens` in Firestore Console — open the app once on that phone to register |
| Reminder docs pile up in Firestore after deleting tasks | (Fixed) Self reminders were never stored, and "remind them, no list" docs were created but not linked to the local task, so deletion never removed them | Every created doc is linked (`sharedId` or `reminderDocId`) and `_delete` deletes `backingDocId`; self reminders are stored with `locallyScheduled=true` and the Cloud Function skips them |
| A reminder received from the other person fires **twice** | (Fixed) The delivery path (FCM / WorkManager / `pendingStream`) armed it under `docNotifId(docId)`, but the local copy it inserted has id `reminder_<docId>` — so `_rearmReminders` added a *second* schedule under `'reminder_<docId>'.hashCode` on the next launch, and its `cancelReminderGroup` only cleared the todo-id family | `_rearmReminders` now also cancels `docNotifId(todo.backingDocId)` before re-arming, leaving this device's own id as the single owner. The magic expression is now `NotificationService.docNotifId` in one place so the call sites can't drift apart again — see the two-id-families table in §5 |
| Re-timing a task with "Remind me" unchecked still fires at the OLD time | (Fixed) The cancel + `dueDate` update lived inside `if (remindSelf)` in `_setReminder`, so unchecking it skipped both — the previous alarm stayed armed and the tile kept showing the old time | The local alarm now always follows the dialog: the old schedule is cancelled unconditionally, and the alarm is re-armed only when "Remind me" is on (`Task.remindsMe`) |
| A reminder you set for the other person is missing when you tick only **Theirs** | (Fixed) The filter placed each task under exactly one box, chosen by its **creator** — so "Drink Water", set by A for B and added to B's list, counted as *Mine*. Unticking Mine to review what you had set for them showed nothing, which reads as the reminder never having been created | `Task.involvesOther(me)` is now evaluated independently of `isMine`, and a task shows if **either** ticked box matches. A reminder you set for them rings on your phone *and* lives on their list, so it belongs to both. The day row distinguishes **· for them** from **· from them** |
| A reminder you set **for the other person** is missing from your own calendar | (Fixed) `_setReminder` cleared `start` whenever "Remind me" was unchecked, so a task set up with **Notify (+ add to their list)** had no time at all on this phone — the calendar only draws tasks with one | The time now survives whenever the dialog set one for *anyone*; the new `Task.remindsMe` flag records whether **this** phone rings for it. Only that gates arming (`_setReminder`, `_rearmReminders`, calendar `_editTask`) and the daily digest. Ticking neither box still clears the time |
| A repeating reminder arrives on the other phone as a one-shot | (Fixed) `recurrence` was a local-only field — `createReminder` never wrote it, the FCM payload never carried it, and `applySharedSnapshot` rescheduled with the default `Recurrence.none`, which *also* silently downgraded your own copy whenever the other side changed the time | `recurrence` is written to the reminder doc, added to the `onReminderCreated` payload, parsed by `PendingReminder`/`SharedTask`, and passed to every `scheduleReminder` call. `applySharedSnapshot` re-arms on a repeat change alone, and no longer drops past-dated repeating reminders (future occurrences still fire) |
| Picking a reminder date then ticking neither box does nothing | (Fixed) `_setReminder` fell through every branch with no write and no feedback | Reports "Reminder cleared" (if the task had one) or "Nothing selected — tick Remind me or Notify" |
| Daily summary notification never arrives | Digest is off, or the background worker isn't running (aggressive OEM battery optimization can suspend WorkManager) | Enable it in-app (bell icon → Daily summary) and set a time. The digest fires from the ~15-min WorkManager worker, so whitelist the app from battery optimization; it appears within one worker interval of the set time |
| Self reminder is missing from Firestore | The self-reminder write is best-effort; a Firestore rule that rejects `forUser == createdBy` writes was previously swallowed silently, so the reminder doc (its cross-device backup) never landed | The write failure is now logged (`LogService.e('todo', 'self reminder Firestore write failed…')` in `_setReminder`) — check `app_logs`. If present, allow self-writes in the Firestore rules |
| Calls fail with token error | Cached token expired and `getAgoraToken` unreachable at last app open | Open the app once with network (token refreshes), or check function logs: `firebase functions:log` |
| Video freezes/stutters on the lower-capability phone | (Fixed) No encoder config — Agora default `maintainQuality` kept resolution and dropped frames when the weak encoder couldn't keep up | Explicit 640×360@15fps profile with `DegradationPreference.maintainFramerate` in `joinCall()`; freeze/fail states now logged to `app_logs` |
| "Call in progress" notification visible during background calls | Foreground service notification (required by Android) was IMPORTANCE_LOW with call-specific wording | (Fixed) IMPORTANCE_MIN channel + VISIBILITY_SECRET + neutral "MyTask — Running" text. A notification cannot be removed entirely — MIN importance is the OS maximum for discretion |
| WebRTC calls: caller times out after 20s, callee never rings even when sitting on ChatScreen | (Fixed) `_startCall()` only called `ChatService.signalCall()` (the ring signal) after its own `CallService.joinCall()` fully finished; `WebRtcSignaling.reset()` deleted leftover ICE-candidate docs from a prior failed call one at a time, which could take 10+ seconds and ate into the 20s call-setup window before the ring was ever sent | `reset()` now batch-deletes; `_startCall()` sends the ring signal before joining its own engine, not after — check `webrtc/current` in Firestore for a fresh `offer` with zero matching `calleeCandidates`/no `answer` as the signature of this bug |
| WebRTC calls negotiate (offer/answer/ICE exchanged, "remote stream connected" logged) but connection state goes to `FAILED` | STUN alone cannot cross carrier-grade/symmetric NAT — common when one phone is on mobile data. Not a code bug; WebRTC requires a TURN relay for that topology | Configure `webrtc_turn_url`/`_username`/`_credential` in Remote Config (a free option: Open Relay Project, `turn:openrelay.metered.ca:80`, user/pass `openrelayproject`) — no rebuild needed, or self-host coturn if you don't want to depend on a third party |
| WebRTC video call shows a black screen after answering; audio call has no sound and shows "missed" after hanging up, even though it was accepted | (Fixed) Sending the ring signal before joining the local engine (the fix above) exposed a race: `WebRtcSignaling.reset()` — which clears the previous call's leftover offer/answer/candidates — ran deep inside the caller's own engine join (after local media capture), well after the ring already went out. The callee, rung immediately, could start listening and apply the *previous* call's stale offer before the new one was written, sending back a mismatched answer (different track/m-line count) and crashing `setRemoteDescription` on the caller's side with `Incompatible send direction` | `CallService.prepareOutgoingCall()` now runs the reset BEFORE the ring is sent, guaranteeing the callee only ever sees a clean slate or the real new offer. Diagnostic logging added: `webrtc: reset — cleared N stale candidate(s)` and the m-line count logged whenever an offer/answer is published or a remote description applied — a stale-offer race shows up as an m-line count that doesn't match what the current call actually negotiated |
| WebRTC: first call after install works fully (audio/video, `RTCPeerConnectionStateConnected`/`Completed` in `app_logs`); every call after that in the same session shows a black screen / no sound and is silently stuck instead of erroring | Two compounding issues. (1) App bug (Fixed): `onUserJoined` fired from `onTrack`, an SDP-level event that happens as soon as a track is negotiated — well before ICE actually connects. That marked the call "connected" in the UI immediately (masking the black screen) and disabled `CallScreen`'s 20s no-answer timeout (`!_callConnected` gate), so a call whose ICE handshake never actually completes just hangs forever with no error instead of timing out. (2) Infra (not a code bug): once the app-bug above is fixed and the timeout can fire correctly, repeated calls in a tight loop were observed to never reach `RTCPeerConnectionStateConnected` at all (no `FAILED` either — just stuck in `Connecting`) — consistent with the free/shared Open Relay Project TURN server throttling or exhausting concurrent relay allocations under repeated test calls, since every install shares the same static `openrelayproject` credentials with every other developer using that public demo server | `onUserJoined` now fires from `onConnectionState` reaching `Connected`, not from `onTrack` — a stuck call now correctly times out and shows an error instead of a silent black screen. If calls after the first one keep timing out, that's the shared TURN server's allocation limit, not the app — self-host coturn with a static long-term credential (see the TURN row above) if this keeps happening |

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
│   └── chat_controller_test.dart        ← optimistic UI (text + media upload: preview
│                                           bubble before upload, per-message progress,
│                                           clientId confirmation, retry re-uploads,
│                                           concurrent uploads), pagination, markRead, canModify,
│                                           hideMessage, editMessage, deleteMessage, presence
│                                           (heartbeat staleness, legacy peer, dispose guard),
│                                           stuck-write watchdog (wedged connection is reset,
│                                           cooldown holds, a live send counts as an ack),
│                                           silent-push recovery (dead stream re-subscribes,
│                                           healthy one does not, listener dropped on dispose)
├── features/call/
│   └── call_service_test.dart           ← backend selection (agora/webrtc + safe fallback),
│                                           leaveCall stops the foreground service and clears
│                                           call state (connectedAt, remote uid, flags)
├── models/
│   ├── message_test.dart                ← fromMap/toMap, all MessageTypes, legacy iv field
│   ├── recurrence_test.dart             ← storage round-trip, fireDays, shortLabel, abbrev,
│   │                                       daySlotMinutes (interval expansion, 22:00 cutoff,
│   │                                       past-cutoff time still fires once)
│   └── task_test.dart                   ← toJson/fromJson round-trip, reading the v1
│                                           format (dueDate), sharedId backfill,
│                                           isMine (incl. null = mine), backingDocId,
│                                           occursOn/occurrenceOn per recurrence,
│                                           remindsMe (default true, round-trip),
│                                           involvesOther (drives the Theirs box),
│                                           involvesOther (drives the Theirs box)
├── utils/
│   ├── time_utils_test.dart             ← formatLastSeen, formatDue,
│   │                                       parseReminderTimestamp (UTC→local regression)
│   ├── link_utils_test.dart             ← splitLinks URL detection (www, punctuation,
│   │                                       multiple links, plain text)
│   ├── calendar_utils_test.dart         ← monthYearLabel; monthCells (whole weeks,
│   │                                       Monday-first padding, leap February,
│   │                                       every day once, no foreign months)
│   ├── call_signal_interpreter_test.dart ← interpretCallSignal event mapping,
│   │                                        callerStatusLabel priority (§6.4)
│   ├── call_event_text_test.dart        ← formatCallDuration padding; missed-vs-ended
│   │                                       wording of the end-of-call chat entry
│   ├── emoji_data_test.dart             ← every category populated, tab icon is one of
│   │                                       its own emoji, no duplicates or blanks
│   └── message_grouping_test.dart       ← runs by sender/time window, never across
│                                           midnight or a call event, date chip per day,
│                                           formatDateSeparator (Today/Yesterday/weekday)
├── services/
│   ├── reminder_service_test.dart       ← applySharedSnapshot reconcile rules
│   │                                       (incl. subtask sync + recurrence sync:
│   │                                       repeat-only change re-arms, clearing a
│   │                                       repeat, past-dated repeat still arms,
│   │                                       both id families cancelled, a notify-only
│   │                                       copy takes the time but no alarm),
│   │                                       insertTodoToPrefs link + repeat carry-over,
│   │                                       deliveryMapFromDocs (outgoing filter)
│   ├── notification_service_test.dart   ← cancelReminderGroup covers all three id
│   │                                       families (base, weekday, interval slots)
│   ├── task_store_test.dart             ← v1 → v2 migration (format, idempotence,
│   │                                       nothing lost, legacy key kept), save/load
│   │                                       round-trip, corrupt JSON throws
│   ├── agora_token_service_test.dart    ← needsRefresh thresholds, cache behavior,
│   │                                       fetch-failure fallback
│   ├── digest_service_test.dart         ← titlesFor (today+not-done filter, skips
│   │                                       notify-only tasks),
│   │                                       buildBody checklist, DigestPrefs defaults
│   ├── call_log_service_test.dart       ← docIdFor stability / dedup key,
│   │                                       shouldSync + shouldReconcile throttles,
│   │                                       windowStartMs (high-water vs full rescan)
│   ├── media_store_service_test.dart    ← mimeTypeFor mapping, channel arguments,
│   │                                       null (not throw) on platform failure,
│   │                                       testMode seam
│   └── giphy_service_test.dart          ← isConfigured gating, no request without a key,
│                                           parseResponse variant preference + lenience
├── widgets/
│   └── message_bubble_test.dart         ← tick states, pending/failed rendering,
│                                           tappable link spans, uploading media
│                                           (local FileImage preview, % ring,
│                                           indeterminate at 0, failed = no ring)
└── screens/
    ├── todo_screen_test.dart            ← add/complete/delete/search tasks, subtasks,
    │                                       long-press edit dialog, unified reminder dialog,
    │                                       re-arm clears the received task's doc-id alarm
    │                                       (no double-fire), unticking "Remind me" clears
    │                                       the alarm, Notify-without-Remind-me keeps the
    │                                       time but arms nothing, neither-box-ticked feedback
    ├── calendar_screen_test.dart        ← month rendering, day selection, repeats drawn
    │                                       on every occurrence, Mine/Theirs filter
    │                                       (incl. last-box-cannot-clear and
    │                                       null-creator-is-mine), month navigation,
    │                                       add/edit/complete/delete write-through,
    │                                       day timeline (hour ruler, now line, scrolled
    │                                       to the current hour, same-time lanes, order)
    ├── calls_screen_test.dart           ← call history rendering
    ├── chat_screen_lifecycle_test.dart  ← background-leave navigation vs live calls
    │                                       (uses DeviceService.testMode seam)
    ├── chat_screen_ui_test.dart         ← date separators per day, grouped runs carry one
    │                                       timestamp, alternating senders keep their tails,
    │                                       empty state
    ├── chat_screen_composer_test.dart   ← attach sheet (all 7 options visible, toggles),
    │                                       emoji panel (inserts at caret, does not send,
    │                                       grapheme-safe backspace, mutually exclusive
    │                                       with the attach sheet), GIF tab configured
    │                                       vs not
    └── chat_screen_overlay_test.dart    ← overlay geometry persistence defaults/reset,
                                            phantom-open guard (notifier + inCall),
                                            resize handle: tap absorbed (no restore),
                                            drag resizes, over-max falls through to move
integration_test/
└── chat_screen_test.dart                ← end-to-end smoke tests (requires physical device)
```

**Run all unit tests (no device needed):**
```powershell
$env:PUB_CACHE = "D:\pub-cache"
flutter test                        # 416 tests, ~55 seconds
```

**Test-mode seams** — every service that touches Firebase/platform APIs has a
static flag or injectable, set them in `setUp()`:

| Seam | Effect |
|---|---|
| `NotificationService.testMode` | schedule/cancel/show become no-ops, but calls are *recorded*: `debugScheduled` (id/title/time/recurrence) and `debugCancelled` (ids). Clear both in `setUp()` |
| `RemoteConfigService.testMode` | skips fetch, returns defaults |
| `ReminderService.testMode` | Firestore methods no-op / return null |
| `DeviceService.testMode` | heartbeat no-op, last-opened stream emits null |
| `AgoraTokenService.fetchOverride` | replaces the Cloud Function call |
| `ChatScreen(repository:, callSignalProvider:)` | constructor injection |
| `CallScreen(callSignalProvider:)` | constructor injection — caller-side ringing/accept/decline tracking |
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
  @override Future<void> deleteForMe(String _, List<String> __) async {}
  @override Future<void> clearChatForMe() async {}
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

Four 1st-gen Node 20 functions live in `functions/` (firebase-functions v4 —
1st gen deliberately, to avoid the Eventarc permission delay 2nd-gen deploys
hit on first use). Deployed to `us-central1` on project `my-chat-app-963fa`:
`onReminderCreated` and `onMessageCreated` (Firestore triggers) and
`getAgoraToken` (HTTPS callable).

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

The payload also carries `recurrence` (`String(data.recurrence || 'none')`) so
the recipient arms the same repeat rather than a one-shot, and `createdBy` so
the received copy is filed under **Theirs** on the calendar instead of
defaulting to the recipient's own. Docs written before these existed send
`'none'` / `''`, which parse back to "does not repeat" / "unknown creator"
(and unknown counts as mine — see §5 `Task`).

FCM data values are always strings, and absent fields are sent as `''` rather
than omitted, so the client normalises empty to null before using them.

> **Redeploy required** after changing the payload:
> `firebase deploy --only functions --project my-chat-app-963fa`.
> Until then recipients keep receiving pushes without these fields and
> repeating reminders arrive as one-shots (the shared-task mirror still
> corrects them, so it degrades rather than breaks).

**Skips `locallyScheduled === true` docs.** "Remind me" self reminders are
stored as a backup but the creator has already scheduled the local
notification, so pushing to them (`forUser === createdBy`) would duplicate it.
The guard at the top of the trigger returns early for these.

### `onMessageCreated` — Firestore trigger (silent)

Fires when a doc is created in `rooms/{roomId}/messages/{messageId}` and wakes
the **other** phone (`sender` is `'A'`/`'B'`; the push goes to the opposite
role's token).

**Why it exists.** Chat delivery otherwise depends entirely on a live Firestore
listener inside a live app process, and two production failures break that:

1. the OS kills the app (OEM battery management), so there is no listener at
   all — the app-startup lines in `app_logs` are how this was identified;
2. the process survives but its `messages` watch target dies **silently** — no
   error, so the resubscribe-on-error self-heal (#80) never fires, and the
   write-stall watchdog (#102) does not see it either because writes still work.

This push is a delivery channel independent of Firestore, so it can notice
both.

**It is data-only and deliberately shows nothing.** There is no `notification`
block, so Android displays no notification whatsoever — discreteness is a
product requirement, and a chat notification would reveal chat activity outside
the app. `android.priority: 'high'` is required for delivery to a dozing or
killed app.

**The payload carries no content** — only `type: 'message'` and the message id.
The phone already has Firestore access and fetches the text itself, so there is
nothing in the push for a notification listener or a device log to leak.

On the client (`FcmService`): the **foreground** handler bumps
`chatRefreshNotifier`; `ChatController._onPushedMessage` then waits
`pushGraceWindow` (3 s) and re-subscribes the message stream **only if no
snapshot arrived in the meantime** — so a healthy conversation never
re-subscribes per message, while a silently dead stream is recovered. The
**background** handler deliberately does nothing: waking the process is the
whole point, the message is already in Firestore for the UI isolate to read on
open, and the notifier lives in a different isolate.

A send failure (stale token after a reinstall) is caught and logged, never
rethrown — the message is in Firestore either way.

> **Redeploy required**: `firebase deploy --only functions --project my-chat-app-963fa`.
> Until then nothing regresses — delivery simply stays dependent on the
> listener, exactly as before.

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
