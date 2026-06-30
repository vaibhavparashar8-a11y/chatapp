---
name: Bug report
about: Something is broken or behaving unexpectedly
title: "[BUG] "
labels: bug
assignees: ''
---

## Description

A clear description of what the bug is.

## Steps to Reproduce

1. Open the app
2. ...
3. See error

## Expected Behavior

What you expected to happen.

## Actual Behavior

What actually happened instead.

## Device Info

- Device model:
- Android version:
- App version / APK build date:
- Role (A or B):

## Logs

Paste relevant log lines from the in-app **Log Screen** (tap ☰ → Logs in the chat screen):

```
PASTE LOGS HERE
```

Or filter from Firestore: `app_logs` collection → `device == "your-device-id"` → `level == "ERROR"`.

## Firestore Evidence (if applicable)

- [ ] Checked `rooms/my-chat-room-001` document in Firebase Console
- [ ] Checked `callSignal.status` value
- [ ] Checked `roleAssignments` map

## Additional Context

Any other context, screenshots, or recordings.
