$env:GRADLE_USER_HOME = "D:\gradle"
$env:PUB_CACHE         = "D:\pub-cache"

flutter build apk --release --split-per-abi

$src = "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
$dst = "build\app\outputs\flutter-apk\MyTask.apk"

if (Test-Path $src) {
    Copy-Item $src $dst -Force
    $mb = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Host "`nMyTask.apk ready — $mb MB`n$((Resolve-Path $dst).Path)"
} else {
    Write-Host "Build failed — arm64 APK not found"
}
