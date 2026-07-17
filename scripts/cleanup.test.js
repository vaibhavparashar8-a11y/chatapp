'use strict';

// Pure arg-parsing tests — no Firebase/network. Run: `node --test` in scripts/.
const { test } = require('node:test');
const assert = require('node:assert');
const { parseArgs, ORDER } = require('./cleanup');

test('selects a single category', () => {
  assert.deepStrictEqual(parseArgs(['applogs']).selected, ['applogs']);
});

test('de-dupes and returns canonical order regardless of input order', () => {
  assert.deepStrictEqual(
    parseArgs(['reminders', 'applogs', 'applogs']).selected,
    ['applogs', 'reminders'],
  );
});

test('"all" expands to every category', () => {
  assert.deepStrictEqual(parseArgs(['all']).selected, ORDER);
});

test('parses --dry-run and --yes flags alongside categories', () => {
  const o = parseArgs(['--dry-run', '-y', 'messages']);
  assert.strictEqual(o.dryRun, true);
  assert.strictEqual(o.yes, true);
  assert.deepStrictEqual(o.selected, ['messages']);
});

test('empty args select nothing (interactive mode)', () => {
  assert.deepStrictEqual(parseArgs([]).selected, []);
});

test('throws on an unknown token so a typo cannot delete the wrong thing', () => {
  assert.throws(() => parseArgs(['bogus']), /Unknown argument/);
});
