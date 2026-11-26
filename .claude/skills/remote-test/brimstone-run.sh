#!/bin/bash
# brimstone-run.sh BRANCH [COMMAND...]
#
# Runs COMMAND (default: .build/debug/vx test --changed amd64 arm64) on
# brimstone with BRANCH checked out, in whichever of two slots is free:
#   slot 1: ~/Projects/OS/VectraOS    lock ~/vx-brimstone.lock
#   slot 2: ~/Projects/OS/VectraOS-2  lock ~/vx-brimstone-2.lock
#           (a worktree sharing slot 1's .cache)
# brimstone has one repository: never touch a slot without its lock.
#
# A lock is a directory holding an `owner` file (host, pid, start time,
# branch). A lock whose owner is a dead process on this host is stale and
# is broken. A slot whose checkout is gone is skipped (slot 2 has been
# removed for space before). Any other held lock is waited on, for
# BRIM_WAIT_MIN minutes at most (default 60).
#
# COMMAND runs inside single quotes on the far side: it must not contain
# a single quote. Put anything longer in a script, scp it over and run it.
#
# The command runs under `zsh -lic`: over a plain ssh, swift is not on
# PATH and a stale .build/debug/vx runs instead. After the run the arch
# test logs are copied to build/vx/brimstone/, the slot goes back to
# main and the lock is released.
#
# The last line is always `BRIM EXIT <status>`: the command's exit code,
# or one of push-failed, no-slot, no-workspace, low-disk.
set -u
b=${1:?usage: brimstone-run.sh BRANCH [COMMAND...]}
shift
cmd=${*:-".build/debug/vx test --changed amd64 arm64"}

# The bare name `brimstone` may not resolve; mDNS does, with brimstone's
# own host key.
H=${BRIM_HOST:-brimstone.local}
ssh_=(ssh -o HostKeyAlias=brimstone -o BatchMode=yes -o ConnectTimeout=10 "$H")
export GIT_SSH_COMMAND="ssh -o HostKeyAlias=brimstone -o BatchMode=yes"
wait_min=${BRIM_WAIT_MIN:-60}
me="$(hostname -s) $$ $(date -u +%FT%TZ) $b"
status=unknown
dir= lock=

done_() { echo "BRIM EXIT $status"; }
trap done_ EXIT

git push -q -f "$H:Projects/OS/VectraOS" "$b" || { status=push-failed; exit 2; }

# Take a slot.
take() { # DIR LOCK -> 0 if taken; a slot whose checkout is gone is skipped
  "${ssh_[@]}" "test -e ~/Projects/OS/$1/.git && mkdir ~/$2 2>/dev/null && echo '$me' > ~/$2/owner"
}
stale() { # LOCK -> 0 if its owner is a dead process on this host
  local o host pid
  o=$("${ssh_[@]}" "cat ~/$1/owner 2>/dev/null || cat ~/$1 2>/dev/null")
  read -r host pid _ <<<"$o"
  [[ $host == "$(hostname -s)" && $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null
}
if ! "${ssh_[@]}" "test -e ~/Projects/OS/VectraOS/.git || test -e ~/Projects/OS/VectraOS-2/.git"; then
  echo "brimstone-run: neither slot's checkout exists on brimstone"
  status=no-workspace
  exit 4
fi
deadline=$((SECONDS + wait_min * 60))
while :; do
  if take VectraOS vx-brimstone.lock; then dir=VectraOS; lock=vx-brimstone.lock; break; fi
  if take VectraOS-2 vx-brimstone-2.lock; then dir=VectraOS-2; lock=vx-brimstone-2.lock; break; fi
  for l in vx-brimstone.lock vx-brimstone-2.lock; do
    if stale "$l"; then
      echo "brimstone-run: breaking stale lock $l: $("${ssh_[@]}" "cat ~/$l/owner 2>/dev/null")"
      "${ssh_[@]}" "rm -rf ~/$l"
    fi
  done
  if ((SECONDS >= deadline)); then
    echo "brimstone-run: both slots held for ${wait_min} min:"
    "${ssh_[@]}" 'for l in ~/vx-brimstone.lock ~/vx-brimstone-2.lock; do echo "  $l: $(cat $l/owner 2>/dev/null || cat $l 2>/dev/null)"; done'
    status=no-slot
    exit 3
  fi
  sleep 60
done
echo "brimstone-run: $b in slot $dir"

# Slot 1 holds the branch main; slot 2 is a worktree, so it detaches.
if [[ $dir == VectraOS ]]; then back="git checkout -q main"; else back="git checkout -q --detach main"; fi
release() {
  mkdir -p build/vx/brimstone
  scp -q -o HostKeyAlias=brimstone -o BatchMode=yes \
    "$H:Projects/OS/$dir/build/vx/*-test.log" build/vx/brimstone/ 2>/dev/null
  "${ssh_[@]}" "cd ~/Projects/OS/$dir && $back; rm -rf ~/$lock"
  done_
}
trap release EXIT

free_gb=$("${ssh_[@]}" "df -Pk ~/Projects/OS/$dir | awk 'NR==2 {print int(\$4/1048576)}'")
if [[ $free_gb =~ ^[0-9]+$ ]] && ((free_gb < ${BRIM_MIN_FREE_GB:-20})); then
  echo "brimstone-run: only ${free_gb} GB free on brimstone"
  status=low-disk
  exit 5
fi

"${ssh_[@]}" "zsh -lic 'cd ~/Projects/OS/$dir && git checkout -q --detach $b && swift build --product vx 2>&1 | tail -1 && $cmd'" 2>&1 | grep -v zle
status=${PIPESTATUS[0]}
exit "$status"
