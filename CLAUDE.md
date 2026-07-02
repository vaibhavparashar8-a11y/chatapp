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

**Never commit directly to `main`.**
**Never push directly to `main`.**
Each logical unit of work (feature or fix) gets its own branch and PR.

## APK Builds — always use the script

```powershell
.\build_release.ps1
```

Never type the flutter build command manually. The script sets the correct
`GRADLE_USER_HOME` and `PUB_CACHE` paths (D: drive), builds arm64 only,
and outputs `MyTask.apk` automatically.

## Environment

- Flutter: D:\flutter\flutter
- Gradle cache: D:\gradle
- Pub cache: D:\pub-cache
- Never write to C: drive for build artifacts

## Security

- `android/app/google-services.json` must NEVER be committed to GitHub
