#!/usr/bin/env bash
#
# Run the named molecule scenarios one after the other and show a tally.
#
# When a scenario fails, the run continues. At the end, the summary shows which
# scenarios failed and where their logs are. The exit status is 0 only when all
# scenarios pass.
#
# Usage: scripts/molecule-tally.sh <scenario> [<scenario> ...]
#
# Environment:
#   MOLECULE_TALLY_LOGDIR  directory for the per-scenario logs
#                          (default: a new directory under $TMPDIR)

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $(basename "$0") <scenario> [<scenario> ...]" >&2
  exit 64
fi

scenarios=("$@")
logdir="${MOLECULE_TALLY_LOGDIR:-$(mktemp -d -t molecule-tally-XXXXXX)}"
mkdir -p "$logdir"

# molecule and ansible look at their stdout to decide about colour. The pipe
# into tee below makes the answer "no". PY_COLORS tells molecule to use colour.
# molecule then sets ANSIBLE_FORCE_COLOR for the ansible-playbook that it
# starts, thus the task lines also have colour. The log file gets the text
# without the colour codes.
if [ -t 1 ]; then
  c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
  export PY_COLORS=1
else
  c_pass=""; c_fail=""; c_dim=""; c_off=""
fi

strip_ansi() { sed -u -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

statuses=()
durations=()
logs=()
failed=0

for scenario in "${scenarios[@]}"; do
  log="${logdir}/${scenario}.log"
  echo
  echo "${c_dim}=== molecule test -s ${scenario} ===${c_off}"
  start=$SECONDS

  molecule test -s "$scenario" 2>&1 | tee >(strip_ansi > "$log")
  # The exit status of molecule, not of tee.
  rc=${PIPESTATUS[0]}

  durations+=("$((SECONDS - start))")
  logs+=("$log")
  if [ "$rc" -eq 0 ]; then
    statuses+=("PASS")
  else
    statuses+=("FAIL")
    failed=$((failed + 1))
  fi
done

# -- Tally --------------------------------------------------------------
width=0
for scenario in "${scenarios[@]}"; do
  [ "${#scenario}" -gt "$width" ] && width=${#scenario}
done
[ "$width" -lt 8 ] && width=8

echo
printf '%s\n' "$(printf '=%.0s' $(seq 1 $((width + 24))))"
printf "%-${width}s  %-6s  %8s\n" "SCENARIO" "RESULT" "TIME"
printf '%s\n' "$(printf -- '-%.0s' $(seq 1 $((width + 24))))"

for i in "${!scenarios[@]}"; do
  seconds=${durations[$i]}
  elapsed=$(printf '%dm%02ds' $((seconds / 60)) $((seconds % 60)))
  if [ "${statuses[$i]}" = "PASS" ]; then
    colour=$c_pass
  else
    colour=$c_fail
  fi
  printf "%-${width}s  ${colour}%-6s${c_off}  %8s\n" \
    "${scenarios[$i]}" "${statuses[$i]}" "$elapsed"
done
printf '%s\n' "$(printf '=%.0s' $(seq 1 $((width + 24))))"
printf '%d of %d scenarios passed.\n' \
  "$(( ${#scenarios[@]} - failed ))" "${#scenarios[@]}"

if [ "$failed" -gt 0 ]; then
  echo
  echo "Logs of the failed scenarios:"
  for i in "${!scenarios[@]}"; do
    [ "${statuses[$i]}" = "FAIL" ] && echo "  ${scenarios[$i]}: ${logs[$i]}"
  done
  exit 1
fi

echo "${c_dim}Logs: ${logdir}${c_off}"
