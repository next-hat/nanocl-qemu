#!/bin/bash
# One QEMU guest and one DHCP/DNS service in a dedicated Docker bridge netns.
set -Eeuo pipefail
umask 077

fail() { echo "nanocl-qemu: $*" >&2; exit 1; }
boolean() {
  case "$2" in true|1) printf true;; false|0) printf false;; *) fail "$1 must be true or false";; esac
}
ipv4_number() {
  local a b c d extra
  IFS=. read -r a b c d extra <<<"$1"
  [[ -z "$extra" && "$a.$b.$c.$d" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || return 1
  done
  printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}
# YAML single quotes protect passwords/keys from YAML syntax and interpolation.
yaml_string() { local value=${1//\'/\'\'}; printf "'%s'" "$value"; }

cloud_init=$(boolean CLOUD_INIT "${CLOUD_INIT:-true}")
# Presence is intentional: an empty document also replaces generated defaults.
custom_user_data=false
if [[ $cloud_init == true && ${CLOUD_INIT_USER_DATA+x} ]]; then
  custom_user_data=true
  # Environment strings cannot contain NUL. Count bytes, not locale characters.
  user_data_bytes=$(LC_ALL=C printf '%s' "$CLOUD_INIT_USER_DATA" | wc -c)
  ((user_data_bytes <= 65536)) || fail 'CLOUD_INIT_USER_DATA must not exceed 65536 bytes'
fi
console=$(boolean CONSOLE "${CONSOLE:-false}")
graphic=$(boolean GRAPHIC "${GRAPHIC:-false}")
[[ $(boolean WEBSOCKIFY "${WEBSOCKIFY:-false}") == false ]] || fail 'WEBSOCKIFY was removed; use the authorized NanoCL console with CONSOLE=true'
[[ $(boolean SPICE "${SPICE:-false}") == false ]] || fail 'SPICE is not supported; use CONSOLE=true'
[[ $console != true || $graphic != true ]] || fail 'CONSOLE and GRAPHIC are mutually exclusive'
mac=${MAC:-}
mac=${mac,,}
[[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || fail 'MAC is required and must be a stable unicast address'
(( (16#${mac:0:2} & 1) == 0 )) || fail 'MAC must be a unicast address'
[[ $mac != 00:00:00:00:00:00 ]] || fail 'MAC must be a nonzero unicast address'
# The runtime owns network/display/monitor/process lifetime options. Other QEMU options
# (disks, CPU, memory, acceleration) remain operator-controlled.
for arg in "$@"; do
  case "$arg" in
    -nographic|--nographic|-vnc|--vnc|-display|--display|-spice|--spice|-net|--net|-netdev|--netdev|-nic|--nic|-daemonize|--daemonize|-no-shutdown|--no-shutdown|-action|--action|-serial|--serial|-monitor|--monitor|-mon|--mon|-qmp|--qmp|-qmp-pretty|--qmp-pretty|-readconfig|--readconfig|-pidfile|--pidfile)
      fail "$arg conflicts with runtime-managed networking, display, monitor or supervision";;
  esac
 done
[[ ${NANOCL_NETWORK_MODE:-} == bridge ]] || fail 'NANOCL_NETWORK_MODE=bridge requires a dedicated Docker bridge network namespace'
[[ -f /.dockerenv && $$ == 1 ]] || fail 'run the runtime as container PID 1 in a dedicated Docker namespace'

mapfile -t defaults < <(ip -4 route show default)
((${#defaults[@]} == 1)) || fail 'exactly one IPv4 default route is required'
read -r -a original_default <<<"${defaults[0]}"
[[ ${original_default[0]} == default && ${original_default[1]} == via && ${original_default[3]} == dev ]] || fail 'unsupported default route'
gateway=${original_default[2]}
uplink=${original_default[4]}
[[ -z ${DEFAULT_INTERFACE:-} || $DEFAULT_INTERFACE == "$uplink" ]] || fail 'DEFAULT_INTERFACE must be the default-route interface'
[[ $uplink =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'unsupported interface name'
[[ $(cat "/sys/class/net/$uplink/type") == 1 && $(cat "/sys/class/net/$uplink/iflink") != "$(cat "/sys/class/net/$uplink/ifindex")" ]] || fail 'the uplink must be a Docker veth'
mapfile -t addresses < <(ip -4 -o addr show scope global)
((${#addresses[@]} == 1)) || fail 'exactly one global IPv4 address is required'
read -r _ address_dev _ cidr _ <<<"${addresses[0]}"
[[ $address_dev == "$uplink" ]] || fail 'the IPv4 address must belong to the uplink'
[[ -z $(ip -6 -o addr show scope global) ]] || fail 'IPv6 networks are not supported'
mapfile -t links < <(ip -o link show | awk -F': ' '$2 != "lo" {print $2}')
((${#links[@]} == 1)) || fail 'multiple network interfaces or shared namespaces are not supported'
guest_ip=${cidr%/*}
prefix=${cidr#*/}
[[ $prefix =~ ^[0-9]+$ ]] || fail 'invalid IPv4 prefix'
((prefix >= 1 && prefix <= 30)) || fail 'unsupported IPv4 prefix'
[[ -z ${IP:-} || $IP == "$guest_ip" ]] || fail 'IP must equal the Docker-assigned address'
guest_number=$(ipv4_number "$guest_ip") || fail 'invalid Docker IPv4 address'
gateway_number=$(ipv4_number "$gateway") || fail 'invalid Docker gateway'
mask_number=$(( (0xffffffff << (32-prefix)) & 0xffffffff ))
network_number=$((guest_number & mask_number))
(( (gateway_number & mask_number) == network_number )) || fail 'gateway must be in the Docker subnet'
helper=169.254.254.1
(( ($(ipv4_number "$helper") & mask_number) != network_number )) || fail 'Docker subnet overlaps the private DHCP helper'
mask="$((mask_number >> 24 & 255)).$((mask_number >> 16 & 255)).$((mask_number >> 8 & 255)).$((mask_number & 255))"
subnet="$((network_number >> 24 & 255)).$((network_number >> 16 & 255)).$((network_number >> 8 & 255)).$((network_number & 255))/$prefix"
mapfile -t routes < <(ip -4 route show)
((${#routes[@]} == 2)) || fail 'additional routes are unsupported'
mtu=$(cat "/sys/class/net/$uplink/mtu")
# Docker applies these before startup because /proc/sys is read-only. all and
# default are required so the new TAP inherits the same namespace-local policy.
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || fail 'Docker sysctl net.ipv4.ip_forward=1 is required'
for scope in all default "$uplink"; do
  for setting in proxy_arp=1 arp_ignore=1 send_redirects=0 rp_filter=0 accept_local=1; do
    key=${setting%=*}; expected=${setting#*=}
    [[ $(sysctl -n "net.ipv4.conf.$scope.$key") == "$expected" ]] || fail "Docker sysctl net.ipv4.conf.$scope.$key=$expected is required"
  done
 done
servers=()
if [[ -n ${DNS:-} ]]; then
  IFS=, read -r -a servers <<<"$DNS"
  for server in "${servers[@]}"; do
    ipv4_number "$server" >/dev/null || fail 'DNS must be a comma-separated IPv4 list'
    [[ $server != "$helper" && $server != "$guest_ip" ]] || fail 'DNS must not point back to the guest or private helper'
  done
  [[ $DNS != *, ]] || fail 'DNS cannot contain empty entries'
fi
if [[ $cloud_init == true ]]; then
  for value in "${INSTANCE_ID:-$mac}" "$(hostname)"; do
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || fail 'provisioning values must be single-line strings'
  done
  if [[ $custom_user_data == false ]]; then
    delete_keys=$(boolean DELETE_SSH_KEY "${DELETE_SSH_KEY:-true}")
    for value in "${USER:-cloud}" "${PASSWORD:-cloud}" "${SSH_KEY:-}"; do
      [[ $value != *$'\n'* && $value != *$'\r'* ]] || fail 'provisioning values must be single-line strings'
    done
    [[ ${USER:-cloud} =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'USER must be a valid Linux account name'
  fi
fi

state=/run/nanocl-runtime
tap=nanocl-tap
vm_dir=/run/nanocl-vm
qmp_socket=$vm_dir/qmp.sock
console_socket=$vm_dir/console.sock
qemu_pid='' dnsmasq_pid='' shutdown_pid=''
network_owned=false
firewall_owned=false
console_owned=false
qmp_owned=false
# ShellCheck 0.9 does not follow the EXIT trap invocation.
# shellcheck disable=SC2317
cleanup() {
  local result=$?
  trap - EXIT TERM INT
  # TERM is an explicit forced stop. NanoCL requests graceful shutdown over QMP.
  # Stop both children and reap them; bound an unresponsive process's cleanup.
  for pid in "$qemu_pid" "$dnsmasq_pid"; do [[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || true; done
  if [[ -n $qemu_pid || -n $dnsmasq_pid ]]; then
    (sleep 8; for pid in "$qemu_pid" "$dnsmasq_pid"; do [[ -z $pid ]] || kill -KILL "$pid" 2>/dev/null || true; done) &
    shutdown_pid=$!
    for pid in "$qemu_pid" "$dnsmasq_pid"; do [[ -z $pid ]] || wait "$pid" 2>/dev/null || true; done
    kill "$shutdown_pid" 2>/dev/null || true
    wait "$shutdown_pid" 2>/dev/null || true
  fi
  if [[ $firewall_owned == true ]]; then
    iptables -D FORWARD -j NANOCL_VM_FORWARD 2>/dev/null || true
    iptables -F NANOCL_VM_FORWARD 2>/dev/null || true
    iptables -X NANOCL_VM_FORWARD 2>/dev/null || true
    iptables -D INPUT -j NANOCL_VM_INPUT 2>/dev/null || true
    iptables -F NANOCL_VM_INPUT 2>/dev/null || true
    iptables -X NANOCL_VM_INPUT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j NANOCL_VM_DNS 2>/dev/null || true
    iptables -t nat -F NANOCL_VM_DNS 2>/dev/null || true
    iptables -t nat -X NANOCL_VM_DNS 2>/dev/null || true
  fi
  if [[ $network_owned == true ]]; then
    ip link del "$tap" 2>/dev/null || true
    ip addr replace "$cidr" dev "$uplink" 2>/dev/null || true
    ip route replace "${original_default[@]}" 2>/dev/null || true
  fi
  if [[ $console_owned == true && ! -L $console_socket && -S $console_socket ]]; then rm -f "$console_socket"; fi
  if [[ $qmp_owned == true && ! -L $qmp_socket && -S $qmp_socket ]]; then rm -f "$qmp_socket"; fi
  rm -f "$state/seed.img" "$state/user-data" "$state/meta-data" "$state/network-config" "$state/dnsmasq.conf" "$state/leases"
  exit "$result"
}
[[ ! -L $state ]] || fail 'runtime state directory must not be a symlink'
mkdir -p "$state"
chmod 700 "$state"
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
[[ ! -e $state/seed.img ]] || rm -f "$state/seed.img"
[[ ! -L $vm_dir && ! -L $qmp_socket ]] || fail 'VM control path must not be a symlink'
mkdir -p "$vm_dir"
chmod 700 "$vm_dir"
[[ ! -e $qmp_socket || -S $qmp_socket ]] || fail 'QMP path is not a socket'
rm -f "$qmp_socket"
qmp_owned=true
# Keep Ctrl-C as a guest byte without restoring the HMP monitor multiplexer.
qemu_serial=(-chardev "stdio,id=nanocl-serial,signal=off" -serial chardev:nanocl-serial)
qemu_display=(-display none)
if [[ $graphic == true ]]; then
  [[ -n ${DISPLAY:-} ]] || fail 'GRAPHIC=true requires DISPLAY'
  backend=${GRAPHIC_BACKEND:-auto}
  available=$(/usr/bin/qemu-system-x86_64 -display help 2>&1)
  if [[ $backend == auto ]]; then
    if grep -qx gtk <<<"$available"; then backend=gtk; else backend=sdl; fi
  fi
  [[ $backend == gtk || $backend == sdl ]] || fail 'unknown graphics backend'
  grep -qx "$backend" <<<"$available" || fail 'requested graphics backend is unavailable'
  qemu_display=(-display "$backend")
fi
if [[ $console == true ]]; then
  [[ ! -L $console_socket ]] || fail 'console path must not be a symlink'
  [[ ! -e $console_socket || -S $console_socket ]] || fail 'console path is not a socket'
  rm -f "$console_socket"
  console_owned=true
  qemu_display+=(-vnc "unix:$console_socket")
fi
seed_args=()
if [[ $cloud_init == true ]]; then
  if [[ $custom_user_data == true ]]; then
    printf '%s' "$CLOUD_INIT_USER_DATA" >"$state/user-data"
  else
    user=${USER:-cloud}
    {
      printf '#cloud-config\nhostname: '; yaml_string "$(hostname)"
      printf '\nmanage_etc_hosts: true\nusers:\n  - default\n  - name: '; yaml_string "$user"
      printf '\n    sudo: "ALL=(ALL) NOPASSWD:ALL"\n    groups: [users, sudo]\n    shell: /bin/bash\n    lock_passwd: false\n'
      if [[ -n ${SSH_KEY:-} ]]; then printf '    ssh_authorized_keys:\n      - '; yaml_string "$SSH_KEY"; printf '\n'; fi
      printf 'ssh_pwauth: true\ndisable_root: true\nchpasswd:\n  expire: false\n  users:\n    - name: '; yaml_string "$user"
      printf '\n      password: '; yaml_string "${PASSWORD:-cloud}"
      printf '\n      type: text\nssh_deletekeys: %s\n' "$delete_keys"
    } >"$state/user-data"
  fi
  { printf 'instance-id: '; yaml_string "${INSTANCE_ID:-$mac}"; printf '\n'; } >"$state/meta-data"
  cat >"$state/network-config" <<NETWORK
version: 2
ethernets:
  nanocl:
    match:
      macaddress: "$mac"
    set-name: nanocl0
    dhcp4: true
    dhcp6: false
    accept-ra: false
    link-local: []
NETWORK
  /usr/bin/cloud-localds -N "$state/network-config" "$state/seed.img" "$state/user-data" "$state/meta-data"
  seed_args=(-cdrom "$state/seed.img")
fi

[[ -c /dev/net/tun ]] || fail '/dev/net/tun must be passed as a Docker device'
for chain in NANOCL_VM_FORWARD NANOCL_VM_INPUT; do
  if iptables -S "$chain" >/dev/null 2>&1; then fail "firewall chain $chain already exists"; fi
done
if iptables -t nat -S NANOCL_VM_DNS >/dev/null 2>&1; then fail 'DNS firewall chain already exists'; fi
ip tuntap add dev "$tap" mode tap
network_owned=true
ip link set "$tap" mtu "$mtu" up
ip addr add "$helper/32" dev "$tap"
# No address is shared by container and guest. Docker keeps its endpoint/MAC;
# proxy ARP and routing move all guest packets across the private TAP unchanged.
ip addr del "$cidr" dev "$uplink"
ip route replace "$subnet" dev "$uplink" scope link
ip route replace default via "$gateway" dev "$uplink" onlink
ip route replace "$guest_ip/32" dev "$tap"
firewall_owned=true
iptables -N NANOCL_VM_FORWARD
iptables -A NANOCL_VM_FORWARD -p udp --dport 67:68 -j DROP
iptables -A NANOCL_VM_FORWARD -i "$tap" ! -s "$guest_ip/32" -j DROP
iptables -A NANOCL_VM_FORWARD -o "$tap" ! -d "$guest_ip/32" -j DROP
iptables -I FORWARD -j NANOCL_VM_FORWARD
iptables -N NANOCL_VM_INPUT
iptables -A NANOCL_VM_INPUT -i "$uplink" -d "$helper" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A NANOCL_VM_INPUT -i "$uplink" -d "$helper" -j DROP
iptables -A NANOCL_VM_INPUT -i "$uplink" -p udp --dport 67:68 -j DROP
iptables -I INPUT -j NANOCL_VM_INPUT
# Only runtime DNS queries need source translation. Guest traffic is never NATed.
# Existing Docker resolver rules are preserved.
iptables -t nat -N NANOCL_VM_DNS
for protocol in udp tcp; do
  iptables -t nat -A NANOCL_VM_DNS -s "$helper/32" -o "$uplink" -p "$protocol" --dport 53 -j SNAT --to-source "$guest_ip"
done
iptables -t nat -A POSTROUTING -j NANOCL_VM_DNS
cat >"$state/dnsmasq.conf" <<DNSMASQ
interface=$tap
except-interface=lo
bind-interfaces
listen-address=$helper
no-hosts
log-facility=-
log-dhcp
dhcp-authoritative
shared-network=$helper,$guest_ip
dhcp-range=$guest_ip,static,$mask,1h
dhcp-host=$mac,id:*,$guest_ip
dhcp-ignore=tag:!known
dhcp-option=option:router,$gateway
dhcp-option=option:dns-server,$helper
dhcp-option=option:mtu,$mtu
dhcp-option=option:classless-static-route,$helper/32,0.0.0.0,0.0.0.0/0,$gateway
dhcp-leasefile=$state/leases
DNSMASQ
if ((${#servers[@]})); then
  printf 'no-resolv\n' >>"$state/dnsmasq.conf"
  for server in "${servers[@]}"; do printf 'server=%s\n' "$server" >>"$state/dnsmasq.conf"; done
fi
dnsmasq --test --conf-file="$state/dnsmasq.conf"
dnsmasq --keep-in-foreground --conf-file="$state/dnsmasq.conf" &
dnsmasq_pid=$!
/usr/bin/qemu-system-x86_64 \
  -monitor none -qmp "unix:$qmp_socket,server=on,wait=off" \
  -netdev "tap,id=nanocl,ifname=$tap,script=no,downscript=no" \
  -device "virtio-net-pci,netdev=nanocl,mac=$mac" \
  "${seed_args[@]}" "${qemu_serial[@]}" "${qemu_display[@]}" "$@" <&0 &
qemu_pid=$!
set +e
wait -n -p exited_pid "$qemu_pid" "$dnsmasq_pid"
result=$?
set -e
if [[ $exited_pid == "$dnsmasq_pid" ]]; then
  echo 'nanocl-qemu: DHCP/DNS service exited; stopping the guest' >&2
  exit 1
fi
exit "$result"
