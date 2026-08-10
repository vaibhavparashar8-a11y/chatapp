const functions = require('firebase-functions');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { RtcTokenBuilder, RtcRole } = require('agora-token');

initializeApp();

// Agora App Certificate lives ONLY in Secret Manager — never in the APK or
// Remote Config. Set with: firebase functions:secrets:set AGORA_APP_CERTIFICATE
const agoraCertificate = defineSecret('AGORA_APP_CERTIFICATE');

// Token lifetime: 24h. The app refreshes its cached token on each app open
// once it is older than 12h, so an active user never holds an expired token.
const TOKEN_TTL_SECONDS = 24 * 60 * 60;

/**
 * Triggers when A writes a new reminder doc for B.
 * Reads B's FCM token from the room doc and sends an immediate push so B's
 * device wakes up and schedules the local notification — regardless of whether
 * the app is open, backgrounded, or completely killed.
 */
exports.onReminderCreated = functions.firestore
  .document('rooms/{roomId}/reminders/{reminderId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const forUser = data.forUser;
    const roomId = context.params.roomId;
    const reminderId = context.params.reminderId;

    // "Remind me" self reminders are stored in Firestore as a backup, but the
    // creator has already scheduled the local notification (locallyScheduled=true
    // at creation). Pushing to them would duplicate it, so skip these.
    if (data.locallyScheduled === true) return null;

    // Look up the recipient's FCM token stored under rooms/{roomId}/fcmTokens.
    const roomDoc = await getFirestore().collection('rooms').doc(roomId).get();
    const fcmTokens = (roomDoc.data() || {}).fcmTokens || {};
    const token = fcmTokens[forUser];

    // Token is absent if the recipient has never opened the app on this device.
    if (!token) return null;

    const scheduledAt = data.scheduledAt && data.scheduledAt.toDate
      ? data.scheduledAt.toDate().toISOString()
      : null;
    if (!scheduledAt) return null;

    return getMessaging().send({
      token,
      notification: {
        title: 'Task Reminder',
        body: data.title || 'You have a reminder',
      },
      data: {
        type: 'reminder',
        reminderId,
        title: data.title || 'Reminder',
        scheduledAt,
        addToList: String(data.addToList || false),
        // Absent on docs written before repeat-sync — the app parses a
        // missing/unknown value back as "does not repeat".
        recurrence: String(data.recurrence || 'none'),
        // Lets the recipient file the reminder under "Theirs" on the calendar
        // instead of defaulting it to their own.
        createdBy: String(data.createdBy || ''),
      },
      android: {
        priority: 'high',
        notification: { channelId: 'task_reminders' },
      },
    });
  });

/**
 * Triggers on every new chat message and wakes the OTHER phone.
 *
 * Chat delivery otherwise depends entirely on a live Firestore listener inside
 * a live app process. Two ways that fails, both seen in production:
 *   - the OS kills the app (OEM battery management), so there is no listener
 *     at all until the user next opens it;
 *   - the process survives but its `messages` watch target dies *silently* —
 *     no error, so the resubscribe-on-error self-heal (#80) never fires.
 *
 * This push is a delivery channel independent of that listener. It is
 * deliberately **data-only**: no `notification` block, so Android displays
 * nothing whatsoever. Discreteness is a product requirement — a chat
 * notification would reveal chat activity outside the app — and the client
 * uses this purely as a signal to re-subscribe and pull the latest messages.
 *
 * No message text or sender name travels in the payload: the phone already has
 * Firestore access and fetches the content itself, so there is nothing here for
 * a notification listener or a log to leak.
 */
exports.onMessageCreated = functions.firestore
  .document('rooms/{roomId}/messages/{messageId}')
  .onCreate(async (snap, context) => {
    const data = snap.data() || {};
    const roomId = context.params.roomId;

    // Messages carry the author's role; push to the other one.
    const sender = data.sender;
    if (sender !== 'A' && sender !== 'B') return null;
    const recipient = sender === 'A' ? 'B' : 'A';

    const roomDoc = await getFirestore().collection('rooms').doc(roomId).get();
    const fcmTokens = (roomDoc.data() || {}).fcmTokens || {};
    const token = fcmTokens[recipient];
    if (!token) return null; // recipient has never opened the app on a device

    try {
      return await getMessaging().send({
        token,
        // NO notification block — data-only keeps this invisible and lets the
        // background isolate run even when the app is killed.
        data: {
          type: 'message',
          messageId: context.params.messageId,
        },
        android: {
          // Required for delivery to a dozing or killed app.
          priority: 'high',
        },
      });
    } catch (e) {
      // A stale token (app reinstalled) must not fail the write that triggered
      // us — the message is already in Firestore either way.
      console.error('onMessageCreated push failed:', e && e.message);
      return null;
    }
  });

/**
 * Mints a fresh Agora RTC token on demand. Called by the app on startup
 * (fetch-on-open caching) — NOT at call time, so cold starts never delay
 * a call. No Firestore reads or writes.
 *
 * Request:  { appId: string, channel: string }
 * Response: { token: string, expiresAt: number (ms since epoch) }
 */
exports.getAgoraToken = functions
  .runWith({ secrets: [agoraCertificate] })
  .https.onCall((data, context) => {
    // Anonymous Firebase Auth is enough — both phones sign in on startup.
    if (!context.auth) {
      throw new functions.https.HttpsError(
        'unauthenticated', 'Sign-in required.');
    }
    const appId = data.appId;
    const channel = data.channel;
    if (!appId || !channel) {
      throw new functions.https.HttpsError(
        'invalid-argument', 'appId and channel are required.');
    }

    const nowSecs = Math.floor(Date.now() / 1000);
    const expireAtSecs = nowSecs + TOKEN_TTL_SECONDS;
    // uid 0 = wildcard token: valid for any uid, so one token serves both
    // phones (they join as uid 1 and 2) and the caller can forward it to the
    // callee through the existing call signaling.
    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      agoraCertificate.value(),
      channel,
      0,
      RtcRole.PUBLISHER,
      expireAtSecs,
      expireAtSecs,
    );
    return { token, expiresAt: expireAtSecs * 1000 };
  });
