#!/usr/bin/env node
// Launcher and early runtime validation regressions; no Docker daemon or KVM.
// Usage: node --test tests/launcher.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, test } from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const work = mkdtempSync(join(tmpdir(), 'nanocl-launcher-test-'));
after(() => rmSync(work, { recursive: true, force: true }));
writeFileSync(join(work, 'docker'), '#!/bin/bash\nprintf \'%s\\0\' "$@"\n', { mode: 0o700 });
const env = { PATH: `${work}:/usr/bin:/bin`, MAC: '52:54:00:19:00:01', DISK: '/test/guest.qcow2' };
const run = (script, values = {}, args = []) => spawnSync('/bin/bash', [join(root, script), ...args], {
  env: { ...env, ...values }, encoding: 'utf8', timeout: 5000,
});
function dockerArgs(values) {
  const result = run('start_vm.sh', values);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.split('\0').slice(0, -1);
}

test('launcher forwards explicit SSH host-key policy, including false and zero', () => {
  for (const value of ['true', 'false', '1', '0']) {
    const args = dockerArgs({ DELETE_SSH_KEY: value });
    const index = args.indexOf(`DELETE_SSH_KEY=${value}`);
    assert(index > 0);
    assert.equal(args[index - 1], '-e');
  }
  assert(!dockerArgs({}).some(arg => arg.startsWith('DELETE_SSH_KEY=')), 'unset policy must retain the runtime default');
});

test('console enabled launcher binds the supplied private VM directory', () => {
  const directory = join(work, 'private console');
  mkdirSync(directory, { mode: 0o700 });
  for (const value of ['true', '1']) {
    const args = dockerArgs({ CONSOLE: value, CONSOLE_DIR: directory });
    const index = args.indexOf('--mount');
    assert(index > 0);
    assert.equal(args[index + 1], `type=bind,source=${directory},target=/run/nanocl-console`);
  }
  for (const value of ['false', '0']) assert(!dockerArgs({ CONSOLE: value }).includes('--mount'));
});

test('console launcher refuses absent, non-private, relative and symlink directories before Docker', () => {
  const shared = join(work, 'shared');
  mkdirSync(shared);
  chmodSync(shared, 0o755);
  const privateTarget = join(work, 'private-target');
  mkdirSync(privateTarget, { mode: 0o700 });
  const link = join(work, 'linked');
  symlinkSync(privateTarget, link);
  for (const directory of [undefined, join(work, 'missing'), 'relative', shared, link]) {
    const result = run('start_vm.sh', { CONSOLE: 'true', ...(directory === undefined ? {} : { CONSOLE_DIR: directory }) });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONSOLE_DIR/);
    assert.equal(result.stdout, '', 'Docker must not be invoked');
  }
});

test('runtime rejects shutdown lifecycle overrides before touching its namespace', () => {
  for (const args of [['-no-shutdown'], ['--no-shutdown'], ['-action', 'shutdown=pause'], ['--action', 'shutdown=pause']]) {
    const result = run('entrypoint.sh', {}, args);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /conflicts with runtime-managed networking, display or supervision/);
    assert(result.stderr.includes(args[0]));
  }
  const allowed = run('entrypoint.sh', {}, ['-m', '768M', '-smp', '1']);
  assert.notEqual(allowed.status, 0);
  assert.match(allowed.stderr, /NANOCL_NETWORK_MODE=bridge/);
});
