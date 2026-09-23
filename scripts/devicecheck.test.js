'use strict';

// Pure verdict tests — no Firebase, no network. Run: `node --test` in scripts/.
const { test } = require('node:test');
const assert = require('node:assert');
const { verdictFor, lastOpened } = require('./devicecheck');

/** Minimal stand-in for a Firestore Timestamp. */
const ts = (d) => ({ toDate: () => d });

test('a role that never claimed a device has never had the app', () => {
  const v = verdictFor({ claimed: false, hasToken: false });
  assert.strictEqual(v.installed, false);
  assert.strictEqual(v.label, 'NEVER INSTALLED');
});

test('claimed but no token is reported apart from an uninstall', () => {
  const v = verdictFor({ claimed: true, hasToken: false });
  assert.strictEqual(v.installed, false);
  assert.strictEqual(v.label, 'NO PUSH TOKEN');
});

test('an accepted dry run means the app is still installed', () => {
  const v = verdictFor({ claimed: true, hasToken: true, tokenError: null });
  assert.strictEqual(v.installed, true);
  assert.strictEqual(v.label, 'INSTALLED');
});

test('a retired token is the conclusive uninstall signal', () => {
  const v = verdictFor({
    claimed: true,
    hasToken: true,
    tokenError: 'messaging/registration-token-not-registered',
  });
  assert.strictEqual(v.installed, false);
  assert.strictEqual(v.label, 'GONE');
});

test('a malformed token counts as not installed, not as unknown', () => {
  for (const code of [
    'messaging/invalid-argument',
    'messaging/invalid-registration-token',
  ]) {
    const v = verdictFor({ claimed: true, hasToken: true, tokenError: code });
    assert.strictEqual(v.installed, false, code);
    assert.strictEqual(v.label, 'BAD TOKEN', code);
  }
});

test('an unrecognised FCM error admits it cannot tell', () => {
  // A quota or auth failure must never be reported as an uninstall.
  const v = verdictFor({
    claimed: true,
    hasToken: true,
    tokenError: 'messaging/server-unavailable',
  });
  assert.strictEqual(v.installed, null);
  assert.strictEqual(v.label, 'UNKNOWN');
  assert.match(v.detail, /server-unavailable/);
});

test('lastOpened takes the later of the chat and todo stamps', () => {
  const room = {
    appLastOpened: { A: ts(new Date('2026-07-15T09:00:00Z')) },
    todoLastOpened: { A: ts(new Date('2026-07-15T11:00:00Z')) },
  };
  assert.strictEqual(
    lastOpened(room, 'A').toDate().toISOString(),
    '2026-07-15T11:00:00.000Z',
  );
});

test('lastOpened copes with only one stamp, or none at all', () => {
  const room = { todoLastOpened: { B: ts(new Date('2026-07-14T08:00:00Z')) } };
  assert.strictEqual(
    lastOpened(room, 'B').toDate().toISOString(),
    '2026-07-14T08:00:00.000Z',
  );
  assert.strictEqual(lastOpened({}, 'A'), null);
  assert.strictEqual(lastOpened({ appLastOpened: {} }, 'A'), null);
});
