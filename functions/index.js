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

// CallMeBot WhatsApp API keys, one per role, stored ONLY in Secret Manager.
// Each phone activates CallMeBot once (WhatsApp "I allow callmebot to send me
// messages" to +34 644 66 32 62) and gets a personal key. Set with:
//   firebase functions:secrets:set CALLMEBOT_APIKEY_A
//   firebase functions:secrets:set CALLMEBOT_APIKEY_B
const callmebotApikeyA = defineSecret('CALLMEBOT_APIKEY_A');
const callmebotApikeyB = defineSecret('CALLMEBOT_APIKEY_B');
const callmebotSecrets = [callmebotApikeyA, callmebotApikeyB];

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
      },
      android: {
        priority: 'high',
        notification: { channelId: 'task_reminders' },
      },
    });
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

// ── WhatsApp reminders (CallMeBot) ───────────────────────────────────────────
// Two scheduled functions drive WhatsApp delivery entirely off the existing
// `reminders` collection (every dated task already writes a reminder doc):
//   • sendWhatsappPings  — a message when a task's scheduledAt time arrives.
//   • sendWhatsappDigest — a once-a-day checklist of the day's tasks.
// Each person receives ONLY their own tasks (routed by the reminder's
// `forUser`) at their own number, configured in-app under
// rooms/{roomId}/settings/whatsapp_{role}. CallMeBot is a plain relay: the
// message is delivered TO the number in `phone`, appearing from the CallMeBot
// contact. Text-only, so checklist items use the unicode ☐ box.

const ROLES = ['A', 'B'];

function apikeyForRole(role) {
  return role === 'A' ? callmebotApikeyA.value() : callmebotApikeyB.value();
}

/** Send one WhatsApp message via CallMeBot. Resolves true on HTTP success. */
async function sendCallMeBot(phone, apikey, text) {
  if (!phone || !apikey) return false;
  const url =
    'https://api.callmebot.com/whatsapp.php' +
    `?phone=${encodeURIComponent(phone)}` +
    `&text=${encodeURIComponent(text)}` +
    `&apikey=${encodeURIComponent(apikey)}`;
  const res = await fetch(url, { method: 'GET' });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    console.error(`CallMeBot ${res.status} for ${phone}: ${body.slice(0, 200)}`);
    return false;
  }
  return true;
}

