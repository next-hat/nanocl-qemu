# nanocl-qemu

QEMU runtime for NanoCL 0.19. The guest receives the **same IPv4 address as its
Docker container** by DHCP. Cloud-init is optional. An optional console listens
on a private Unix socket and is exposed through NanoCL's authorized WebSocket
endpoint, suitable for noVNC.

## Networking

Each VM needs its own Docker bridge network namespace with one IPv4 endpoint.
NanoCL persists a unicast MAC and passes it to QEMU. The runtime discovers the
actual Docker address, prefix, gateway and MTU; it does not assume `/16` or public
DNS resolvers.

The runtime removes the Docker address from the container's uplink, creates a
private TAP, and routes the guest's `/32` through it. The guest alone owns the
Docker address. Proxy ARP connects the TAP and Docker uplink while Docker keeps
its existing endpoint and MAC. Guest packets are not translated inside the
runtime. Docker's ordinary bridge egress and published-port behavior still apply.

A dnsmasq instance listens only on the private TAP. It leases the Docker address
to the configured MAC (`id:*` ignores changing DHCP client identifiers), supplies
the real subnet, gateway and MTU, and ignores unknown MACs. Leases last one hour
and renew after 30 minutes. A private `169.254.254.1/32` address supplies DHCP and
DNS; option 121 makes it directly reachable and preserves the default gateway.
The DNS service forwards the container's resolver configuration, including
Docker's `127.0.0.11`, or the explicit `DNS` override. Only helper-originated
upstream DNS traffic uses SNAT to the Docker address. Existing Docker DNS
firewall rules are preserved.

The same helper address can be reused in separate namespaces. Linux
`accept_local=1` permits proxy ARP between their unnumbered uplinks;
`arp_ignore=1` prevents the helper address from answering on the uplink. New
uplink traffic to the helper and all forwarded DHCP traffic are dropped. The
runtime also rejects guest source addresses other than its assigned IPv4.
There is no bridge carrying guest DHCP broadcasts onto the Docker network.

Alternatives considered:

- Bridging TAP and uplink while both retain the address creates competing IP
  ownership; removing container ownership makes DHCP/DNS service addressing and
  Docker endpoint behavior harder to isolate.
- A private guest subnet with NAT gives straightforward DHCP isolation, but makes
  `ip addr` in the guest differ from the Docker address.
- Routed TAP with proxy ARP preserves the required address and isolates DHCP,
  with explicit namespace sysctls and a narrowly scoped DNS translation rule.

Only a dedicated IPv4 Docker bridge namespace is supported. Host, shared
`container:`, none, internal, macvlan, overlay, multiple endpoints, global IPv6,
additional routes, and subnets overlapping the private helper are unsupported.
NanoCL validates Docker driver/mode information before creation. The standalone
`NANOCL_NETWORK_MODE=bridge` flag is an operator assertion: an in-container
process cannot prove namespace exclusivity. Do not set it for shared namespaces.

## Build and start

Build locally; the candidate release image is not published by these commands:

```sh
docker build -t nanocl-qemu:vm019-test .
```

The current Alpine 3.18 package build resolves QEMU 8.0.5 and dnsmasq 2.90. The
candidate nightly tag is `ghcr.io/next-hat/nanocl-qemu:8.0.5.0-nightly`, with the
`io.nanocl.vm-runtime-api=0.19` label. Custom user-data additionally requires
`io.nanocl.vm-cloud-init-user-data=1`. Registry publication is a separate release
step. NanoCL requires the label so an old runtime cannot silently ignore the new
configuration. After publication, CI can explicitly select this nightly image
for end-to-end testing.

Use an existing disk with a DHCP-capable guest. Keep a separate copy or qcow2
overlay for each VM; never open one writable disk from multiple QEMU processes.
The included launcher supplies required namespace sysctls and devices:

```sh
MAC=52:54:00:00:00:01 IMAGE=nanocl-qemu:vm019-test \
  DISK="$PWD/server.img" ./start_vm.sh
```

The launcher uses Docker's default bridge. Set `NETWORK` to a user-defined bridge
for Docker service-name resolution. KVM requires `/dev/kvm`; runtime networking
requires `/dev/net/tun` and `NET_ADMIN`. Privileged containers and host networking
are unnecessary. The runtime owns network/display/supervision QEMU options;
disk, memory, CPU and acceleration arguments remain configurable. In particular,
`-no-shutdown`, `-action` and their double-dash aliases are rejected so guest
poweroff stops the runtime instead of pausing QEMU.

The standalone launcher uses `GUEST_USER` for the generated guest account,
defaulting to `cloud` when unset or empty. For example, set `GUEST_USER=vmadmin`
alongside `SSH_KEY` to provision that account. The launcher maps this value to
the runtime's `USER` environment variable and ignores the host shell's `USER`.
Direct Docker runs still use `USER`; NanoCL's `User` field is unchanged. Custom
user-data owns the guest accounts when supplied and ignores this generated value.

