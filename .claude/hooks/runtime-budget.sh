#!/bin/bash
# PreToolUse hook on Bash: refuses the few command shapes that break the
# project's runtime rules (CLAUDE.md, "Build: vx"; the runtime-budget
# skill). It is deliberately narrow; anything it doesn't recognise runs.
#
#  - retrying a check until it passes (ctest --repeat, until-pass loops):
#    a check that flakes is removed, not retried;
#  - a loop of five or more test, boot or bench runs: estimate one run
#    times the count first; over about 5 minutes, ask the owner;
#  - an explicit timeout over 30 minutes on a suite or bench;
#  - waiting with `pgrep -f`: the waiting shell's own command line
#    matches the pattern, so the wait never ends.
#
# A command the owner has agreed to carries a `# budget-ok: <reason>`
# comment and is let through.
input=$(cat)
if command -v jq >/dev/null 2>&1; then
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
else
  cmd=$input
fi
[[ -z $cmd ]] && exit 0
[[ $cmd == *"# budget-ok:"* ]] && exit 0

deny() {
  echo "runtime-budget: $1" >&2
  echo "If the owner has agreed to this run, add a '# budget-ok: <reason>' comment to the command." >&2
  exit 2
}

suite='(vx (test|ci|bench|boot)|ctest|swift test|hosttest\.sh|brimstone-run\.sh|board-run\.sh|mutat)'

if [[ $cmd =~ (until|while)[^\;]*pgrep\ +-f ]]; then
  deny "a wait on 'pgrep -f PATTERN' never ends, because this shell's own command line contains PATTERN. Wait on a pid (while kill -0 \$pid), on a log's last line, or run the command with run_in_background."
fi
if [[ $cmd =~ ctest[^\;\|]*--repeat || $cmd =~ --repeat-until-fail ]]; then
  deny "a check that flakes is removed, not retried (CLAUDE.md). Find the cause, or remove the check."
fi
retry='until +([^ ;]*/)?(vx (test|ci|bench|boot)|ctest|swift test|hosttest\.sh|brimstone-run\.sh|board-run\.sh)'
if [[ $cmd =~ $retry ]]; then
  deny "this retries a suite until it passes. A check that flakes is removed, not retried (CLAUDE.md)."
fi
# for i in $(seq N) / {1..N} / $(seq A B) around a suite, with N >= 5.
if [[ $cmd =~ for\ +[A-Za-z_]+\ +in\ +(\$\(seq\ +([0-9]+)(\ +([0-9]+))?\)|\{([0-9]+)\.\.([0-9]+)\}) ]]; then
  m=("${BASH_REMATCH[@]}")
  if [[ -n ${m[2]} ]]; then
    if [[ -n ${m[4]} ]]; then n=$((m[4] - m[2] + 1)); else n=${m[2]}; fi
  else
    n=$((m[6] - m[5] + 1))
  fi
  if ((n >= 5)) && [[ $cmd =~ $suite ]]; then
    deny "this runs a suite, boot or bench $n times. Estimate one run times $n before launching; if that is over about 5 minutes, shrink it or ask the owner (feedback: a five hour run has no benefit)."
  fi
fi
if [[ $cmd =~ $suite ]] && [[ $cmd =~ timeout\ +([0-9]+)([smh]?)\  ]]; then
  t=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in m) t=$((t * 60)) ;; h) t=$((t * 3600)) ;; esac
  if ((t > 1800)); then
    deny "a timeout of ${t}s on a suite or bench. No arch's run may take over 5 minutes, and a brimstone run of vx test --changed takes about 15; say why this one needs longer, or shrink it."
  fi
fi
exit 0