/** Load both roles' WhatsApp settings docs for a room. */
async function loadWhatsappSettings(roomRef) {
  const out = {};
  for (const role of ROLES) {
    const snap = await roomRef.collection('settings').doc(`whatsapp_${role}`).get();
    out[role] = snap.exists ? snap.data() : null;
  }
  return out;
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Local wall-clock parts for `whenMs`, shifted by a UTC offset (minutes). */
function localParts(whenMs, offsetMin) {
  const d = new Date(whenMs + offsetMin * 60000);
  return {
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    y: d.getUTCFullYear(),
    mo: d.getUTCMonth(),
    day: d.getUTCDate(),
    weekday: d.getUTCDay(),
  };
}

function pad2(n) { return String(n).padStart(2, '0'); }

/** e.g. "2:00 PM" for a UTC ms value at the given offset. */
function fmtLocalTime(whenMs, offsetMin) {
  const p = localParts(whenMs, offsetMin);
  const ampm = p.hour < 12 ? 'AM' : 'PM';
  const h12 = p.hour % 12 === 0 ? 12 : p.hour % 12;
  return `${h12}:${pad2(p.minute)} ${ampm}`;
}

/**
 * Per-task ping: a reminder whose scheduledAt just passed and hasn't been
 * WhatsApp'd yet. Runs frequently; the whatsappSentAt stamp dedupes.
 */
exports.sendWhatsappPings = functions
  .runWith({ secrets: callmebotSecrets })
  .pubsub.schedule('every 2 minutes')
  .onRun(async () => {
    const db = getFirestore();
    const now = Date.now();
    // Ignore reminders more than 6h overdue so a first deploy (or downtime)
    // never floods old tasks.
    const cutoff = new Date(now - 6 * 60 * 60 * 1000);
    const rooms = await db.collection('rooms').get();

    for (const roomDoc of rooms.docs) {
      const settings = await loadWhatsappSettings(roomDoc.ref);
      const due = await roomDoc.ref
        .collection('reminders')
        .where('scheduledAt', '<=', new Date(now))
        .where('scheduledAt', '>', cutoff)
        .get();

      for (const rem of due.docs) {
        const data = rem.data();
        if (data.whatsappSentAt) continue;
        if (data.done === true) continue;
        const role = data.forUser;
        const cfg = settings[role];
        if (!cfg || cfg.enabled !== true || !cfg.phone) continue;

        const title = (data.title || '').trim() || 'Reminder';
        const when = data.scheduledAt.toDate().getTime();
        const text =
          `⏰ Task due — ${fmtLocalTime(when, cfg.utcOffsetMinutes || 0)}\n` +
          `☐ ${title}`;
        const ok = await sendCallMeBot(cfg.phone, apikeyForRole(role), text);
        // Stamp regardless of ok: a hard failure (e.g. bad key) must not loop
        // every 2 minutes. Retries would just re-hit the same broken config.
        await rem.ref.update({ whatsappSentAt: new Date() });
        if (!ok) console.error(`ping not delivered for ${rem.id} (role ${role})`);
      }
    }
    return null;
  });

/**
 * Morning digest: once per day, at or after each person's configured local
 * time, send a checklist of that person's tasks scheduled for today.
 * lastDigestSentDate (local YYYY-MM-DD) guarantees exactly one send per day
 * and lets a missed slot catch up later the same day.
 */
exports.sendWhatsappDigest = functions
  .runWith({ secrets: callmebotSecrets })
  .pubsub.schedule('every 5 minutes')
  .onRun(async () => {
    const db = getFirestore();
    const now = Date.now();
    const rooms = await db.collection('rooms').get();

    for (const roomDoc of rooms.docs) {
      const settings = await loadWhatsappSettings(roomDoc.ref);

      for (const role of ROLES) {
        const cfg = settings[role];
        if (!cfg || cfg.enabled !== true || !cfg.phone) continue;

        const offset = cfg.utcOffsetMinutes || 0;
        const p = localParts(now, offset);
        const dateStr = `${p.y}-${pad2(p.mo + 1)}-${pad2(p.day)}`;
        if (cfg.lastDigestSentDate === dateStr) continue; // already sent today

        const nowMinOfDay = p.hour * 60 + p.minute;
        const cfgMinOfDay = (cfg.hour || 0) * 60 + (cfg.minute || 0);
        if (nowMinOfDay < cfgMinOfDay) continue; // not time yet

        // Local day window → UTC range for the scheduledAt query.
        const dayStartMs = Date.UTC(p.y, p.mo, p.day, 0, 0, 0) - offset * 60000;
        const dayEndMs = dayStartMs + 24 * 60 * 60 * 1000;

        const snap = await roomDoc.ref
          .collection('reminders')
          .where('forUser', '==', role)
          .where('scheduledAt', '>=', new Date(dayStartMs))
          .where('scheduledAt', '<', new Date(dayEndMs))
          .get();

        const tasks = snap.docs
          .map((d) => d.data())
          .filter((d) => d.done !== true)
          .sort((a, b) => a.scheduledAt.toDate() - b.scheduledAt.toDate());

        const header =
          `📋 Today's tasks — ${WEEKDAYS[p.weekday]}, ${p.day} ${MONTHS[p.mo]}`;
        let text;
        if (tasks.length === 0) {
          text = `${header}\n\nNothing scheduled today. 🎉`;
        } else {
          const lines = tasks.map((t) => {
            const title = (t.title || '').trim() || 'Reminder';
            return `☐ ${title}  (${fmtLocalTime(t.scheduledAt.toDate().getTime(), offset)})`;
          });
          text = `${header}\n${lines.join('\n')}`;
        }

        const ok = await sendCallMeBot(cfg.phone, apikeyForRole(role), text);
        if (ok) {
          await roomDoc.ref
            .collection('settings')
            .doc(`whatsapp_${role}`)
            .set({ lastDigestSentDate: dateStr }, { merge: true });
        } else {
          console.error(`digest not delivered for role ${role} in ${roomDoc.id}`);
        }
      }
    }
    return null;
  });
