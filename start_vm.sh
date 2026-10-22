#!/bin/bash
set -euo pipefail
: "${MAC:?Set a stable guest MAC, for example 52:54:00:00:00:01}"
: "${DISK:=$PWD/server.img}"
: "${VM_DIR:?Set an existing private VM-specific directory for QMP and optional console sockets}"
if [[ $VM_DIR != /* || $VM_DIR == *,* || ! -d $VM_DIR || -L $VM_DIR ]] || [[ $(stat -c %a "$VM_DIR") != 700 ]]; then
  echo 'VM_DIR must be an existing absolute directory with mode 0700, without commas or a symlink' >&2
  exit 1
fi
endpoint_sysctls='net.ipv4.conf.IFNAME.proxy_arp=1,net.ipv4.conf.IFNAME.arp_ignore=1,net.ipv4.conf.IFNAME.send_redirects=0,net.ipv4.conf.IFNAME.rp_filter=0,net.ipv4.conf.IFNAME.accept_local=1'
# Docker's extended network syntax normalizes names; use its immutable ID so
# an existing mixed-case network name continues to select the same network.
network_id=$(docker network inspect --format '{{.Id}}' "${NETWORK:-bridge}")
args=(run -it --rm --network "name=$network_id,\"driver-opt=com.docker.network.endpoint.sysctls=$endpoint_sysctls\"" --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1)
args+=(--mount "type=bind,source=$VM_DIR,target=/run/nanocl-vm")
for scope in all default; do
  for setting in proxy_arp=1 arp_ignore=1 send_redirects=0 rp_filter=0 accept_local=1; do
    args+=(--sysctl "net.ipv4.conf.$scope.$setting")
  done
done
args+=(-e "MAC=$MAC" -e NANOCL_NETWORK_MODE=bridge -e "CLOUD_INIT=${CLOUD_INIT:-true}" -e "CONSOLE=${CONSOLE:-false}" -e "USER=${GUEST_USER:-cloud}")
if [[ ${CLOUD_INIT:-true} == true || ${CLOUD_INIT:-true} == 1 ]]; then
  if [[ ${CLOUD_INIT_USER_DATA_FILE+x} ]]; then
    if [[ ${CLOUD_INIT_USER_DATA+x} || ! -f $CLOUD_INIT_USER_DATA_FILE || ! -r $CLOUD_INIT_USER_DATA_FILE ]]; then
      echo 'CLOUD_INIT_USER_DATA_FILE must be a readable regular file and cannot accompany CLOUD_INIT_USER_DATA' >&2
      exit 1
    fi
    if (($(wc -c <"$CLOUD_INIT_USER_DATA_FILE") > 65536)); then
      echo 'CLOUD_INIT_USER_DATA_FILE must not exceed 65536 bytes' >&2
      exit 1
    fi
    # EOF preserves trailing newlines; a successful NUL-delimited read rejects NUL.
    if IFS= read -r -d '' CLOUD_INIT_USER_DATA <"$CLOUD_INIT_USER_DATA_FILE"; then
      echo 'CLOUD_INIT_USER_DATA_FILE must not contain NUL bytes' >&2
      exit 1
    fi
  fi
  if [[ ${CLOUD_INIT_USER_DATA+x} ]]; then
    if (($(LC_ALL=C printf '%s' "$CLOUD_INIT_USER_DATA" | wc -c) > 65536)); then
      echo 'CLOUD_INIT_USER_DATA must not exceed 65536 bytes' >&2
      exit 1
    fi
    export CLOUD_INIT_USER_DATA
    args+=(-e CLOUD_INIT_USER_DATA)
  fi
fi
for key in PASSWORD SSH_KEY INSTANCE_ID DNS DELETE_SSH_KEY NANOCL_MANAGED_RESOURCES FROM_NETWORK DEFAULT_INTERFACE; do
  [[ -z ${!key:-} ]] || args+=(-e "$key=${!key}")
done
args+=(-v "$DISK:/img/server.img" "${IMAGE:-nanocl-qemu:vm019-test}")
if (($#)); then
  args+=("$@")
else
  args+=(-accel kvm)
  if [[ ${NANOCL_MANAGED_RESOURCES:-false} != true && ${NANOCL_MANAGED_RESOURCES:-false} != 1 ]]; then args+=(-m 2G -smp 2); fi
  args+=(-drive "file=/img/server.img,if=virtio,format=qcow2")
fi
exec docker "${args[@]}"
