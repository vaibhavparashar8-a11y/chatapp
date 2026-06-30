## Summary

What does this PR do? (1–3 bullet points)

- 
- 

Closes #

## Changes

Brief description of what changed and why.

## Affected Files

List the main files modified:

- `lib/...`

## Test Plan

- [ ] Tested on device as role **A**
- [ ] Tested on device as role **B**
- [ ] Sent text message — appears immediately (optimistic UI) and confirmed via stream
- [ ] Sent media — progress bar shown, media received on other device
- [ ] Read receipts update correctly (single → double blue tick)
- [ ] Typing indicator appears and clears
- [ ] Presence (Online / Last seen) updates correctly
- [ ] Call feature unaffected (if not changing call code)
- [ ] Built `MyTask.apk` with `.\build_release.ps1` — APK is ~105 MB
- [ ] Installed APK on physical device — no crash on startup

## Notes for Reviewer

Any edge cases, known limitations, or follow-up work.
