#!/usr/bin/env node
// Launcher and early runtime validation regressions; no Docker daemon or KVM.
// Usage: node --test tests/launcher.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, test } from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const work = mkdtempSync(join(tmpdir(), 'nanocl-launcher-test-'));
after(() => rmSync(work, { recursive: true, force: true }));
writeFileSync(join(work, 'docker'), '#!/bin/bash\nif [[ ${TEST_USER_DATA_OUTPUT:-} ]]; then printf \'%s\' "$CLOUD_INIT_USER_DATA" >"$TEST_USER_DATA_OUTPUT"; fi\nprintf \'%s\\0\' "$@"\n', { mode: 0o700 });
const vmDirectory = join(work, 'vm');
mkdirSync(vmDirectory, { mode: 0o700 });
const env = { PATH: `${work}:/usr/bin:/bin`, MAC: '52:54:00:19:00:01', DISK: '/test/guest.qcow2', VM_DIR: vmDirectory };
const run = (script, values = {}, args = []) => spawnSync('/bin/bash', [join(root, script), ...args], {
  env: { ...env, ...values }, encoding: 'utf8', timeout: 5000,
});
function dockerArgs(values) {
  const result = run('start_vm.sh', values);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.split('\0').slice(0, -1);
}

test('launcher chooses the guest account independently of the host USER', () => {
  for (const [values, expected] of [
    [{}, 'cloud'],
    [{ USER: 'alice' }, 'cloud'],
    [{ USER: 'alice', GUEST_USER: '' }, 'cloud'],
    [{ USER: 'alice', GUEST_USER: 'vmadmin' }, 'vmadmin'],
  ]) {
    const args = dockerArgs(values);
    assert.deepEqual(args.filter(arg => arg.startsWith('USER=')), [`USER=${expected}`]);
    assert.equal(args[args.indexOf(`USER=${expected}`) - 1], '-e');
  }
});

test('launcher forwards explicit SSH host-key policy, including false and zero', () => {
  for (const value of ['true', 'false', '1', '0']) {
    const args = dockerArgs({ DELETE_SSH_KEY: value });
    const index = args.indexOf(`DELETE_SSH_KEY=${value}`);
    assert(index > 0);
    assert.equal(args[index - 1], '-e');
  }
  assert(!dockerArgs({}).some(arg => arg.startsWith('DELETE_SSH_KEY=')), 'unset policy must retain the runtime default');
});

test('launcher preserves custom user-data file bytes, including empty data and trailing newlines', () => {
  for (const data of ['', '#cloud-config\n# café \'quoted\' $literal $(untouched)\n\n', 'x'.repeat(65536)]) {
    const path = join(work, 'user data.yaml');
    const output = join(work, 'forwarded-user-data');
    writeFileSync(path, data);
    const args = dockerArgs({ CLOUD_INIT_USER_DATA_FILE: path, TEST_USER_DATA_OUTPUT: output });
    assert.equal(readFileSync(output, 'utf8'), data);
    const index = args.indexOf('CLOUD_INIT_USER_DATA');
    assert(index > 0);
    assert.equal(args[index - 1], '-e');
    assert(!args.some(arg => arg.startsWith('CLOUD_INIT_USER_DATA=')), 'payload must not appear in Docker command arguments');
  }
});

test('launcher rejects unreadable, NUL, oversized and ambiguous user-data inputs before Docker', () => {
  const nul = join(work, 'nul-user-data');
  const large = join(work, 'large-user-data');
  writeFileSync(nul, 'before\0after');
  writeFileSync(large, 'é'.repeat(32769));
  for (const values of [
    { CLOUD_INIT_USER_DATA_FILE: join(work, 'absent') },
    { CLOUD_INIT_USER_DATA_FILE: work },
    { CLOUD_INIT_USER_DATA_FILE: nul },
    { CLOUD_INIT_USER_DATA_FILE: large },
    { CLOUD_INIT_USER_DATA_FILE: nul, CLOUD_INIT_USER_DATA: '' },
    { CLOUD_INIT_USER_DATA: 'x'.repeat(65537) },
  ]) {
    const result = run('start_vm.sh', values);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CLOUD_INIT_USER_DATA/);
    assert.equal(result.stdout, '', 'Docker must not be invoked');
  }
  for (const value of ['false', '0']) {
    const args = dockerArgs({ CLOUD_INIT: value, CLOUD_INIT_USER_DATA_FILE: nul, CLOUD_INIT_USER_DATA: 'x'.repeat(65537) });
    assert(!args.includes('CLOUD_INIT_USER_DATA'), 'disabled provisioning ignores custom data');
  }
});

test('runtime bounds custom user-data by bytes only when cloud-init is enabled', () => {
  const rejected = run('entrypoint.sh', { CLOUD_INIT_USER_DATA: 'é'.repeat(32769) });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /must not exceed 65536 bytes/);
  for (const values of [{ CLOUD_INIT_USER_DATA: 'x'.repeat(65536) }, { CLOUD_INIT: 'false', CLOUD_INIT_USER_DATA: 'x'.repeat(65537) }]) {
    const result = run('entrypoint.sh', values);
    assert.match(result.stderr, /NANOCL_NETWORK_MODE=bridge/, 'accepted data reaches the existing namespace validation');
  }
});

test('launcher always binds the private VM directory, including without a console', () => {
  const directory = join(work, 'private vm');
  mkdirSync(directory, { mode: 0o700 });
  for (const value of ['true', '1', 'false', '0']) {
    const args = dockerArgs({ CONSOLE: value, VM_DIR: directory });
    const index = args.indexOf('--mount');
    assert(index > 0);
    assert.equal(args[index + 1], `type=bind,source=${directory},target=/run/nanocl-vm`);
    assert.equal(args.filter(arg => arg === '--mount').length, 1);
  }
});

test('launcher refuses absent, non-private, relative and symlink VM directories before Docker', () => {
  const shared = join(work, 'shared');
  mkdirSync(shared);
  chmodSync(shared, 0o755);
  const privateTarget = join(work, 'private-target');
  mkdirSync(privateTarget, { mode: 0o700 });
  const link = join(work, 'linked');
  symlinkSync(privateTarget, link);
  for (const directory of [undefined, join(work, 'missing'), 'relative', shared, link, '/tmp/vm,other']) {
    const result = run('start_vm.sh', { VM_DIR: directory });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /VM_DIR/);
    assert.equal(result.stdout, '', 'Docker must not be invoked');
  }
});

test('runtime rejects shutdown and monitor overrides before touching its namespace', () => {
  for (const args of [
    ['-no-shutdown'], ['--no-shutdown'], ['-action', 'shutdown=pause'], ['--action', 'shutdown=pause'],
    ['-qmp', 'tcp:0.0.0.0:4444,server=on'], ['--qmp', 'stdio'],
    ['-qmp-pretty', 'stdio'], ['--qmp-pretty', 'stdio'],
    ['-mon', 'chardev=other'], ['--mon', 'chardev=other'],
    ['-monitor', 'stdio'], ['--monitor', 'stdio'],
    ['-readconfig', '/tmp/other.cfg'], ['--readconfig', '/tmp/other.cfg'],
  ]) {
    const result = run('entrypoint.sh', {}, args);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /conflicts with runtime-managed networking, display, monitor or supervision/);
    assert(result.stderr.includes(args[0]));
  }
  const allowed = run('entrypoint.sh', {}, ['-m', '768M', '-smp', '1']);
  assert.notEqual(allowed.status, 0);
  assert.match(allowed.stderr, /NANOCL_NETWORK_MODE=bridge/);
});
