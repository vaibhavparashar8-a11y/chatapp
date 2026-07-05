# Claude Code Instructions for this project

## What this app is

A private two-person Flutter/Android app: chat + audio/video calls + a todo
list with cross-device reminders. Both users install the same APK; each
device claims role **A** or **B** via a Firestore transaction keyed on
ANDROID_ID (`DeviceService`). Everything lives under one Firestore room doc
(`rooms/{chatRoomId}`). Full reference: `docs/DEVELOPER_GUIDE.md`.

## Folder map

```
lib/
├── main.dart              ← startup order matters — see guide §5 before touching
├── constants.dart         ← mutable globals set at startup (mySenderId, agoraToken, …)
├── models/                ← plain Dart data classes, no Firebase imports
├── controllers/           ← ChatController: ALL chat business logic, no Firebase imports
├── repositories/          ← IChatRepository interface + FirebaseChatRepository adapter
├── services/              ← static-method services (chat, device, reminder, fcm,
│                             notification, agora_token, remote_config, log, call_log)
├── screens/               ← todo_screen (home), chat_screen (+ part files in chat/),
│                             calls_screen, media_viewer, log_screen
├── widgets/               ← message_bubble (+ part files in bubbles/)
├── features/call/         ← CallService (Agora engine), CallScreen, incoming dialog
├── background_worker.dart ← WorkManager isolate (15-min reminder/sync fallback)
└── utils/                 ← pure functions (time formatting) — unit-testable
functions/                 ← Cloud Functions, Node 20 1st-gen (onReminderCreated,
                             getAgoraToken); deploy: firebase deploy --only functions
test/                      ← mirrors lib/; helpers/fake_chat_repository.dart
docs/DEVELOPER_GUIDE.md    ← the deep reference (schema, data flows, module docs)
android/.../chatapp/       ← native: MainActivity, CallForegroundService (discreet
                             notification — do not make it louder)
```

## Conventions

- Layering: UI → ChatController → IChatRepository → services. ChatController
  must never import Firebase; screens must never contain business logic.
- Services are static-method classes with a `testMode` flag (or injectable
  override) — always add the seam when creating a new service.
- Big screens split via Dart `part` files, not new widgets files.
- Shared tasks: a todo with `sharedId != null` mirrors a Firestore reminder
  doc — every local mutation must write through (see guide §6.7).
- Notification IDs: reminders may be scheduled under `todo.id.hashCode` OR
  `docId.hashCode.abs() % 0x7FFFFFFF` — cancel both when in doubt.
- FCM payload timestamps are UTC — always parse via `parseReminderTimestamp`.
- Discreteness is a product requirement: no notification, label, or UI text
  may reveal chat/call activity outside the app.

## Commands

| Task | Command |
|---|---|
| Run tests (157) | `flutter test` |
| Build APK | `.\build_release.ps1` (never raw `flutter build`) |
| Deploy functions | `firebase deploy --only functions --project my-chat-app-963fa` |
| Function logs | `firebase functions:log --project my-chat-app-963fa` |
| Outdated deps | `flutter pub outdated` (migration pending — issue #53, do NOT upgrade Flutter SDK) |

## Git Workflow — MANDATORY, never skip

Every change must follow this flow, no exceptions:

1. `git checkout -b <prefix>/<short-description>` — always branch from current base
   - `feat/` for new features
   - `fix/` for bug fixes
   - `chore/` for non-code changes (deps, config, etc.)
2. Make changes, commit to the branch
3. `git push origin <branch>`
4. Create a PR — never merge directly into main
5. User merges the PR on GitHub
6. **After every merge into main: run `git fetch origin && git pull origin main`** to bring local in sync — confirm with `git status` showing "up to date"

**Never commit directly to `main`.**
**Never push directly to `main`.**
Each logical unit of work (feature or fix) gets its own branch and PR.

## Testing — MANDATORY, never skip

Every feature and bug fix must include tests:

- New feature → add widget/unit tests covering the happy path and key edge cases
- Bug fix → add a test that would have caught the bug (regression test)
- Tests live in `test/` mirroring the `lib/` structure (e.g. `lib/screens/foo.dart` → `test/screens/foo_test.dart`)
- Run `flutter test` before committing to confirm all tests pass
- If a feature genuinely cannot be tested (platform-native, third-party SDK with no mock) document why in the PR description — do not silently skip

## Documentation — MANDATORY, never skip

Every change that adds, removes, or alters app behavior must update
`docs/DEVELOPER_GUIDE.md` **in the same PR** as the code change:

- New feature → document it in the relevant module section (§5); add a
  data-flow diagram (§6) if it spans devices/services
- Bug fix → add a row to Common Issues & Fixes (§7) if the root cause is
  instructive; update any guide snippet the fix invalidated
- Schema change (Firestore fields/collections, SharedPreferences keys,
  Remote Config keys) → update the §4 schema / §2 config tables
- New service, Cloud Function, or startup step → update §3 architecture,
  the §5 main.dart startup order, and §11 for functions
- New tests or test seams → update §9 (test tree, count, seam table)

Pure refactors with no behavior change need no docs update — but check
whether any guide snippet references the moved code.

## APK Builds — always use the script

```powershell
.\build_release.ps1
```

Never type the flutter build command manually. The script:
- Runs `flutter test` first — **aborts the build if any test fails**
- Sets the correct `GRADLE_USER_HOME` and `PUB_CACHE` paths (D: drive)
- Passes `--split-per-abi` (keeps APK size small — one APK per CPU architecture)
- Outputs `MyTask.apk` automatically

## Environment

- Flutter: D:\flutter\flutter
- Gradle cache: D:\gradle
- Pub cache: D:\pub-cache
- Never write to C: drive for build artifacts

## Security

- `android/app/google-services.json` must NEVER be committed to GitHub

## Workflow
- **Start Fresh:** Run `/clear` immediately at the beginning of any brand new feature or task to prevent context bloat and ensure prior session history does not cause hallucinations.
- **Agent Orchestration:** Do not fan out agents until I explicitly specify. Always ask if it is necessary to fan out before doing so.
- **Look Before You Leap:** Before modifying any core files (especially main.dart or structural layers), you must use your grep/view tools to inspect the relevant sections in docs/DEVELOPER_GUIDE.md.
- **Surgical Changes Only:** Modify exclusively the code required to complete the task or fix the bug. Do not touch adjacent working logic, reformat unrelated blocks, or clean up styling unless explicitly requested.