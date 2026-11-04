#!/bin/bash
# validate-all.sh [--no-drills]: runs every check of the lab in order, one at a time (the switches are VMs; a parallel load would change what
# is measured): validate-fabric.sh all, validate-rails.sh all, validate-storage.sh, validate-ocp.sh (clusters prod, dev, gpu),
# validate-platform.sh for gpu, prod and dev, validate-isolation.sh, validate-f5.sh, then drills.sh unless --no-drills (the drills shut switch
# ports, move a LIF and fail over the BIG-IP under traffic, and restore them). Each check writes its own directory under results/; this script
# prints each check's RESULT line, writes results/summary.txt (one line per check) and exits 1 when any check fails.
cd "$(dirname "$0")" || exit 1; . ./lib.sh
case "${1:-}" in ""|--no-drills) ;; *) echo "usage: $0 [--no-drills]" >&2; exit 2;; esac
mkdir -p results; SUM=results/summary.txt; : > $SUM; RC=0
run() {   # run <check> [args]: the check's output on the terminal, its RESULT line and exit code into the summary
  local o r line; o=$(mktemp); say "== $*"; ./"$@" 2>&1 | tee "$o"; r=${PIPESTATUS[0]}
  line=$(grep -E '^(== )?RESULT' "$o" | tail -1 | sed -E 's/^== //'); rm -f "$o"
  [ $r = 0 ] && echo "$line" | grep -q ' 0 failed' || RC=1
  say "== $1: ${line:-no RESULT line} (rc $r)"; printf '%s %-28s %s (rc %d)\n' "$(date -u +%FT%TZ)" "$*" "${line:-no RESULT line}" $r >> $SUM; }
run validate-fabric.sh all
run validate-rails.sh all
run validate-storage.sh
run validate-ocp.sh
for cl in gpu prod dev; do run validate-platform.sh $cl; done
run validate-isolation.sh
run validate-f5.sh
[ "${1:-}" = --no-drills ] || run drills.sh
echo; cat $SUM; exit $RC
