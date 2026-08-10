# Firestore admin tools

Two scripts, same auth: **`peek.js`** (read-only diagnostic) and
**`cleanup.js`** (bulk delete).

## `peek.js` — read-only diagnostic

```bash
cd scripts
node peek.js
```

Prints, and changes nothing: the newest `app_logs` entries with ages, every
message doc (flagging any with **no timestamp** — the app's
`orderBy('timestamp')` query drops those silently), the room doc's
`presence` / `presenceAt` / `readAt` / `lastSeen` / `callSignal` / `fcmTokens`,
and the deployed Firestore security rules.

Use it when one phone stops receiving. The signature of a **wedged Firestore
connection** on the sending phone is: `presence.X == true`, `presenceAt.X`
frozen minutes ago, and no `lastSeen.X` — that phone's writes are queued
locally and never sent. See the matching row in `docs/DEVELOPER_GUIDE.md` §7.

## `cleanup.js` — bulk delete

Selectively bulk-deletes the Firestore collections that pile up over time, so
you don't have to select-and-delete documents one by one in the console.

Deletes any of:

| Category    | Collection(s)                          | Notes |
|-------------|----------------------------------------|-------|
| `applogs`   | `app_logs`                             | Diagnostic logs — safe to wipe anytime |
| `calllogs`  | `app_call_log_A`, `app_call_log_B`     | Call history for both devices |
| `messages`  | `rooms/{room}/messages`                | **Shared** — permanently deletes chat history for BOTH phones |
| `reminders` | `rooms/{room}/reminders`               | **Shared** — deletes reminder docs for both; pending cross-device reminders may stop firing |

## One-time setup

1. **Get a service-account key** (this is an admin credential — keep it private):
   Firebase console → **Project settings → Service accounts → Generate new
   private key**. Save the downloaded JSON as `scripts/serviceAccountKey.json`.
   It is gitignored — **never commit it**.

2. **Install deps** (once):
   ```bash
   cd scripts
   npm install
   ```
   > On **Windows PowerShell**, run each line separately — `&&` is not a valid
   > separator there (use `;` to chain, e.g. `cd scripts; npm install`).

## Usage

Run from the `scripts/` folder:

```bash
node cleanup.js                    # interactive: shows counts, asks what to delete
node cleanup.js applogs            # delete one category
node cleanup.js messages reminders # delete several
node cleanup.js all                # every category
node cleanup.js --dry-run all      # show counts only, delete NOTHING (safe preview)
node cleanup.js --yes applogs      # skip the confirmation prompt (for scripting)
```

Categories: `applogs` | `calllogs` | `messages` | `reminders` | `all`.

- The tool always prints current document counts first.
- Deleting `messages`/`reminders` requires typing `DELETE` to confirm (they are
  shared and irreversible). Other categories ask `y/N`.
- `--dry-run` is the safe way to see how much is there before deleting.

## Config

- **Room id** defaults to `my-chat-room-001` (the app's `kDefaultChatRoomId`).
  Override with `CHAT_ROOM_ID=... node cleanup.js ...`.
- **Key path** defaults to `scripts/serviceAccountKey.json`. Override with
  `GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`.

## Tests

Pure arg-parsing logic is covered by Node's built-in test runner (no Firebase
needed):

```bash
cd scripts
npm test          # runs `node --test`
```

The delete/count paths talk to live Firestore and are exercised manually via
`--dry-run`; they are not part of the Flutter `flutter test` suite.
