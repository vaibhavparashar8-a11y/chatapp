#!/usr/bin/env node
'use strict';

/**
 * Firestore cleanup admin tool for the private chat app.
 *
 * Selectively bulk-deletes the collections that accumulate over time, so you
 * never have to select-and-delete docs one by one in the Firebase console.
 *
 * Usage:
 *   node cleanup.js                      interactive — shows counts, asks what to delete
 *   node cleanup.js applogs              delete one category
 *   node cleanup.js messages reminders   delete several
 *   node cleanup.js all                  every category
 *   node cleanup.js --dry-run all        show counts only, delete NOTHING
 *   node cleanup.js --yes applogs        skip the confirmation prompt
 *
 * Categories: applogs | calllogs | messages | reminders | all
 *
 * Auth: put a Firebase service-account key at scripts/serviceAccountKey.json
 * (Firebase console → Project settings → Service accounts → Generate new
 * private key), or point GOOGLE_APPLICATION_CREDENTIALS at it. The key is
 * gitignored — NEVER commit it.
 *
 * Room id defaults to the app's kDefaultChatRoomId; override with CHAT_ROOM_ID.
 */

const path = require('path');
const readline = require('readline');

const ROOM_ID = process.env.CHAT_ROOM_ID || 'my-chat-room-001';

// Canonical order — also the order counts/deletes are reported in.
const ORDER = ['applogs', 'calllogs', 'messages', 'reminders'];

/** Collection refs + metadata per category. `db` is an admin Firestore. */
function categories(db) {
  return {
    applogs: {
      label: 'App logs',
      danger: false,
      refs: [db.collection('app_logs')],
    },
    calllogs: {
      label: 'Call logs',
      danger: false,
      refs: [
        db.collection('app_call_log_A'),
        db.collection('app_call_log_B'),
      ],
    },
    messages: {
      label: 'Messages (shared — deletes for BOTH phones)',
      danger: true,
      refs: [db.collection('rooms').doc(ROOM_ID).collection('messages')],
    },
    reminders: {
      label: 'Reminders (shared — deletes for BOTH phones)',
      danger: true,
      refs: [db.collection('rooms').doc(ROOM_ID).collection('reminders')],
    },
  };
}

/**
 * Parse CLI args into { selected, dryRun, yes }. Pure — unit-tested.
 * Throws on an unknown token so a typo can't silently delete the wrong thing.
 */
function parseArgs(argv) {
  let dryRun = false;
  let yes = false;
  const picked = new Set();
  for (const a of argv) {
    if (a === '--dry-run' || a === '-n') dryRun = true;
    else if (a === '--yes' || a === '-y') yes = true;
    else if (a === 'all') ORDER.forEach((c) => picked.add(c));
    else if (ORDER.includes(a)) picked.add(a);
    else throw new Error(`Unknown argument: "${a}"`);
  }
  const selected = ORDER.filter((c) => picked.has(c));
  return { selected, dryRun, yes };
}

async function countRefs(refs) {
  let total = 0;
  for (const ref of refs) {
    const snap = await ref.count().get();
    total += snap.data().count;
  }
  return total;
}

async function deleteRefs(db, refs) {
  let total = 0;
  for (const ref of refs) {
    total += (await ref.count().get()).data().count;
    await db.recursiveDelete(ref); // batched under the hood (BulkWriter)
  }
  return total;
}

function ask(question) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return new Promise((resolve) =>
    rl.question(question, (a) => {
      rl.close();
      resolve(a.trim());
    }));
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    console.error('Categories: applogs | calllogs | messages | reminders | all');
    process.exit(1);
  }

  // Lazy-require so `node --test` (which imports parseArgs) needs no admin SDK.
  const admin = require('firebase-admin');
  const keyPath =
    process.env.GOOGLE_APPLICATION_CREDENTIALS ||
    path.join(__dirname, 'serviceAccountKey.json');
  let cred;
  try {
    cred = require(keyPath);
  } catch {
    console.error(`\nService-account key not found at:\n  ${keyPath}\n`);
    console.error('Firebase console → Project settings → Service accounts →');
    console.error('Generate new private key, save it as scripts/serviceAccountKey.json');
    console.error('(it is gitignored), then re-run.');
    process.exit(1);
  }

  admin.initializeApp({ credential: admin.credential.cert(cred) });
  const db = admin.firestore();
  const CATS = categories(db);

  console.log(`\nProject: ${cred.project_id}   Room: ${ROOM_ID}\n`);
  const counts = {};
  for (const key of ORDER) {
    counts[key] = await countRefs(CATS[key].refs);
    console.log(
      `  ${key.padEnd(10)} ${String(counts[key]).padStart(6)}  ${CATS[key].label}`,
    );
  }
  console.log('');

  let selected = opts.selected;
  if (selected.length === 0) {
    const ans = await ask(
      'Which to delete? (e.g. applogs,calllogs | all | q to quit): ',
    );
    if (ans === '' || ans.toLowerCase() === 'q') {
      console.log('Nothing deleted.');
      process.exit(0);
    }
    try {
      selected = parseArgs(ans.split(',').map((s) => s.trim()).filter(Boolean))
        .selected;
    } catch (e) {
      console.error(e.message);
      process.exit(1);
    }
  }

  const toDelete = selected.filter((c) => counts[c] > 0);
  if (toDelete.length === 0) {
    console.log('Selected categories are already empty. Nothing to delete.');
    process.exit(0);
  }

  const totalDocs = toDelete.reduce((n, c) => n + counts[c], 0);
  console.log(`\nWill delete ${totalDocs} document(s) from: ${toDelete.join(', ')}`);

  if (opts.dryRun) {
    console.log('\n[dry-run] Nothing deleted.');
    process.exit(0);
  }

  if (!opts.yes) {
    const hasDanger = toDelete.some((c) => CATS[c].danger);
    if (hasDanger) {
      console.log(
        '\n⚠  Includes SHARED data (messages/reminders) — permanently deleted for BOTH phones.',
      );
      const confirm = await ask('Type DELETE to confirm: ');
      if (confirm !== 'DELETE') {
        console.log('Aborted.');
        process.exit(0);
      }
    } else {
      const confirm = await ask('Proceed? (y/N): ');
      if (confirm.toLowerCase() !== 'y') {
        console.log('Aborted.');
        process.exit(0);
      }
    }
  }

  for (const c of toDelete) {
    process.stdout.write(`Deleting ${c} (${counts[c]})... `);
    const n = await deleteRefs(db, CATS[c].refs);
    console.log(`done (${n}).`);
  }
  console.log('\n✅ Cleanup complete.');
  process.exit(0);
}

// Only run when invoked directly, so tests can import parseArgs cleanly.
if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

module.exports = { parseArgs, categories, ORDER, ROOM_ID };
