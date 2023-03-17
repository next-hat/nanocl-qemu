#!/bin/bash

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

# Get host hostname
hostname=$(hostname)

# Get default interface
default_interface=$DEFAULT_INTERFACE

if [ -z "$default_interface" ]; then
    default_interface=$(ip route show | grep default | awk '{print $5}')
fi

gateway=$GATEWAY

# If gateway is not set, use the default gateway
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

# Change ip to local subnet of 10.x.0.x/16
newip=$(echo $ip | awk -F. '{print "10."$2".0."$4}')
newgateway=$(echo $gateway | awk -F. '{print "10."$2".0.1"}')
rangestart=$(echo $gateway | awk -F. '{print "10."$2".0.2"}')
rangeend=$(echo $gateway | awk -F. '{print "10."$2".0.254"}')

echo $newip
echo $newgateway

# Generate random id for the network
id=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)

echo $id

TAP=tap$id
BRIDGE=br$id

# Setup bridge
ip link add name $BRIDGE type bridge
# ip tuntap add mode tap $TAP
ip tuntap add dev $TAP mode tap user root
# # Remove ip from eth0 and add it to br$id
# ip addr flush dev eth0
# ip addr del $ip/1 dev eth0
ip link set dev $TAP master $BRIDGE
# ip link set dev $default_interface master $BRIDGE
ip addr add $newgateway/16 dev $BRIDGE
# # Up interfaces
ip link set $BRIDGE up
ip link set $TAP up
# Add new default route
# ip route add default via $gateway dev $BRIDGE

ssh_key=""

if [ ! -z "$SSH_KEY" ]; then
cat <<EOF > /tmp/ssh_key
  ssh_authorized_keys:
  - $SSH_KEY
EOF
ssh_key=`cat /tmp/ssh_key`
cat /tmp/ssh_key
fi

delete_ssh_key=$DELETE_SSH_KEY
if [ -z "$delete_ssh_key" ]; then
    delete_ssh_key="true"
fi

## Generate cloud-init config
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

from_network=$FROM_NETWORK
if [ -z "$from_network" ]; then
    from_network=ens3
fi

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
      dhcp4: true
      # addresses: [$newip/16]
      # routes:
      # - to: default
      #   via: $newgateway
      # - to: $newgateway/16
      #   via: $newgateway
      #   metric: 100
      nameservers:
          search: [Local]
          addresses: [8.8.8.8, 8.8.4.4]
EOF

# Generate seed
/usr/bin/cloud-localds /tmp/seed.img /tmp/user-data -N /tmp/network-config

# Get eth0 mac address
mac=$(ip link show eth0 | grep ether | awk '{print $2}')

cat <<EOF > /tmp/dnsmasq.conf
bind-interfaces
listen-address=$newgateway
server=8.8.8.8
server=8.8.4.4
dhcp-range=$rangestart,$rangeend,12M
dhcp-host=$mac,$newip
EOF

dnsmasq -d -C /tmp/dnsmasq.conf &

# Redirect all incomming traffic to $newip and vice versa
iptables -t nat -A PREROUTING -d $newip -j DNAT --to $ip
iptables -t nat -A PREROUTING -d $ip -j DNAT --to $newip
iptables -t nat -A POSTROUTING -s $ip -j SNAT --to $newip
iptables -t nat -A POSTROUTING -s $newip -j SNAT --to $ip

# Start quemu with tap$id
/usr/bin/qemu-system-x86_64 -device virtio-net-pci,netdev=net0,mq=on,vectors=6,mac=$mac -netdev tap,script=no,downscript=no,ifname=$TAP,id=net0 -cdrom /tmp/seed.img --nographic $@

# /usr/bin/qemu-system-x86_64 -net nic,model=virtio -net bridge,br=$BRIDGE -cdrom /tmp/seed.img -nographic $@

# Clean network
ip link set $TAP down
ip link del $TAP
ip link del $BRIDGE