## Configuration

| Environment | Default | Meaning |
| --- | --- | --- |
| `MAC` | required | Stable, nonzero, unicast guest MAC; owned and persisted by NanoCL. |
| `NANOCL_NETWORK_MODE` | required | `bridge`, after confirming a dedicated Docker bridge namespace. |
| `DEFAULT_INTERFACE` | discovered | Must match the sole default-route interface. |
| `CLOUD_INIT` | `true` | Generate and attach a NoCloud seed for provisioning. |
| `CLOUD_INIT_USER_DATA` | unset | Complete custom user-data, up to 65536 UTF-8 bytes; replaces generated user/password/SSH configuration, including when empty. |
| `INSTANCE_ID` | MAC | Stable cloud-init instance identity; NanoCL passes the VM key. |
| `USER`, `PASSWORD` | `cloud`, `cloud` | Generated cloud-init defaults when custom user-data is absent; change the password or supply an SSH key. |
| `SSH_KEY` | none | Single authorized public key for the generated user. Ignored with custom user-data. |
| `DELETE_SSH_KEY` | `true` | Generated cloud-init SSH host-key generation policy. Ignored with custom user-data. |
| `DNS` | container resolvers | Optional comma-separated IPv4 upstream DNS servers. Guest DNS remains the private forwarder. |
| `CONSOLE` | `false` | Enable raw VNC on `/run/nanocl-console/console.sock`. |
| `GRAPHIC` | `false` | Local GTK/SDL display, requiring `DISPLAY` and operator-provided display mounts. |
| `GRAPHIC_BACKEND` | `auto` | Local display backend: `auto`, `gtk`, or `sdl`. |

Booleans accept `true`/`false` or `1`/`0`. Console and local graphics are mutually
exclusive. Generated provisioning values must be single-line strings and are
quoted as YAML. Custom user-data is copied without interpolation, YAML merging,
or newline changes. The runtime does not log provisioning content; Docker
inspect and NanoCL VM inspection expose it to authorized operators, like the
existing password/SSH fields.

For manual Docker runs, pass `--sysctl net.ipv4.ip_forward=1` and, for **both**
`all` and `default`, `net.ipv4.conf.<scope>.proxy_arp=1`, `arp_ignore=1`,
`send_redirects=0`, `rp_filter=0`, and `accept_local=1`. The runtime verifies these
before changing addresses because Docker mounts `/proc/sys` read-only.

## Optional cloud-init and migration

With `CLOUD_INIT=true`, the seed configures IPv4 DHCP matched by the stable MAC,
with the interface named `nanocl0`. When `CLOUD_INIT_USER_DATA` is unset, it also
generates the hostname, user and SSH key/password configuration.
The stable name prevents early netplan generation from waiting for a name that
udev subsequently changes during boot. DHCPv6, router advertisements, and IPv6
link-local addresses are disabled to match the runtime's IPv4-only contract.
It never contains a static guest address or
hardcoded DNS. The seed uses a stable instance ID and does not run `cloud-init
clean`: provisioning is not silently repeated on every boot.

Supply a complete cloud-init user-data document to configure additional users,
packages, files or commands. With the standalone launcher, provide a UTF-8 file
using `CLOUD_INIT_USER_DATA_FILE`:

```sh
MAC=52:54:00:00:00:01 CLOUD_INIT_USER_DATA_FILE="$PWD/user-data.yaml" \
  DISK="$PWD/server.img" ./start_vm.sh
```

The launcher accepts an empty file, preserves trailing newlines, rejects NUL
bytes and documents over 65536 bytes, and passes the content through Docker's
environment without placing it in the command arguments. Supply either the file
or an exported `CLOUD_INIT_USER_DATA`, not both. For direct Docker runs, export
the document and pass `-e CLOUD_INIT_USER_DATA`. A cloud-config YAML document
needs its `#cloud-config` header; scripts and other cloud-init user-data formats
can also be passed unchanged. NanoCL's stable instance ID and DHCP network
configuration are retained. Custom data fully owns guest account, password, SSH
key, hostname and host-key policies: set everything the guest needs, including
access credentials. The runtime does not validate cloud-init syntax; invalid
content is reported by cloud-init inside the guest.

With `CLOUD_INIT=false`, no seed is generated or attached. The guest needs its
own DHCP-capable network configuration; cloud-init need not be installed.
Custom user-data and generated provisioning values are ignored in this mode.
Existing images containing static network configuration must be changed to DHCP
before switching. Existing disks that were provisioned under the old instance
ID may see a one-time provisioning run after migration; back them up and inspect
cloud-init state first. User/password/SSH and custom user-data changes are initial
provisioning, not a general guest configuration-management mechanism. Updating
the data does not force once-per-instance cloud-init modules to run again on an
already provisioned disk.

