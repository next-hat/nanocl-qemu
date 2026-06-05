#!/bin/bash

# Get host hostname
hostname=$(hostname)

# Get default interface
default_interface=$DEFAULT_INTERFACE

if [ -z "$default_interface" ]; then
    default_interface=$(ip route show | grep default | awk '{print $5}')
fi

# If user is empty, use cloud
user=$USER
if [ -z "$user" ]; then
    user=cloud
fi

# If password is empty, use cloud
password=$PASSWORD
if [ -z "$password" ]; then
    password=cloud
fi

# If gateway is not set, use the gateway of eth0
if [ -z "$gateway" ]; then
    gateway=$(ip route show | grep default | awk '{print $3}')
    gateway=$(echo $gateway | awk -F. '{print $1"."$2"."$3"."$4}')
fi

# If ip is not set, use the ip of eth0
ip=$IP
if [ -z "$ip" ]; then
    ip=$(ip addr show $default_interface | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    ip=$(echo $ip | awk -F. '{print $1"."$2"."$3"."$4}')
fi

# If the mac is not set, generate a random one
mac=$MAC
if [ -z "$mac" ]; then
    mac=$(printf '52:54:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
fi

# Generate random ID for network interfaces
NET_ID=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
TAP=tap$NET_ID
BRIDGE=br$NET_ID
NET=net$NET_ID

# Create the tun device
mkdir -p /dev/net
mknod /dev/net/tun c 10 200

# Create the tap network with his bridge
ip tuntap add dev $TAP mode tap user root
ip link set $TAP up
ip link add name $BRIDGE type bridge
ip link set dev $TAP master $BRIDGE
ip link set dev $default_interface master $BRIDGE
ip link set $BRIDGE up

# Load ssh key if set
ssh_key=""
if [ ! -z "$SSH_KEY" ]; then
cat <<EOF > /tmp/ssh_key
  ssh_authorized_keys:
  - $SSH_KEY
EOF
ssh_key=`cat /tmp/ssh_key`
cat /tmp/ssh_key
fi

# Delete existing ssh key
delete_ssh_key=$DELETE_SSH_KEY
if [ -z "$delete_ssh_key" ]; then
    delete_ssh_key="true"
fi

# Generate cloud-init config
cat <<EOF > /tmp/user-data
#cloud-config

version: 2
hostname: $hostname
manage_etc_hosts: true
users:
- default
- name: $user
  primary_group: $user
  sudo: ALL=(ALL) NOPASSWD:ALL
  groups: users, admin, sudoers
  homedir: /home/$user
  shell: /bin/bash
  lock_passwd: false
$ssh_key

ssh_pwauth: true
disable_root: true
chpasswd:
  expire: false
  users:
    - name: $user
      password: $password
      type: text

ssh_deletekeys: $delete_ssh_key

runcmd:
  - netplan apply
  - sh -c "sleep 2 && cloud-init clean" &

final_message: "The system is finally up, after \$UPTIME seconds"
EOF

# If from_network is not set, use ens3
from_network=$FROM_NETWORK
if [ -z "$from_network" ]; then
    from_network=ens3
fi

# If to_network is not set, use eth0
to_network=$TO_NETWORK
if [ -z "$to_network" ]; then
    to_network=eth0
fi

# Generate network config
cat <<EOF > /tmp/network-config
#cloud-config

network:
  version: 2
  renderer: networkd
  ethernets:
    $from_network:
      match:
        name: $from_network
      set-name: $to_network
      dhcp4: no
      addresses: [$ip/16]
      routes:
      - to: default
        via: $gateway
      nameservers:
          search: [Local]
          addresses: [1.1.1.1, 1.0.0.1]
EOF

# Generate seed
/usr/bin/cloud-localds /tmp/seed.img /tmp/user-data -N /tmp/network-config

graphic_mode=false
if [ "$GRAPHIC" = "true" ] || [ "$GRAPHIC" = "1" ]; then
  graphic_mode=true
fi

spice_mode=false
if [ "$SPICE" = "true" ] || [ "$SPICE" = "1" ]; then
  spice_mode=true
fi

websockify_mode=false
if [ "$WEBSOCKIFY" = "true" ] || [ "$WEBSOCKIFY" = "1" ]; then
  websockify_mode=true
fi

qemu_args=("$@")
qemu_display_args=()
graphic_backend=${GRAPHIC_BACKEND:-auto}

if [ "$graphic_mode" = "true" ] && [ -n "$DISPLAY" ]; then
  available_displays=$(/usr/bin/qemu-system-x86_64 -display help 2>&1 || true)

  if [ "$graphic_backend" = "gtk" ]; then
    if echo "$available_displays" | grep -q '^gtk$'; then
      qemu_display_args+=("-display" "gtk")
    else
      echo "GRAPHIC_BACKEND=gtk was requested, but gtk is not available in the image" >&2
      exit 1
    fi
  elif [ "$graphic_backend" = "sdl" ]; then
    if echo "$available_displays" | grep -q '^sdl$'; then
      qemu_display_args+=("-display" "sdl")
    else
      echo "GRAPHIC_BACKEND=sdl was requested, but sdl is not available in the image" >&2
      exit 1
    fi
  elif [ "$graphic_backend" = "auto" ]; then
    if echo "$available_displays" | grep -q '^gtk$'; then
      qemu_display_args+=("-display" "gtk")
    elif echo "$available_displays" | grep -q '^sdl$'; then
      qemu_display_args+=("-display" "sdl")
    else
      echo "GRAPHIC=true was requested, but no graphical QEMU display backend is available in the image" >&2
      exit 1
    fi
  else
    echo "GRAPHIC_BACKEND must be one of: auto, gtk, sdl" >&2
    exit 1
  fi
elif [ "$graphic_mode" = "true" ]; then
  echo "GRAPHIC=true requires DISPLAY to be set in the container environment" >&2
  exit 1
elif [ "$spice_mode" = "true" ] || [ "$websockify_mode" = "true" ]; then
  qemu_display_args+=("-display" "none")
fi

if [ "$spice_mode" = "true" ]; then
  qemu_display_args+=("-spice" "port=${SPICE_PORT:-5930},disable-ticketing=on,addr=127.0.0.1")
fi

websockify_pid=""
if [ "$websockify_mode" = "true" ]; then
  if ! command -v websockify >/dev/null 2>&1; then
    echo "websockify is not installed in the image" >&2
    exit 1
  fi

  vnc_display=${VNC_DISPLAY:-0}
  vnc_port=$((5900 + vnc_display))

  qemu_display_args+=("-vnc" "127.0.0.1:${VNC_DISPLAY:-0}")
  websockify "${WEBSOCKIFY_PORT:-6080}" "127.0.0.1:${vnc_port}" &
  websockify_pid=$!
fi

if [ "$graphic_mode" = "false" ] && [ "$spice_mode" = "false" ] && [ "$websockify_mode" = "false" ]; then
  qemu_display_args+=("-nographic")
fi

# Start quemu with $TAP
cleanup() {
  if [ -n "$websockify_pid" ]; then
    kill "$websockify_pid" >/dev/null 2>&1 || true
  fi

  ip link set "$TAP" down >/dev/null 2>&1 || true
  ip link del "$TAP" >/dev/null 2>&1 || true
  ip link del "$BRIDGE" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

/usr/bin/qemu-system-x86_64 -netdev tap,id=$NET,ifname=$TAP,script=no -device virtio-net-pci,netdev=$NET,mac=$mac -cdrom /tmp/seed.img "${qemu_display_args[@]}" "${qemu_args[@]}"

# Clean networks
cleanup
