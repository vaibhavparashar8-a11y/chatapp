#!/usr/bin/env node
'use strict';

/**
 * Read-only Firestore diagnostic — prints nothing but what is already there.
 *
 * Answers: are the app_logs writes landing (and when did they stop), how fresh
 * are the newest messages, and what does the room doc's presence / readAt /
 * callSignal look like. Used to chase the multi-second chat + call delivery lag.
 *
 * Usage:  cd scripts   then   node peek.js
 *
 * Auth and room id work exactly like cleanup.js: service-account key at
 * scripts/serviceAccountKey.json (or GOOGLE_APPLICATION_CREDENTIALS), room from
 * CHAT_ROOM_ID or the app default. DELETES NOTHING — reads only.
 */

const path = require('path');

const ROOM_ID = process.env.CHAT_ROOM_ID || 'my-chat-room-001';

/** ISO string for a Firestore Timestamp, or the raw value if it isn't one. */
function iso(v) {
  if (v && typeof v.toDate === 'function') return v.toDate().toISOString();
  return v === undefined ? '—' : String(v);
}

/** How long ago, in human terms — the point of the whole exercise. */
function ago(v) {
  if (!v || typeof v.toDate !== 'function') return '';
  const mins = Math.round((Date.now() - v.toDate().getTime()) / 60000);
  if (mins < 60) return `${mins}m ago`;
  if (mins < 1440) return `${Math.round(mins / 60)}h ago`;
  return `${Math.round(mins / 1440)}d ago`;
}

/** Timestamps sort newest-first; docs missing the field sink to the bottom. */
function byFieldDesc(field) {
  return (a, b) => {
    const av = a.get(field);
    const bv = b.get(field);
    const at = av && av.toDate ? av.toDate().getTime() : 0;
    const bt = bv && bv.toDate ? bv.toDate().getTime() : 0;
    return bt - at;
  };
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
  console.log(`\nProject: ${cred.project_id}   Room: ${ROOM_ID}`);
  console.log(`Now:     ${new Date().toISOString()}\n`);

  // ── app_logs ──────────────────────────────────────────────────────────────
  // Sorted in memory, not by the server: a doc with no `time` field would make
  // an orderBy query drop it silently, and those are exactly the ones of
  // interest here.
  const logs = await db.collection('app_logs').get();
  console.log(`--- app_logs (${logs.size} docs total) ---`);
  if (logs.empty) {
    console.log('  (empty — nothing has ever been written, or it was cleaned)');
  }
  logs.docs
    .sort(byFieldDesc('time'))
    .slice(0, 8)
    .forEach((d) => {
      const v = d.data();
      console.log(
        `  ${iso(v.time)} ${String(ago(v.time)).padEnd(9)} ` +
          `${v.device || '?'} ${v.level || '?'} ${v.tag || '?'}: ` +
          String(v.message || '').slice(0, 80),
      );
    });

  // ── messages ──────────────────────────────────────────────────────────────
  const msgs = await db
    .collection('rooms')
    .doc(ROOM_ID)
    .collection('messages')
    .get();
  console.log(`\n--- messages (${msgs.size} docs total) ---`);
  // Every doc, not a top-N slice: one with no `timestamp` sorts last here and
  // is dropped entirely by the app's orderBy('timestamp') query — exactly the
  // case worth spotting.
  msgs.docs.sort(byFieldDesc('timestamp')).forEach((d) => {
    const v = d.data();
    const missing = v.timestamp === undefined || v.timestamp === null;
    console.log(
      `  ${missing ? '!! NO TIMESTAMP  ' : iso(v.timestamp)} ` +
        `${String(ago(v.timestamp)).padEnd(9)} ` +
        `${v.sender || '?'} ${v.type || 'text'} ` +
        JSON.stringify(String(v.text || '').slice(0, 40)) +
        (v.deletedFor && v.deletedFor.length
          ? ` deletedFor=${JSON.stringify(v.deletedFor)}`
          : ''),
    );
  });

  // ── room doc ──────────────────────────────────────────────────────────────
  const roomSnap = await db.collection('rooms').doc(ROOM_ID).get();
  const r = roomSnap.data() || {};
  const stamps = (o) =>
    o && typeof o === 'object'
      ? Object.fromEntries(
          Object.entries(o).map(([k, v]) => [k, `${iso(v)} (${ago(v)})`]),
        )
      : o;

  console.log('\n--- room doc ---');
  console.log('  fields     :', Object.keys(r).join(', ') || '(none)');
  console.log('  presence   :', JSON.stringify(r.presence));
  console.log('  presenceAt :', JSON.stringify(stamps(r.presenceAt)));
  console.log('  readAt     :', JSON.stringify(stamps(r.readAt)));
  console.log('  lastSeen   :', JSON.stringify(stamps(r.lastSeen)));
  console.log('  typing     :', JSON.stringify(r.typing));
  console.log('  callSignal :', JSON.stringify(r.callSignal));
  console.log('  fcmTokens  :', Object.keys(r.fcmTokens || {}).join(', ') || '(none)');

  // ── security rules ────────────────────────────────────────────────────────
  // Read via the Firebase Rules API. A write that the client cannot perform
  // (PERMISSION_DENIED) looks identical to "the message never sent", so the
  // deployed rules are worth seeing rather than guessing at.
  try {
    const { GoogleAuth } = require('google-auth-library');
    const auth = new GoogleAuth({
      credentials: cred,
      scopes: ['https://www.googleapis.com/auth/cloud-platform'],
    });
    const client = await auth.getClient();
    const base = 'https://firebaserules.googleapis.com/v1';
    const rel = await client.request({
      url: `${base}/projects/${cred.project_id}/releases/cloud.firestore`,
    });
    const rulesetName = rel.data.rulesetName;
    const rs = await client.request({ url: `${base}/${rulesetName}` });
    console.log(`\n--- firestore rules (${rulesetName}) ---`);
    for (const f of rs.data.source.files) {
      console.log(`# ${f.name}`);
      console.log(f.content);
    }
  } catch (e) {
    console.log('\n--- firestore rules ---');
    console.log('  could not read:', e && e.message ? e.message : e);
  }
  console.log();
}

main().catch((e) => {
  console.error('\nFAILED:', e && e.message ? e.message : e);
  process.exit(1);
});
