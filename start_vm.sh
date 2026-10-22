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
for key in PASSWORD SSH_KEY INSTANCE_ID DNS DELETE_SSH_KEY; do
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
