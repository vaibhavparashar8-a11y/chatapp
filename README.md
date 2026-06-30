# ChatApp — Private Anonymous Messenger

A fully private 2-person chat app. No names, no notifications, no saved history.

---

## Privacy features
- Fully anonymous — no names shown, just "You" and "Them"
- Messages auto-delete the moment either person leaves or closes the app
- Media files (images, videos) also deleted from server on exit
- No push notifications — silent by design
- No login, no account, just install and chat

---

## Features
- Real-time text chat
- Send images, videos, GIFs, any file
- Audio calls (Agora)
- Video calls with camera preview, mute, flip camera
- Manual "clear chat" button in top bar

---

## Setup Instructions

### Step 1 — Install Flutter
Download from https://flutter.dev/docs/get-started/install

### Step 2 — Enable Firebase services
Go to https://console.firebase.google.com → your project (my-chat-app)

**Firestore:**
- Firestore Database → Create database → Start in test mode

**Storage:**
- Upgrade to Blaze plan → Storage → Get started → Test mode

**Firestore rules** (Firestore → Rules tab):
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if true;
    }
  }
}
```

**Storage rules** (Storage → Rules tab):
```
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /{allPaths=**} {
      allow read, write: if true;
    }
  }
}
```

### Step 3 — Build APK for Phone 1
In `lib/constants.dart`, confirm:
```dart
const String mySenderId = 'A';
```
Then run:
```
flutter pub get
flutter build apk --release
```
APK is at: `build/app/outputs/flutter-apk/app-release.apk`
Install on Phone 1.

### Step 4 — Build APK for Phone 2
Open `lib/constants.dart` and change:
```dart
const String mySenderId = 'B';  // <-- only change this
```
Build again and install on Phone 2.

### Step 5 — Install
On each phone:
Settings → Security → Enable "Install unknown apps"
Open the APK → Install → Done.

---

## How messages are deleted
- App goes to background → deleted
- App is closed/swiped away → deleted
- Back button pressed → deleted
- Manual clear button tapped → deleted

Both the Firestore messages AND the media files in Storage are deleted.
