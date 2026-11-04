# check-lib.sh: helpers for a check that writes its own result directory (source it after lib.sh; drills.sh uses it):
#   results/sonic-clos-dc_<kind>_<ts>/   commands.txt (every command, in order, through redact: no key or password), raw/, result.txt
#   result lines "  PASS  [tag] text", "  FAIL  [tag] text   -> why", "  KNOWN [tag] text"; the last line "== RESULT: P passed, F failed, K known"
#   close <result file> returns non-zero when the result holds a FAIL. Tag [D]: a drill.
aset() {   # aset <kind>: makes the result directory, sets OUT, CMDLOG, KIND, TS
  KIND=$1; TS=$(date -u +%Y%m%d_%H%M%S); OUT=results/${LAB}_${KIND}_$TS; mkdir -p "$OUT/raw"
  CMDLOG="$PWD/$OUT/commands.txt"; : > "$CMDLOG"; P=0; F=0; K=0; echo "$KIND -> $OUT"; }
ev()   { printf '%s\n' "$*" | redact >> "$CMDLOG"; }                              # a note or a command line into commands.txt
R()    { ev "\$ $*"; local o; o=$(eval "$*" 2>&1); printf '%s\n' "$o" | redact >> "$CMDLOG"; printf '%s\n' "$o"; }   # run + record
ok()   { printf "  PASS  %s\n" "$1"; P=$((P + 1)); }
bad()  { printf "  FAIL  %s%s\n" "$1" "${2:+   -> $2}"; F=$((F + 1)); }
kn()   { printf "  KNOWN %s\n" "$1"; K=$((K + 1)); }
chk()  { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected $2, got ${3:-nothing}"; }   # chk <text> <expected> <got>
ge()   { [ "${3:-0}" -ge "$2" ] 2>/dev/null && ok "$1 ($3)" || bad "$1" "expected >= $2, got ${3:-nothing}"; }
has()  { echo "$3" | grep -qE "$2" && ok "$1" || bad "$1" "got: $(echo $3 | head -c 160)"; }      # has <text> <regex> <output>
hasnt(){ echo "$3" | grep -qE "$2" && bad "$1" "reached: $(echo $3 | head -c 120)" || ok "$1"; }
result() { echo; echo "== RESULT: $P passed, $F failed, $K known"; }
close() { grep -q ' 0 failed' "$1"; }                                    # close <result file>: 0 when it holds no FAIL
# ---- the clusters: a node over ssh (core@ its container's management address), oc on a cluster's own bastion
NS() { NSSH "$1" "$2"; }                                                         # NS <container> <cmd>
OCB() { docker exec $C-bastion-$1 bash -c "$2" 2>&1; }                           # OCB <cl> '<sh>': oc / jq on bastion-<cl>
podnode() { OCB $1 "oc -n $2 get pod -l $3 -o jsonpath={.items[0].spec.nodeName}"; }   # podnode <cl> <ns> <selector>: the node of the first match
# a tenant's API key (APISIX consumer), read on its own bastion, never printed or recorded
apikey() { OCB $1 "oc -n platform get secret inference-api-key -o jsonpath={.data.key} | base64 -d"; }
# provenance: what this check ran against (lab tree hash, images, versions), for the head of a report
provenance() {
  echo "- lab tree: sha256 $(find . -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.cli' -o -name '*.xml' \) -not -path './results/*' | sort | xargs cat | sha256sum | cut -c1-64) over $(find . -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.cli' -o -name '*.xml' \) -not -path './results/*' | wc -l) files"
  echo "- deployed: $(docker inspect -f '{{.State.StartedAt}}' $C-spine1 | cut -c1-19)Z (spine1 started); host uptime $(awk '{printf "%.1f d", $1/86400}' /proc/uptime)"
  echo "- images: $(docker ps --filter name=$C- --format '{{.Image}}' | sort | uniq -c | awk '{printf "%s x%s; ", $2, $1}')"
  echo "- OpenShift: $(for cl in $CLUSTERS; do printf '%s %s (%s nodes); ' $cl "$(OCB $cl 'oc get clusterversion -o jsonpath={.items[0].status.desired.version}')" "$(OCB $cl 'oc get nodes --no-headers | wc -l' | tr -d ' ')"; done)"
  echo "- ONTAP: $(ONTAP version | head -1)"; }
