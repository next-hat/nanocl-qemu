#!/bin/bash
set -euo pipefail
: "${MAC:?Set a stable guest MAC, for example 52:54:00:00:00:01}"
: "${DISK:=$PWD/server.img}"
args=(run -it --rm --network "${NETWORK:-bridge}" --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1)
for scope in all default; do
  for setting in proxy_arp=1 arp_ignore=1 send_redirects=0 rp_filter=0 accept_local=1; do
    args+=(--sysctl "net.ipv4.conf.$scope.$setting")
  done
done
args+=(-e "MAC=$MAC" -e NANOCL_NETWORK_MODE=bridge -e "CLOUD_INIT=${CLOUD_INIT:-true}" -e "CONSOLE=${CONSOLE:-false}")
for key in USER PASSWORD SSH_KEY INSTANCE_ID DNS DELETE_SSH_KEY; do
  [[ -z ${!key:-} ]] || args+=(-e "$key=${!key}")
done
if [[ ${CONSOLE:-false} == true || ${CONSOLE:-false} == 1 ]]; then
  : "${CONSOLE_DIR:?Set an existing private VM-specific console directory}"
  if [[ $CONSOLE_DIR != /* || $CONSOLE_DIR == *,* || ! -d $CONSOLE_DIR || -L $CONSOLE_DIR ]] || [[ $(stat -c %a "$CONSOLE_DIR") != 700 ]]; then
    echo 'CONSOLE_DIR must be an existing absolute directory with mode 0700, without commas or a symlink' >&2
    exit 1
  fi
  args+=(--mount "type=bind,source=$CONSOLE_DIR,target=/run/nanocl-console")
fi
args+=(-v "$DISK:/img/server.img" "${IMAGE:-nanocl-qemu:vm019-test}")
if (($#)); then args+=("$@"); else args+=(-accel kvm -m 2G -smp 2 -drive "file=/img/server.img,if=virtio,format=qcow2"); fi
exec docker "${args[@]}"
