#!/usr/bin/env node
// Maintained Linux/Docker/KVM acceptance test. No dependency outside Node builtins.
// Usage: node tests/integration.mjs /absolute/ubuntu-24.04-minimal-cloudimg-amd64.img
// RUNTIME_IMAGE and TOOLS_IMAGE select locally built candidates. Never publishes.
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

const base = resolve(process.argv[2] ?? '');
assert(process.argv[2], 'Pass an existing Ubuntu 24.04 minimal cloud image; it is mounted read-only.');
const image = process.env.RUNTIME_IMAGE ?? 'nanocl-qemu:vm019-test';
const tools = process.env.TOOLS_IMAGE ?? 'nanocl-qemu:vm019-tools';
const work = mkdtempSync(`${tmpdir()}/nanocl-vm-test-`);
const prefix = basename(work);
const network = `${prefix}-net`;
const containers = new Set();
let networkOwned = false;
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { encoding: 'utf8', timeout: 120000, ...options }).trim();
const docker = (...args) => run('docker', args);
const attempt = (cmd, args) => spawnSync(cmd, args, { encoding: 'utf8', timeout: 10000 });
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const logs = name => { const result = attempt('docker', ['logs', name]); assert.equal(result.status, 0); return result.stdout + result.stderr; };
async function until(description, check, timeout = 120000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { if (check()) return; await delay(500); }
  throw new Error(`Timed out: ${description}`);
}
function sshArgs(ip, command, user = 'cloud') {
  return ['-i', `${work}/key`, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', `UserKnownHostsFile=${work}/known_hosts`, '-o', 'ConnectTimeout=3', `${user}@${ip}`, command];
}
const ssh = (vm, command) => run('ssh', sshArgs(vm.ip, command, vm.user));
async function ready(vm) {
  await until(`SSH ${vm.name}`, () => {
    assert.equal(docker('inspect', '-f', '{{.State.Running}}', vm.name), 'true', `${vm.name} exited; inspect ${work}`);
    return attempt('ssh', sshArgs(vm.ip, 'true', vm.user)).status === 0;
  });
}
async function launch(id, cloudInit, fixedIp, disk = `${work}/guest${id}.qcow2`, userData) {
  const name = `${prefix}-${id}`;
  const mac = `52:54:00:19:00:0${id}`;
  const vmDir = `${work}/vm${id}`;
  mkdirSync(vmDir, { recursive: true, mode: 0o700 });
  const args = ['create', '--name', name, '--network', network, '--cpus', '1', '--cap-add', 'NET_ADMIN', '--device', '/dev/kvm', '--device', '/dev/net/tun', '--sysctl', 'net.ipv4.ip_forward=1'];
  for (const scope of ['all', 'default']) for (const [key, value] of Object.entries({ proxy_arp: 1, arp_ignore: 1, send_redirects: 0, rp_filter: 0, accept_local: 1 })) args.push('--sysctl', `net.ipv4.conf.${scope}.${key}=${value}`);
  if (fixedIp) args.push('--ip', fixedIp);
  for (const env of [`MAC=${mac}`, 'NANOCL_NETWORK_MODE=bridge', `CLOUD_INIT=${cloudInit}`, `CONSOLE=${id === 1}`, `INSTANCE_ID=${name}`, `USER=${cloudInit && userData === undefined ? 'cloud' : 'ignored invalid user'}`, `SSH_KEY=${readFileSync(`${work}/key.pub`, 'utf8').trim()}`]) args.push('-e', env);
  if (userData !== undefined) args.push('-e', `CLOUD_INIT_USER_DATA=${userData}`, '-e', 'PASSWORD=ignored\ninvalid', '-e', 'DELETE_SSH_KEY=ignored');
  if (!cloudInit) args.push('-e', 'CLOUD_INIT_USER_DATA=ignored custom data');
  if (id === 2) args.push('-e', `DNS=${process.env.TEST_DNS ?? '1.1.1.1'}`);
  args.push('-v', `${base}:${base}:ro`, '-v', `${work}:${work}`, '-v', `${vmDir}:/run/nanocl-vm`, image, '-accel', 'kvm', '-m', '768M', '-smp', '1', '-drive', `file=${disk},if=virtio,format=qcow2`);
  docker(...args);
  containers.add(name);
  docker('start', name);
  const ip = docker('inspect', '-f', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', name);
  const vm = { name, ip, mac, vmDir, user: userData === undefined ? 'cloud' : 'provisioned' };
  await ready(vm);
  const qemuArgs = docker('exec', name, 'sh', '-c', 'tr "\\0" "\\n" </proc/$(pidof qemu-system-x86_64)/cmdline').split('\n');
  assert.equal(qemuArgs[qemuArgs.indexOf('-chardev') + 1], 'stdio,id=nanocl-serial,signal=off', 'serial Ctrl-C must remain guest input');
  assert.equal(qemuArgs[qemuArgs.indexOf('-serial') + 1], 'chardev:nanocl-serial');
  assert.equal(qemuArgs[qemuArgs.indexOf('-monitor') + 1], 'none', 'guest serial must not expose HMP');
  return vm;
}
// A local root helper opens the mode-0700 socket; QMP never gets a TCP listener.
async function withQmp(vm, action) {
  const name = `${vm.name}-qmp`;
  // Separate Docker startup from the protocol deadline and register ownership
  // before starting: a delayed container create must not escape cleanup.
  docker('create', '--name', name, '--network', 'none', '--cpus', '1', '-v', `${vm.vmDir}:/vm`, tools, 'tail', '-f', '/dev/null');
  containers.add(name);
  docker('start', name);
  assert.equal(docker('inspect', '-f', '{{.State.Running}}', name), 'true');
  const child = spawn('docker', ['exec', '-i', name, 'socat', '-', 'UNIX-CONNECT:/vm/qmp.sock'], { stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  const events = [];
  let sequence = 0;
  let stderr = '';
  let closed;
  const done = new Promise(resolve => child.once('close', resolve));
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-8192); });
  const settle = (key, error, value) => { const entry = pending.get(key); if (!entry) return; pending.delete(key); clearTimeout(entry.timer); error ? entry.reject(error) : entry.resolve(value); };
  const wait = key => new Promise((resolve, reject) => {
    if (closed) { reject(closed); return; }
    const timer = setTimeout(() => settle(key, new Error(`Timed out waiting for QMP ${key}: ${stderr}`)), 10000);
    pending.set(key, { resolve, reject, timer });
  });
  const fail = error => { closed = error; for (const key of pending.keys()) settle(key, error); };
  const greeting = wait('greeting');
  child.once('error', fail);
  child.stdin.on('error', fail);
  child.once('close', code => fail(new Error(`QMP helper exited (${code}): ${stderr}`)));
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    try {
      const message = JSON.parse(line);
      if (message.QMP) settle('greeting', undefined, message.QMP);
      else if (message.event) events.push(message);
      else if ('id' in message) settle(message.id, message.error ? new Error(JSON.stringify(message.error)) : undefined, message.return);
    } catch (error) { fail(error); }
  });
  const execute = async command => {
    const id = ++sequence;
    const response = wait(id);
    child.stdin.write(`${JSON.stringify({ execute: command, id })}\n`);
    return response;
  };
  try {
    await greeting;
    await execute('qmp_capabilities');
    return await action(execute, events);
  } finally {
    child.stdin.end();
    // Closing the transport ends socat, including after a failed assertion.
    const removed = attempt('docker', ['rm', '-f', name]);
    child.kill();
    await done;
    lines.close();
    if (removed.status === 0) containers.delete(name);
  }
}
function checkNetwork(vm) {
  const data = JSON.parse(ssh(vm, 'ip -j -4 addr show scope global'));
  assert.equal(data.length, 1);
  assert.equal(data[0].addr_info[0].local, vm.ip);
  assert.equal(data[0].addr_info[0].prefixlen, 24);
  assert.equal(ssh(vm, `cat /sys/class/net/${data[0].ifname}/address`), vm.mac);
  const routes = JSON.parse(ssh(vm, 'ip -j -4 route'));
  const gateway = docker('inspect', '-f', '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}', vm.name);
  assert.equal(routes.find(route => route.dst === 'default')?.gateway, gateway);
  assert(routes.some(route => route.dst === '169.254.254.1' && route.dev === data[0].ifname && !route.gateway), 'guest needs an on-link DHCP/DNS helper route');
  assert.equal(data[0].mtu, Number(docker('exec', vm.name, 'cat', '/sys/class/net/eth0/mtu')));
  assert(!docker('exec', vm.name, 'ip', '-4', 'addr').includes(`inet ${vm.ip}/`), 'container must not locally own the guest IP');
  docker('exec', vm.name, 'ip', 'neigh', 'flush', 'dev', 'eth0');
  ssh(vm, `sudo ip neigh flush dev ${data[0].ifname}`);
  // Actual guest UDP/TCP DNS, then an external HTTP request. No guest packages added.
  const program = `import socket,struct,urllib.request\ndef receive(s,n):\n r=b''\n while len(r)<n:\n  chunk=s.recv(n-len(r));assert chunk;r+=chunk\n return r\nfor kind,host in ((socket.SOCK_DGRAM,'example.com'),(socket.SOCK_STREAM,'example.org')):\n q=bytes.fromhex('123401000001000000000000')+b''.join(bytes([len(p)])+p.encode() for p in host.split('.'))+bytes.fromhex('0000010001')\n s=socket.socket(socket.AF_INET,kind);s.settimeout(10);s.connect(('169.254.254.1',53));s.sendall((struct.pack('!H',len(q)) if kind==socket.SOCK_STREAM else b'')+q)\n r=receive(s,struct.unpack('!H',receive(s,2))[0]) if kind==socket.SOCK_STREAM else s.recv(4096)\n assert len(r)>12 and r[:2]==q[:2] and r[3]&15==0 and struct.unpack('!H',r[6:8])[0]>0\nprint(urllib.request.urlopen('http://example.com',timeout=15).status)\n`;
  assert.equal(ssh(vm, `python3 -c ${quote(program)}`), '200');
  return data[0].ifname;
}
async function renewalAndIsolation(vm, iface) {
  const capture = `${vm.name}-capture`;
  docker('create', '--name', capture, '--network', `container:${vm.name}`, '--cap-add', 'NET_RAW', '-v', `${work}:${work}`, tools, 'tcpdump', '-U', '-i', 'eth0', '-w', `${work}/dhcp.pcap`, 'udp', 'portrange', '67-68');
  containers.add(capture);
  docker('start', capture);
  await until('capture ready', () => logs(capture).includes('listening on eth0'));
  const before = (logs(vm.name).match(/DHCPACK/g) ?? []).length;
  ssh(vm, `sudo networkctl renew ${iface}`);
  await until('DHCP renewal acknowledged', () => (logs(vm.name).match(/DHCPACK/g) ?? []).length > before);
  docker('stop', '-t', '3', capture);
  const packets = docker('run', '--rm', '--network', 'none', '-v', `${work}:${work}:ro`, tools, 'tcpdump', '-nr', `${work}/dhcp.pcap`);
  assert.equal(packets, '', 'DHCP escaped the private TAP');
}