Random MAC generation, `FROM_NETWORK`/`TO_NETWORK` renaming, arbitrary `IP`
overrides, and the old public websockify path are removed. `IP`, when supplied,
must equal the detected Docker address. `WEBSOCKIFY=true` and `SPICE=true` fail
with an explicit migration error. Remove raw `-nographic`/`--nographic` and other
runtime-owned QEMU network/display options; the runtime selects headless output
or the requested display. Default headless serial output remains in Docker logs.

## Console and lifecycle

`CONSOLE=true` creates a raw QEMU VNC Unix socket in a directory with mode 0700.
It creates no TCP VNC or WebSocket listener. NanoCL mounts a VM-specific directory
and bridges its authorized `/vms/{vm_key}/console` WebSocket to that socket after
checking the current VM, runtime identity and enabled console. See NanoCL's
`examples/vm-console` noVNC client and VM documentation for authorization and
browser usage. QEMU native WebSocket and websockify were rejected because either
would add a listener and an additional authorization boundary to the runtime.

For the standalone launcher, `CONSOLE=true` (or `1`) requires `CONSOLE_DIR` to
name an existing absolute directory with mode 0700, dedicated to this VM. The
path must not be a symlink or contain commas. The launcher bind-mounts it at
`/run/nanocl-console`; connect an authorized local console bridge to
`$CONSOLE_DIR/console.sock`. The launcher does not create a shared directory or
start a network listener. For example, create a new private directory per VM:

```sh
install -d -m 700 "$PWD/vm-console"
MAC=52:54:00:00:00:01 CONSOLE=true CONSOLE_DIR="$PWD/vm-console" \
  DISK="$PWD/server.img" ./start_vm.sh
```

QEMU and dnsmasq are supervised together. A DHCP/DNS process exit stops the guest;
a QEMU exit stops dnsmasq. TERM/INT stop and reap both children, with a bounded
fallback for an unresponsive process. Cleanup removes only owned firewall
chains/TAP/socket/seed and restores the container's original address/default
route. Docker deletion removes the dedicated network namespace. A new start
rebuilds the lease from Docker's current address and the persisted MAC; address
changes on recreation remain Docker/NanoCL's IP allocation policy.

Docker stop/restart terminates QEMU; it is a guest power cut, not an ACPI guest
shutdown. Shut down from inside the guest before a planned stop when filesystem
consistency matters. Newly provisioned files can still be in the guest's dirty
page cache after cloud-init reports completion. The restart test explicitly
runs guest `sync` and verifies unchanged SSH hostkeys across the restart; it
does not claim crash-safe guest application data.

## Reproducible validation

Run launcher and early runtime argument checks without Docker or KVM:

```sh
node --test tests/launcher.mjs
```

On Linux with Docker, KVM, Node.js, OpenSSH and `qemu-img`, supply an immutable
Ubuntu 24.04 minimal cloud image:

```sh
docker build -t nanocl-qemu:vm019-test .
docker build -f tests/Dockerfile.tools -t nanocl-qemu:vm019-tools .
node tests/integration.mjs /absolute/path/ubuntu-24.04-minimal-cloudimg-amd64.img
```

The suite creates only uniquely named containers and a dedicated `/24` Docker
network. `TEST_SUBNET` overrides `172.29.222.0/24` if it conflicts with local
networks. It uses qcow2 overlays in a temporary directory, leaves the source disk
read-only, and removes its containers/network in `finally`. Logs and overlays
are retained at the printed temporary path for inspection.
`guest-no-cloud-init.qcow2` is a flattened snapshot taken after clean shutdown,
with the cloud-init package removed and ordinary DHCP configuration. The suite
boots a writable copy of this snapshot for its no-cloud-init checks. This test
fixture matches MAC `52:54:00:19:00:01`; its `cloud` account uses the test key in
the same temporary directory. Use a writable copy for further tests.

Checks include shell syntax/lint, invalid MAC rejection, actual cloud-init/KVM
boot, same-IP/mask/MAC, exact gateway/helper route/MTU, guest UDP/TCP DNS and
outbound HTTP, SSH ingress, byte-preserved custom user-data with a custom SSH
user, `write_files`, `runcmd`, retained instance identity and managed DHCP, explicit
renewal with no uplink DHCP, two simultaneous VMs and guest-to-guest ingress,
private Unix VNC protocol, container restart after guest `sync`, DHCP-process
failure, and cleanup
of the TAP/owned rules while preserving Docker resolver rules. The
second VM exercises explicit upstream DNS (`TEST_DNS`, default `1.1.1.1`). It also
purges cloud-init from a disposable guest, saves plain DHCP configuration, powers
it off, and boots it with no seed before repeating network checks. NanoCL API
permissions and a real noVNC browser session require the separate NanoCL
integration tests; a Unix RFB greeting alone does not prove browser integration.
