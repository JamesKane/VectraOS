#!/bin/bash
# PreToolUse hook on Read, Grep, Glob and Bash: the clean-room rule.
# Work in this tree is clean-room work: nothing here may be read from the
# GPL sources the chinese-wall specs were written from. This refuses any
# tool call that names
#   ../linux*, ../mesa, ../drm-* (or the same under Projects/OS/),
#   chinese-wall/provenance (the dirty room's audit trail),
#   a .c or .h file in a session scratchpad (third-party source has been
#   found there before).
# The dirty-room agents (dirty-room-answerer, dirty-room-reviewer) are
# let through: they are the only readers of those sources. The agent's
# type comes from the hook input's agent_type; a harness that doesn't
# send it gets the refusal, so dirty-room work then runs from a session
# opened in chinese-wall, not here.
input=$(cat)
agent=
if command -v jq >/dev/null 2>&1; then
  agent=$(jq -r '.agent_type // empty' <<<"$input")
  text=$(jq -c '.tool_input // {}' <<<"$input")
else
  [[ $input =~ \"agent_type\":\ *\"([^\"]*)\" ]] && agent=${BASH_REMATCH[1]}
  text=$input
fi
case $agent in dirty-room-answerer|dirty-room-reviewer) exit 0 ;; esac

e='([/"'"'"' =:]|$)'
dirty=(
  "(^|[^A-Za-z0-9_.-])(\.\./)+(linux[A-Za-z0-9_.-]*|mesa|drm-[A-Za-z0-9_.-]*)$e"
  "/Projects/OS/(linux[A-Za-z0-9_.-]*|mesa|drm-[A-Za-z0-9_.-]*)$e"
  "chinese-wall/provenance"
  "/scratchpad/[^\"' ]*\.[ch]$e"
)
for re in "${dirty[@]}"; do
  if [[ $text =~ $re ]]; then
    echo "clean-room: this names ${BASH_REMATCH[0]}, which is on the dirty side of the wall." >&2
    echo "The clean side reads only chinese-wall/specs (and permissive sources, per chinese-wall/README.md). Put the question to the dirty room: spawn a dirty-room-answerer." >&2
    exit 2
  fi
done
exit 0