console.log(`Evidence/overlays: ${work}`);
try {
  assert.equal(docker('image', 'inspect', '-f', '{{index .Config.Labels "io.nanocl.vm-runtime-api"}}', image), '0.19');
  assert.equal(docker('image', 'inspect', '-f', '{{index .Config.Labels "io.nanocl.vm-cloud-init-user-data"}}', image), '1');
  assert.equal(docker('image', 'inspect', '-f', '{{index .Config.Labels "io.nanocl.vm-qmp"}}', image), '1');
  docker('run', '--rm', '--entrypoint', 'bash', image, '-n', '/entrypoint.sh');
  docker('run', '--rm', '--entrypoint', 'shellcheck', tools, '/entrypoint.sh');
  const invalid = attempt('docker', ['run', '--rm', '--network', 'none', '-e', 'MAC=ff:ff:ff:ff:ff:ff', image]);
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /unicast/);
  const format = JSON.parse(run('qemu-img', ['info', '--output=json', base])).format;
  for (const id of [1, 2]) run('qemu-img', ['create', '-f', 'qcow2', '-F', format, '-b', base, `${work}/guest${id}.qcow2`, '4G']);
  run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', `${work}/key`]);
  docker('network', 'create', '--subnet', process.env.TEST_SUBNET ?? '172.29.222.0/24', network);
  networkOwned = true;
  const first = await launch(1, true);
  assert.match(ssh(first, 'cloud-init status --wait'), /status: done/);
  const iface = checkNetwork(first);
  console.log('PASS cloud-init boot, same Docker IP, /24, stable MAC, guest UDP/TCP DNS, outbound HTTP and SSH ingress');
  await renewalAndIsolation(first, iface);
  console.log('PASS explicit DHCP renewal and no uplink DHCP packets');
  const customData = `#cloud-config\nusers:\n  - name: provisioned\n    sudo: 'ALL=(ALL) NOPASSWD:ALL'\n    shell: /bin/bash\n    ssh_authorized_keys:\n      - ${readFileSync(`${work}/key.pub`, 'utf8').trim()}\nwrite_files:\n  - path: /etc/nanocl-provisioned\n    permissions: '0644'\n    content: |\n      café 'quoted' $literal\nruncmd:\n  - [touch, /etc/nanocl-runcmd]\n\n`;
  const second = await launch(2, true, undefined, undefined, customData);
  assert.match(ssh(second, 'cloud-init status --wait'), /status: done/);
  assert.equal(execFileSync('docker', ['exec', second.name, 'cat', '/run/nanocl-runtime/user-data'], { encoding: 'utf8' }), customData);
  assert.equal(execFileSync('ssh', sshArgs(second.ip, 'sudo cat /var/lib/cloud/instance/user-data.txt', second.user), { encoding: 'utf8' }), customData);
  assert.equal(ssh(second, 'cat /etc/nanocl-provisioned && test -f /etc/nanocl-runcmd && ! getent passwd cloud'), "café 'quoted' $literal");
  assert.equal(ssh(second, 'cloud-init query instance_id'), second.name);
  checkNetwork(second);
  console.log('PASS custom user-data is unchanged in runtime and guest; custom SSH user, write_files/runcmd, stable instance ID and managed DHCP');
  assert.notEqual(first.ip, second.ip);
  ssh(first, `python3 -c 'import socket; s=socket.create_connection(("${second.ip}",22),10); assert s.recv(64).startswith(b"SSH-")'`);
  assert(!docker('exec', second.name, 'ss', '-lnt').match(/:(5900|6080)\b/));
  console.log('PASS two simultaneous VMs and guest-to-guest ingress; console disabled');
  const rfb = docker('run', '--rm', '--network', 'none', '-v', `${first.vmDir}:/vm`, tools, 'sh', '-c', 'timeout 2 socat - UNIX-CONNECT:/vm/console.sock | head -c 12');
  assert.equal(rfb, 'RFB 003.008');
  console.log('PASS private Unix VNC protocol; NanoCL authorized WebSocket/browser validation is separate');
  for (const vm of [first, second]) {
    assert.equal(docker('exec', vm.name, 'stat', '-c', '%a', '/run/nanocl-vm'), '700');
    assert.equal(docker('exec', vm.name, 'stat', '-c', '%a', '/run/nanocl-vm/qmp.sock'), '700');
    await withQmp(vm, async (execute, events) => {
      assert.equal((await execute('query-status')).status, 'running');
      await execute('stop');
      assert.equal((await execute('query-status')).status, 'paused');
      assert(events.some(event => event.event === 'STOP'));
      await execute('cont');
      assert.equal((await execute('query-status')).status, 'running');
      assert(events.some(event => event.event === 'RESUME'));
    });
  }
  console.log('PASS private QMP negotiation, status and pause/resume events with console enabled and disabled');
  const hostKeys = ssh(second, 'sha256sum /etc/ssh/ssh_host_*_key.pub');
  // Intentionally leave this buffered; ACPI shutdown must flush it without sync.
  ssh(second, "sudo sh -c 'printf qmp-clean-shutdown >/etc/nanocl-before-powerdown'");
  await withQmp(second, async execute => {
    // A paused guest cannot process ACPI. Acceptance alone must not be mistaken
    // for shutdown completion or force the runtime to terminate the guest.
    await execute('stop');
    await execute('system_powerdown');
    assert.equal((await execute('query-status')).status, 'paused');
    assert.equal(docker('inspect', '-f', '{{.State.Running}}', second.name), 'true');
    await execute('cont');
  });
  await until('QMP powerdown stops runtime', () => docker('inspect', '-f', '{{.State.Running}}', second.name) === 'false');
  assert.equal(docker('inspect', '-f', '{{.State.ExitCode}}', second.name), '0');
  assert.equal(docker('run', '--rm', '--network', 'none', '-v', `${second.vmDir}:/vm`, tools, 'sh', '-c', 'test ! -e /vm/qmp.sock && test ! -e /vm/console.sock'), '');
  docker('start', second.name);
  await ready(second);
  assert.equal(ssh(second, 'sha256sum /etc/ssh/ssh_host_*_key.pub'), hostKeys);
  assert.equal(ssh(second, 'cat /etc/nanocl-before-powerdown'), 'qmp-clean-shutdown');
  checkNetwork(second);
  console.log('PASS QMP powerdown acknowledgement leaves a paused guest alive; resume completes ACPI shutdown and preserves buffered writes, IP, MAC and SSH hostkeys across a new start');
  ssh(first, 'sudo apt-get purge -y cloud-init >/dev/null; test ! -e /usr/bin/cloud-init');
  const netplan = `network:\n  version: 2\n  ethernets:\n    guest:\n      match:\n        macaddress: ${first.mac}\n      set-name: nanocl0\n      dhcp4: true\n      dhcp6: false\n      accept-ra: false\n      link-local: []\n`;
  ssh(first, `printf '%s' '${netplan}' | sudo tee /etc/netplan/01-dhcp.yaml >/dev/null; sudo chmod 600 /etc/netplan/01-dhcp.yaml; sudo rm -f /etc/netplan/50-cloud-init.yaml; sudo poweroff`);
  await until('guest poweroff stops runtime', () => docker('inspect', '-f', '{{.State.Running}}', first.name) === 'false');
  assert.equal(docker('inspect', '-f', '{{.State.ExitCode}}', first.name), '0');
  docker('rm', first.name);
  containers.delete(first.name);
  run('qemu-img', ['convert', '-O', 'qcow2', `${work}/guest1.qcow2`, `${work}/guest-no-cloud-init.qcow2`]);
  const plainDisk = `${work}/guest-no-cloud-init-boot.qcow2`;
  copyFileSync(`${work}/guest-no-cloud-init.qcow2`, plainDisk);
  const plain = await launch(1, false, first.ip, plainDisk);
  ssh(plain, 'test ! -e /usr/bin/cloud-init');
  docker('exec', plain.name, 'sh', '-c', 'test ! -e /run/nanocl-runtime/seed.img; ! tr "\\0" " " </proc/$(pidof qemu-system-x86_64)/cmdline | grep -q -- -cdrom');
  checkNetwork(plain);
  console.log('PASS cloud-init package absent and no seed attached; DHCP/ingress/DNS/HTTP still work');
  // Keep the namespace alive so runtime cleanup is observable after PID 1 exits.
  const observer = `${prefix}-observer`;
  docker('create', '--name', observer, '--network', `container:${plain.name}`, '--cap-add', 'NET_ADMIN', tools, 'tail', '-f', '/dev/null');
  containers.add(observer);
  docker('start', observer);
  // Docker can use nftables while Alpine's default iptables uses legacy tables.
  const firewall = docker('exec', observer, 'sh', '-c', 'iptables-save; iptables-nft-save');
  assert(firewall.includes(':DOCKER_OUTPUT '), 'Docker embedded resolver rules must remain installed');
  docker('exec', plain.name, 'sh', '-c', 'kill -TERM $(pidof dnsmasq)');
  await until('dnsmasq failure stops runtime', () => docker('inspect', '-f', '{{.State.Running}}', plain.name) === 'false');
  assert.notEqual(docker('inspect', '-f', '{{.State.ExitCode}}', plain.name), '0');
  assert.equal(docker('run', '--rm', '--network', 'none', '-v', `${plain.vmDir}:/vm`, tools, 'sh', '-c', 'test ! -e /vm/qmp.sock && test ! -e /vm/console.sock'), '');
  assert(!docker('exec', observer, 'ip', 'link').includes('nanocl-tap'));
  assert(!docker('exec', observer, 'iptables-save').includes('NANOCL_VM_'));
  // Docker removes its endpoint/uplink after the primary container exits.
  // The observer proves runtime TAP/rule cleanup, not Docker endpoint lifetime.
  console.log('PASS DHCP service failure stops QEMU; TAP and owned rules removed, Docker resolver rules preserved during operation');
} finally {
  for (const name of containers) {
    const logs = attempt('docker', ['logs', name]);
    writeFileSync(`${work}/${name}.log`, `${logs.stdout ?? ''}\n${logs.stderr ?? ''}`);
    attempt('docker', ['rm', '-f', name]);
  }
  if (networkOwned) {
    const removed = attempt('docker', ['network', 'rm', network]);
    assert.equal(removed.status, 0, `Cleanup failed for network ${network}: ${removed.stderr}`);
  }
  const remaining = docker('ps', '-aq', '--filter', `name=^/${prefix}-`);
  assert.equal(remaining, '', 'task containers survived cleanup');
  console.log(`Task containers removed; retained task-only disks and evidence in ${work}`);
}
