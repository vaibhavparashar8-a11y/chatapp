# Claude Code Instructions for this project

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
