#!/usr/bin/env node
'use strict';

/**
 * "Do both phones still have the app?" — answered entirely from this machine.
 *
 * Nothing is installed, nothing is deployed, and neither phone does any work:
 * the check runs against Firebase's own records of them.
 *
 * The room doc alone cannot answer the question. `roleAssignments` and
 * `appLastOpened` say a phone installed the app *once*; both survive an
 * uninstall, a factory reset and an OEM battery-killer forever. So this script
 * adds the one signal that does expire — the FCM registration token.
 *
 * FCM lets a token be validated with a **dry-run send**: the message is
 * assembled and checked against the token but never delivered, so the phone
 * shows nothing and is not even woken. Firebase answers from its own
 * registration table:
 *
 *   accepted                            → the app is still installed on that
 *                                         phone, with that token live
 *   registration-token-not-registered   → the app is gone (uninstalled, data
 *                                         cleared, or the token was rotated
 *                                         away and never re-registered)
 *   invalid-argument                    → the stored token is malformed
 *
 * Caveat worth knowing before trusting a green result: FCM does not retire a
 * token the instant an app is uninstalled. It usually notices within days —
 * sometimes weeks — typically on the first delivery attempt afterwards. So
 * "not registered" is conclusive, while "accepted" can lag reality. Cross-read
 * it with the last-opened timestamps this prints beside it.
 *
 * Usage:  cd scripts   then   node devicecheck.js
 *
 * Auth and room id work exactly like cleanup.js and peek.js: service-account
 * key at scripts/serviceAccountKey.json (or GOOGLE_APPLICATION_CREDENTIALS),
 * room from CHAT_ROOM_ID or the app default. WRITES NOTHING, SENDS NOTHING.
 */

const path = require('path');

const ROOM_ID = process.env.CHAT_ROOM_ID || 'my-chat-room-001';
const ROLES = ['A', 'B'];

/** ISO string for a Firestore Timestamp, or a dash when it was never written. */
function iso(v) {
  if (v && typeof v.toDate === 'function') return v.toDate().toISOString();
  return '—';
}

/** How long ago, in human terms. */
function ago(v) {
  if (!v || typeof v.toDate !== 'function') return '';
  const mins = Math.round((Date.now() - v.toDate().getTime()) / 60000);
  if (mins < 60) return `${mins}m ago`;
  if (mins < 1440) return `${Math.round(mins / 60)}h ago`;
  return `${Math.round(mins / 1440)}d ago`;
}

/** The later of the two "last opened" stamps, whichever exist. */
function lastOpened(room, role) {
  const stamps = [room.appLastOpened, room.todoLastOpened]
    .map((m) => (m || {})[role])
    .filter((t) => t && typeof t.toDate === 'function');
  if (!stamps.length) return null;
  return stamps.reduce((a, b) => (a.toDate() > b.toDate() ? a : b));
}

/**
 * Turns one dry-run outcome into a verdict. Pure — the tests drive it directly
 * rather than talking to FCM.
 *
 * `tokenError` is the FCM error code (`err.errorInfo.code`), or null when the
 * dry run was accepted. `claimed` / `hasToken` come from the room doc.
 */
function verdictFor({ claimed, hasToken, tokenError }) {
  if (!claimed) {
    return {
      installed: false,
      label: 'NEVER INSTALLED',
      detail: 'no role claimed — this phone has never launched the app',
    };
  }
  if (!hasToken) {
    return {
      installed: false,
      label: 'NO PUSH TOKEN',
      detail:
        'claimed a role but never registered for push — an old build, or ' +
        'notifications were denied',
    };
  }
  switch (tokenError) {
    case null:
    case undefined:
      return {
        installed: true,
        label: 'INSTALLED',
        detail: 'FCM accepted the token — the app is still on this phone',
      };
    case 'messaging/registration-token-not-registered':
      return {
        installed: false,
        label: 'GONE',
        detail:
          'FCM has retired the token — the app was uninstalled, its data ' +
          'cleared, or it never re-registered',
      };
    case 'messaging/invalid-argument':
    case 'messaging/invalid-registration-token':
      return {
        installed: false,
        label: 'BAD TOKEN',
        detail: 'the stored token is malformed — treat as not installed',
      };
    default:
      return {
        installed: null,
        label: 'UNKNOWN',
        detail: `FCM returned ${tokenError} — could not tell either way`,
      };
  }
}

/** Dry-run one token. Returns the FCM error code, or null when accepted. */
async function probe(messaging, token) {
  try {
    // `true` = dry run: validated against the registration table, never sent.
    await messaging.send({ token, data: { type: 'devicecheck' } }, true);
    return null;
  } catch (e) {
    return (e && e.errorInfo && e.errorInfo.code) || (e && e.code) || 'unknown';
  }
}

async function main() {
  const admin = require('firebase-admin');
  const keyPath =
    process.env.GOOGLE_APPLICATION_CREDENTIALS ||
    path.join(__dirname, 'serviceAccountKey.json');
  let cred;
  try {
    cred = require(keyPath);
  } catch {
    console.error(`\nService-account key not found at:\n  ${keyPath}\n`);
    console.error('Run this from the scripts/ folder, or set');
    console.error('GOOGLE_APPLICATION_CREDENTIALS to the key path.');
    process.exit(1);
  }

  admin.initializeApp({ credential: admin.credential.cert(cred) });
  const db = admin.firestore();
  const messaging = admin.messaging();

  console.log(`\nProject: ${cred.project_id}   Room: ${ROOM_ID}`);
  console.log(`Now:     ${new Date().toISOString()}`);
  console.log('Nothing is delivered to either phone — dry run only.\n');

  const snap = await db.collection('rooms').doc(ROOM_ID).get();
  const room = snap.data() || {};
  const assignments = room.roleAssignments || {};
  const tokens = room.fcmTokens || {};

  for (const role of ROLES) {
    const claimed = typeof assignments[role] === 'string' && assignments[role];
    const token = tokens[role];
    const hasToken = typeof token === 'string' && token.length > 0;
    const tokenError = hasToken ? await probe(messaging, token) : undefined;
    const v = verdictFor({ claimed: !!claimed, hasToken, tokenError });

    const opened = lastOpened(room, role);
    console.log(`Phone ${role}: ${v.label}`);
    console.log(`  ${v.detail}`);
    console.log(`  device id   : ${claimed || '(none)'}`);
    console.log(
      `  last opened : ${iso(opened)} ${opened ? `(${ago(opened)})` : ''}`,
    );
    console.log('');
  }

  console.log(
    'A "GONE" verdict is conclusive. "INSTALLED" can lag an uninstall by\n' +
      'days, so read it together with the last-opened time above it.\n',
  );
  process.exit(0);
}

// Only run when invoked directly, so the tests can import verdictFor cleanly.
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { verdictFor, lastOpened, ROOM_ID, ROLES };
