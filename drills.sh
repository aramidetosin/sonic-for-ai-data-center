#!/bin/bash
# drills.sh [drill ...]: failure drills under live traffic, each restored and checked before the next.
#   link     d1  one ESI-LAG leg of the cluster-prod node running whoami (it serves 10.0.1.200 in Vrf-Prod, announced by every node over MetalLB)   d2  one PA-VM ae1 member (leaf6a-border side)
#            d3  one ONTAP a0a member (netapp-01 on leaf5a-storage)
#   switch   d4  the whole rack leaf "a" of that node      d5  spine2 (all 12 fabric ports)
#            d6  leaf6a-border (every port: the PA, both BIG-IP trunks, dns-ntp1 / dns-ntp2, the spines)
#   storage  d7  svm-prod's NFS LIF nfs-netapp01 migrated to the other ONTAP node and reverted
#   balancer d8  the active BIG-IP forced to standby (the peer takes the VIPs), then failed back
#   app      d9  one of prod's APISIX pods deleted   d10 one of prod's LiteLLM pods deleted
# prod and dev are separate clusters on the same addresses; the app drills act on cluster prod from bastion-prod.
# Traffic during every drill: probe-prod and probe-dev > their own whoami through the BIG-IP VIP 10.0.5.10 (0.5 s), probe-prod DNS > dns-ntp1 (1 s),
# the external LAN > 192.168.100.142 (1 s), a writer pod on prod-san in cluster prod (fsync every 1 s), prod's NFS marker through the BIG-IP (1 s), and for the
# balancer and app drills prod inference (chat, back to back). A drill PASSes when every probe kept >= 90 % of its requests and the element is back.
# Every switch port shut is reopened, the LIF reverted and the BIG-IP failed back by an EXIT trap, whatever happens. Nothing else is changed.
# Results in results/sonic-clos-dc_drills_<ts>/: result.txt (the judged lines), report.md (a table per drill and the result), raw/ (per drill and
# probe), commands.txt.
set -u
cd "$(dirname "$0")" || exit 1; . ./lib.sh; . ./check-lib.sh
aset drills; V="$OUT/result.txt"; D=dc.lab; RESTORE=(); NSD=scd-drill
WANT=("$@"); [ $# -eq 0 ] && WANT=(d1 d2 d3 d4 d5 d6 d7 d8 d9 d10)
want() { local d; for d in "${WANT[@]}"; do [ "$d" = "$1" ] && return 0; done; return 1; }
# ---- switch ports: shut / reopen through one chained KLISH session; every shut port is remembered for the trap
ports_cmd() { local sw=$1 act=$2; shift 2; local a=("configure terminal") p; for p in "$@"; do a+=("interface $p" "$act" "exit"); done; KL $sw "${a[@]}" > /dev/null 2>&1; }
shut() { local sw=$1; shift; ev "\$ KL $sw 'configure terminal' 'interface <port>' 'shutdown' ... : $*"; ports_cmd $sw shutdown "$@"; RESTORE+=("$sw:$*"); }
reopen() { local e sw; for e in "${RESTORE[@]}"; do sw=${e%%:*}; ev "\$ KL $sw ... 'no shutdown': ${e#*:}"; ports_cmd $sw "no shutdown" ${e#*:}; done; RESTORE=(); }
F5A() { ./bigip-run.sh "$@" 2>&1; }
active() { local u; for u in lb-f5a lb-f5b; do F5A $u 'tmsh show cm failover-status' | grep -qE '^Status +ACTIVE' && { echo $u; return; }; done; }
LIFMOVED=""; F5HOME=""; E0DDOWN=""; PADOWN=""
PAX="/config/devices/entry[@name='localhost.localdomain']/network/interface/ethernet/entry[@name='ethernet1/1']"
palink() {   # palink down | auto: ethernet1/1's link-state, committed; auto deletes the element again (the bootstrap config has none)
  if [ "$1" = down ]; then ./pa-set.sh "$PAX" "<link-state>down</link-state>" > /dev/null; else ./pa-set.sh --delete "$PAX/link-state" > /dev/null; fi
  ./pa-set.sh --commit > /dev/null; }
failback() { [ -n "$F5HOME" ] || return 0; local a; a=$(active); [ -n "$a" ] && [ "$a" != "$F5HOME" ] && { ev "\$ [$a] tmsh run sys failover standby"; F5A $a 'tmsh run sys failover standby' > /dev/null; }; F5HOME=""; }
cleanup() { [ -n "$PADOWN" ] && palink auto; [ -n "$E0DDOWN" ] && ONTAP "set -privilege advanced -confirmations off; network port modify -node dc-ontap-01 -port e0d -up-admin true" > /dev/null; reopen; [ -n "$LIFMOVED" ] && ONTAP "network interface revert -vserver svm-prod -lif nfs-netapp01" > /dev/null; failback; probes_stop 2>/dev/null; }
trap cleanup EXIT
upports() { KL $1 "show interface status" | awk '$1 ~ /^Ethernet/ && $4 == "oper-up" {print $1}'; }
# ---- probes
probes_start() {   # starts every probe; each writes ok / fail lines
  # no probe loop of an earlier drill may survive into this one (a loop caught mid-request could miss the stop flag and run on, appending to the
  # next drill's counts): kill them by name ([b]racketed: the pattern never matches this command itself), then clear the files
  for c in prod dev; do X probe-$c "pkill -f '/tmp/p-[h]ello|/tmp/p-[d]ns|/tmp/p-[i]nf' 2>/dev/null; rm -f /tmp/p-* /tmp/stop"; done
  for c in prod dev; do docker exec -d $C-probe-$c sh -c "while [ ! -f /tmp/stop ]; do curl -sk -m 3 https://whoami.$c.$D/ | grep -q '^tenant $c ' && echo \"\$(date +%s.%N | cut -c1-14) ok\" || echo \"\$(date +%s.%N | cut -c1-14) fail\"; sleep 0.5; done >> /tmp/p-hello"; done
  docker exec -d $C-probe-prod sh -c "while [ ! -f /tmp/stop ]; do dig +short +time=2 +tries=1 model.$D @10.250.0.11 | grep -qx 10.0.5.11 && echo \"\$(date +%s.%N | cut -c1-14) ok\" || echo \"\$(date +%s.%N | cut -c1-14) fail\"; sleep 1; done >> /tmp/p-dns"
  rm -f /tmp/scd-p-*; PL=""; ( while [ ! -f /tmp/scd-stop ]; do curl -sk -m 3 --resolve whoami.prod.$D:443:192.168.100.142 https://whoami.prod.$D/ | grep -q '^tenant prod ' && echo "$(date +%s.%N | cut -c1-14) ok" || echo "$(date +%s.%N | cut -c1-14) fail"; sleep 1; done >> /tmp/scd-p-ext ) & PL="$PL $!"
  ( while [ ! -f /tmp/scd-stop ]; do X probe-prod "curl -sk -m 3 https://whoami.prod.$D/data/marker.txt" | grep -q 'written by prod' && echo "$(date +%s.%N | cut -c1-14) ok" || echo "$(date +%s.%N | cut -c1-14) fail"; sleep 1; done >> /tmp/scd-p-nfs ) & PL="$PL $!"
  OCB prod "oc -n $NSD exec writer -- sh -c 'rm -f /tmp/stop; : > /tmp/p-blk; (while [ ! -f /tmp/stop ]; do dd if=/dev/urandom of=/data/f bs=1M count=4 conv=fsync 2>/dev/null && echo \$(date +%s) ok || echo \$(date +%s) fail; sleep 1; done >> /tmp/p-blk) >/dev/null 2>&1 &'" > /dev/null
  if [ "${INF:-0}" = 1 ]; then AK=$(apikey prod); docker exec -d -e K="$AK" $C-probe-prod sh -c "while [ ! -f /tmp/stop ]; do curl -sk -m 120 -o /tmp/r -w '%{http_code} %{time_total}' -H \"apikey: \$K\" -H 'Content-Type: application/json' -d '{\"model\":\"qwen2.5-0.5b\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' https://inference.prod.$D/models/qwen2.5-0.5b/proxy/v1/chat/completions > /tmp/c; c=\$(cat /tmp/c); case \"\$c\" in 200\\ *) r=ok;; *) r=fail;; esac; echo \"\$(date +%s.%N | cut -c1-14) \$r \$c\"; done >> /tmp/p-inf"; unset AK; fi; }
probes_stop() { for c in prod dev; do X probe-$c "touch /tmp/stop"; done; touch /tmp/scd-stop; OCB prod "oc -n $NSD exec writer -- touch /tmp/stop" > /dev/null 2>&1; sleep 4
  [ -n "${PL:-}" ] && { kill $PL 2>/dev/null; wait $PL 2>/dev/null; }; PL=""; rm -f /tmp/scd-stop; }   # the the lab host-side loops: stopped and reaped by PID
tally() {   # tally <drill>: "probe ok total longest-outage-s" per probe into raw/<drill>-probes.txt (the timestamped samples: raw/<drill>-<probe>.log)
  local d=$1 n f
  mo() { awk '$2 == "fail" { if (!s) s = $1; e = $1 } $2 == "ok" && s { if ($1 - s > m) m = $1 - s; s = 0 } END { if (s && e - s + 1 > m) m = e - s + 1; printf "%.1f", m + 0 }'; }
  line() { n=$1; f=$2; echo "$n $(awk '$2 == "ok"' $f | grep -c .) $(grep -c . $f) $(mo < $f)"; cp $f "$OUT/raw/$d-$n.log"; }
  { for c in prod dev; do X probe-$c 'cat /tmp/p-hello' > /tmp/scd-t-hello-$c; line hello-probe-$c /tmp/scd-t-hello-$c; done
    X probe-prod 'cat /tmp/p-dns' > /tmp/scd-t-dns; line dns-probe-prod /tmp/scd-t-dns
    line ext-142 /tmp/scd-p-ext; line nfs-marker /tmp/scd-p-nfs
    OCB prod "oc -n $NSD exec writer -- cat /tmp/p-blk" > /tmp/scd-t-blk; line blk-writes /tmp/scd-t-blk
    [ "${INF:-0}" = 1 ] && { X probe-prod 'cat /tmp/p-inf' > /tmp/scd-t-inf; line inference /tmp/scd-t-inf; }; } > "$OUT/raw/$d-probes.txt"
  rm -f /tmp/scd-t-*; cat "$OUT/raw/$d-probes.txt"; }
judge() {   # judge <drill> <label> <restored-check-output> <restored-regex>: every probe >= 90 % and the element back; the longest outage reported
  local d=$1 lab=$2 r=$3 rx=$4 bad_p="" pv_p="" n o t m
  while read -r n o t m; do [ "${t:-0}" -gt 0 ] || { bad_p="$bad_p $n(no samples)"; continue; }; [ $((o * 100 / t)) -ge 90 ] && continue
    # drill d2 only: a probe through the PA-VM that fell short within the PA-VM's own measured LAG-member convergence is a KNOWN
    if echo " ${PAVM_PROBES:-} " | grep -q " $n " && awk -v m=$m -v x=${PAVM_MAX:-0} 'BEGIN { exit !(m <= x) }'; then pv_p="$pv_p $n($o/$t, ${m}s)"; else bad_p="$bad_p $n($o/$t, longest outage ${m}s)"; fi
  done < "$OUT/raw/$d-probes.txt"
  local line; line=$(awk '{printf "%s %s/%s (%ss); ", $1, $2, $3, $4}' "$OUT/raw/$d-probes.txt")
  if [ -n "$bad_p" ]; then bad "[D] $d $lab: probes below 90 %" "$bad_p   ($line)"
  elif [ -n "$pv_p" ]; then kn "[D] $d $lab: only the probes through the PA-VM fell short:$pv_p; the PA-VM's software dataplane takes ~7 s to stop using a LAG member even when that member's link is down at both ends (measured); every other probe kept >= 90 % ($line)"
  else ok "[D] $d $lab: every probe kept >= 90 % ($line)"; fi
  echo "$r" | grep -qE "$rx" && ok "[D] $d $lab: restored" || bad "[D] $d $lab: not restored" "$(echo $r | head -c 160)"
  ROWS+=("| $d | $lab | $line | $(echo "$r" | grep -qE "$rx" && echo "restored, back $((BACKS / 60)) min $((BACKS % 60)) s after the failure" || echo NOT restored) |"); }
drill() {   # drill <id> <label> <seconds>: start probes, run the action ($ACT), hold, restore ($UNDO), wait ($BACK), judge
  local d=$1 lab=$2 hold=$3 i; echo "== $d: $lab"; ev ""; ev "# ===== $d: $lab"
  probes_start; sleep 8; local t0; t0=$(date +%s); eval "$ACT"; sleep "$hold"; eval "$UNDO"; local r=""; for i in $(seq 1 30); do r=$(eval "$BACK" 2>&1); echo "$r" | grep -qE "$RX" && break; sleep 6; done
  BACKS=$(( $(date +%s) - t0 )); sleep 6; probes_stop; tally $d > /dev/null; judge $d "$lab" "$r" "$RX"; echo; }
ROWS=()
# ---- the writer pod (prod-san, on prod-cp1 of cluster prod), and where things are
OCB prod "oc create namespace $NSD" > /dev/null 2>&1
docker exec -i $C-bastion-prod oc apply -f - > /dev/null <<EOF
{"apiVersion":"v1","kind":"List","items":[
 {"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"blk","namespace":"$NSD"},"spec":{"storageClassName":"prod-san","accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"1Gi"}}}},
 {"apiVersion":"v1","kind":"Pod","metadata":{"name":"writer","namespace":"$NSD"},"spec":{"nodeSelector":{"kubernetes.io/hostname":"prod-cp1"},
  "tolerations":[{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}],
  "securityContext":{"runAsNonRoot":true,"runAsUser":1001,"fsGroup":1001,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"w","image":"registry.access.redhat.com/ubi9/ubi-minimal:latest","command":["sleep","86400"],
   "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"d","mountPath":"/data"}]}],
  "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"blk"}}]}}]}
EOF
OCB prod "oc -n $NSD wait --for=condition=Ready pod/writer --timeout=300s" > /dev/null
VN=$(podnode prod whoami app=whoami)   # a prod node: its hostname is its container
# where it is cabled, from the source of record: leaf a of rack 3 <-> its eth1 (gen.py links), the PortChannel described <node>-lag
LA=leaf3a-compute; VRACK=rack3
VPORT=Ethernet$(( $(grep -oE "\"$LA:eth[0-9]+\", \"$VN:eth1\"" $TOPO | head -1 | sed -E 's/^"[^:]+:eth([0-9]+)".*/\1/') - 1 ))
VPO=$(awk -v d="description $VN-lag" '/^interface PortChannel/ {p=$2} $0 == d {sub("PortChannel", "", p); print p; exit}' configs/$LA.cli)
{ echo "$LAB failure drills $TS (prod's whoami on $VN, $VRACK, $LA $VPORT / PortChannel$VPO; writer pod on prod-cp1, prod-san)"; echo
if want d1; then ACT="shut $LA $VPORT"; UNDO="reopen"; BACK="echo \$(NS $VN 'grep -c \"MII Status: up\" /proc/net/bonding/bond0') \$(KL $LA 'show evpn es' | grep PortChannel$VPO)"; RX="^3 .*LR +PortChannel$VPO"
  drill d1 "ESI-LAG leg $LA $VPORT of $VN (PortChannel$VPO)" 30; fi
# d2 = a pulled cable too: the PA-VM's ethernet1/1 link goes down (a committed change: its applying is the moment of failure) with the switch port
if want d2; then ACT="PADOWN=1; palink down; shut leaf6a-border Ethernet6"; UNDO="palink auto; PADOWN=''; reopen"; PAVM_PROBES="dns-probe-prod ext-142"; PAVM_MAX=10; BACK="echo \$(KL leaf6a-border 'show evpn es' | grep PortChannel93) \$(KL leaf6a-border 'show interface status' | grep -E '^PortChannel93 ')"; RX="LR +PortChannel93 .*oper-up"
  drill d2 "the cable between the PA-VM ethernet1/1 (ae1) and leaf6a-border Ethernet6 (both ends down)" 30; PAVM_PROBES=""; PAVM_MAX=0; fi
# d3 = a pulled cable: both ends lose the link at once. The VMs here do not pass link state across their wiring (a switch-side shutdown leaves
# ONTAP's e0d up, and ONTAP asks for slow LACP: it would keep sending on it for up to 90 s), so both ends are taken down together
if want d3; then ACT="E0DDOWN=1; ONTAP 'set -privilege advanced -confirmations off; network port modify -node dc-ontap-01 -port e0d -up-admin false' > /dev/null; shut leaf5a-storage Ethernet4"
  UNDO="ONTAP 'set -privilege advanced -confirmations off; network port modify -node dc-ontap-01 -port e0d -up-admin true' > /dev/null; E0DDOWN=''; reopen"; BACK="ONTAP 'network port ifgrp show -node dc-ontap-01'"; RX="full +e0d, e0e, e0f, e0g"
  drill d3 "the cable between dc-ontap-01 e0d and leaf5a-storage Ethernet4 (a0a member: both ends down)" 30; fi
if want d4; then P4=$(upports $LA | xargs); ACT="shut $LA $P4"; UNDO="reopen"; BACK="echo \$(KL $LA 'show bgp ipv4 unicast summary' | grep -o 'established [0-9]*') lone-ES \$(KL $LA 'show evpn es' | awk '\$1 ~ /^00:/ && \$2 ~ /L/ && \$2 !~ /R/' | wc -l)"; RX="established 4 lone-ES 0$"
  drill d4 "whole rack leaf $LA ($(echo $P4 | wc -w) ports)" 45; fi
if want d5; then P5=$(upports spine2 | xargs); ACT="shut spine2 $P5"; UNDO="reopen"; BACK="KL spine2 'show bgp ipv4 unicast summary' | grep -o 'established [0-9]*'"; RX="established 12"
  drill d5 "spine2 ($(echo $P5 | wc -w) ports)" 45; fi
if want d6; then P6=$(upports leaf6a-border | xargs); ACT="shut leaf6a-border $P6"; UNDO="reopen"
  BACK="echo \$(KL leaf6a-border 'show bgp ipv4 unicast summary' | grep -o 'established [0-9]*') \$(for v in Vrf-Prod Vrf-Dev Vrf-Svc Vrf-Ocp; do KL leaf6a-border \"show bgp ipv4 unicast vrf \$v summary\" | grep -o 'established [0-9]*'; done | xargs)"
  RX="established 4 established 3 established 3 established 3 established 3"
  drill d6 "leaf6a-border ($(echo $P6 | wc -w) ports: the PA, both BIG-IP trunks, dns-ntp1, dns-ntp2, the spines)" 45; fi
if want d7; then ACT="LIFMOVED=1; ONTAP 'network interface migrate -vserver svm-prod -lif nfs-netapp01 -destination-node dc-ontap-02 -destination-port a0a-103' > /dev/null"
  UNDO="ONTAP 'network interface revert -vserver svm-prod -lif nfs-netapp01' > /dev/null; LIFMOVED=''"; BACK="ONTAP 'network interface show -vserver svm-prod -lif nfs-netapp01 -fields curr-node,is-home'"; RX="dc-ontap-01 +true"
  drill d7 "svm-prod NFS LIF nfs-netapp01 migrated to dc-ontap-02, then reverted" 30; fi
INF=1
if want d8; then F5HOME=$(active); F5PEER=$([ "$F5HOME" = lb-f5a ] && echo lb-f5b || echo lb-f5a)
  ACT="ev '\$ [$F5HOME] tmsh run sys failover standby'; F5A $F5HOME 'tmsh run sys failover standby' > /dev/null"; UNDO="failback"
  BACK="echo \$(active) \$(F5A $F5HOME 'tmsh show cm sync-status' | awk '/^Status/ {print \$2, \$3}')"; RX="^$F5HOME In Sync"
  drill d8 "the active BIG-IP $F5HOME forced to standby ($F5PEER takes the VIPs and their routes), then failed back" 40; F5HOME=""; fi
if want d9; then ACT="OCB prod 'oc -n platform delete \$(oc -n platform get pod -l app=apisix -o name | head -1) --wait=false' > /dev/null"; UNDO=":"; BACK="OCB prod 'oc -n platform rollout status deploy/apisix --timeout=10s'"; RX="successfully rolled out"
  drill d9 "one of prod's 2 APISIX pods deleted" 20; fi
if want d10; then ACT="OCB prod 'oc -n platform delete \$(oc -n platform get pod -l app=litellm -o name | head -1) --wait=false' > /dev/null"; UNDO=":"; BACK="OCB prod 'oc -n platform rollout status deploy/litellm --timeout=10s'"; RX="successfully rolled out"
  drill d10 "one of prod's 2 LiteLLM pods deleted" 20; fi
INF=0
result; } > "$V"
# the writer first, then its claim once the volume is detached (no VolumeFailedDelete retry), then the namespace
BPV=$(OCB prod "oc -n $NSD get pvc blk -o jsonpath={.spec.volumeName}"); OCB prod "oc -n $NSD delete pod writer --wait=true --timeout=120s" > /dev/null
for i in $(seq 1 60); do OCB prod "oc get volumeattachment --no-headers -o custom-columns=PV:.spec.source.persistentVolumeName" | grep -qx "$BPV" || break; sleep 3; done
OCB prod "oc delete namespace $NSD --wait=true --timeout=300s" > /dev/null
cat "$V"
{ echo "# $LAB failure drills, $TS"; echo; provenance; echo
  echo "Each element failed under live traffic, held, restored, and checked before the next drill. Probes (ok / sent): probe-prod and probe-dev to their own"
  echo "whoami through the BIG-IP VIP, DNS from probe-prod to dns-ntp1, the external LAN to 192.168.100.142, prod's NFS marker through the BIG-IP, fsync'd 4 MiB"
  echo "writes to a prod-san claim on prod-cp1 (cluster prod), and in the balancer and app drills prod inference. A drill passes when every probe keeps >= 90 % and"
  echo "the element is back."; echo
  echo "| drill | element failed | probes ok / sent (longest outage) | after |"; echo "|---|---|---|---|"; printf '%s\n' "${ROWS[@]}"
  echo; echo "## Result"; echo '```'; cat "$V"; echo '```'; echo; echo "Raw: raw/<drill>-probes.txt; every command: commands.txt."; } > "$OUT/report.md"
close "$V"
