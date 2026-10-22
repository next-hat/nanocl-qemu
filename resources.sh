#!/bin/bash
# Sourced runtime code. Resource data is parsed as JSON, never as shell code.
load_managed_resources() {
  local path=$1 directory=${1%/*} document values cpu memory max_cpu max_memory LC_ALL=C
  [[ ! -L $directory && -d $directory && $(stat -c '%a' "$directory") == 700 ]] || fail 'managed VM directory must be a private, non-symlink directory (0700)'
  [[ ! -L $path && -f $path && $(stat -c '%a' "$path") == 600 ]] || fail 'resources.json must be a private, non-symlink regular file (0600)'
  # Bound the read itself, including if an operator changes the file in place.
  if IFS= read -r -d '' -n 4097 document <"$path"; then
    fail 'resources.json must not contain NUL or exceed 4096 bytes'
  fi
  # Streaming paths also reject duplicate keys, which a normal JSON object
  # parser would silently overwrite. Exactly one object/document is required.
  jq -e --stream -s '[.[] | select(length == 2) | .[0]] | sort == [["Cpu"],["MaxCpu"],["MaxMemory"],["Memory"]]' <<<"$document" >/dev/null 2>&1 || fail 'resources.json must contain exactly Cpu, Memory, MaxCpu and MaxMemory'
  values=$(jq -e -r -s '
    def positive_integer: type == "number" and . > 0 and . == floor;
    if length == 1 and (.[0] | type == "object") then .[0] else error("expected one object") end
    | select(keys == ["Cpu","MaxCpu","MaxMemory","Memory"])
    | select(all(.[]; positive_integer))
    | select(.Cpu <= .MaxCpu and .MaxCpu <= 255 and .Memory <= .MaxMemory and .MaxMemory <= 8796093022207)
    | [.Cpu,.Memory,.MaxCpu,.MaxMemory] | @tsv
  ' <<<"$document" 2>/dev/null) || fail 'resources.json contains invalid resource limits'
  IFS=$'\t' read -r cpu memory max_cpu max_memory <<<"$values"
  qemu_resources=(-smp "cpus=$cpu,maxcpus=$max_cpu,sockets=1,cores=$max_cpu,threads=1")
  # QEMU rejects slots/maxmem when maximum RAM equals the initial allocation.
  if ((max_memory > memory)); then
    qemu_resources+=(-m "${memory}M,slots=32,maxmem=${max_memory}M")
  else
    qemu_resources+=(-m "${memory}M")
  fi
}
