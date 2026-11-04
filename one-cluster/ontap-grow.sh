#!/bin/bash
# ontap-grow.sh: the simulator's capacity for the models and the tenants' data (4 model LUNs + MinIO + Harbor per tenant; the base aggregates are ~14 GB), run once on a
# fresh cluster BEFORE ontap-setup.sh, while nothing stores data on it.
#   1 vsim_makedisks -n 12 -t 36 -a 2 on each node (12 x 9 GB simulated disks; diag system shell via ontap-shell.py), skipped if present
#   2 the simulator sees new disks only after a reboot: node 2, then epsilon to node 2 and node 1, then epsilon back
#   3 assign the new disks, one RAID-DP aggregate per node from them: aggr_netapp01 / aggr_netapp02
cd "$(dirname "$0")"; . ./lib.sh
N1=dc-ontap-01; N2=dc-ontap-02
rows() { ONTAP "$1" | awk 'NF && $1 !~ /^-+$/ && !/entries were displayed|^Error|^  /' | tail -n +2; }
healthy() { [ "$(rows "cluster show -fields health" | awk '$2 == "true"' | wc -l)" = 2 ]; }
wait_healthy() { local t=$((SECONDS + 1800)); sleep 90; until healthy; do [ $SECONDS -gt $t ] && { say "cluster not healthy after 30 min"; return 1; }; sleep 20; done; }
[ "$(rows "storage aggregate show -aggregate aggr_netapp01,aggr_netapp02 -fields aggregate" | wc -l)" = 2 ] && { say "aggr_netapp01 and aggr_netapp02 exist"; exit 0; }
say "0/3 the diag account (a fresh simulator has it locked, without a password): LAB password from .env, unlocked"
./ontap-shell.py --unlock-diag || exit 1
say "1/3 simulated disks"
for n in $N1 $N2; do
  c=$(./ontap-shell.py $n "ls /sim/dev/,disks | grep -c ^v2[.]" | tail -1)
  [ "${c:-0}" -ge 12 ] && say "$n: $c disks on adapter 2 already" || ./ontap-shell.py $n "cd /sim/dev && sudo vsim_makedisks -n 12 -t 36 -a 2 >/dev/null 2>&1; ls ,disks | grep -c ^v2[.]" | tail -1 | sed "s/^/  $n adapter-2 disks: /"
done
if [ "$(rows "storage disk show -container-type unassigned -fields disk" | wc -l)" -lt 24 ] && [ "$(rows "storage disk show -fields physical-size" | awk '$2 ~ /GB$/ && $2+0 > 5' | wc -l)" -lt 24 ]; then
  say "2/3 rebooting node 2 (node 1 holds epsilon), then node 1"
  ONTAP "set -privilege advanced -confirmations off; system node reboot -node $N2 -ignore-quorum-warnings true -inhibit-takeover true" | tail -1
  wait_healthy || exit 1
  ONTAP "set -privilege advanced -confirmations off; cluster modify -node $N1 -epsilon false; cluster modify -node $N2 -epsilon true" | tail -1
  ONTAP "set -privilege advanced -confirmations off; system node reboot -node $N1 -ignore-quorum-warnings true -inhibit-takeover true" | tail -1
  sleep 120; wait_healthy || exit 1
  ONTAP "set -privilege advanced -confirmations off; cluster modify -node $N2 -epsilon false; cluster modify -node $N1 -epsilon true" | tail -1
fi
say "3/3 aggregates from the new disks"
for n in $N1 $N2; do ONTAP "storage disk assign -all true -node $n" >/dev/null; done; sleep 20
for i in 01 02; do n=dc-ontap-$i
  dl=$(rows "storage disk show -owner $n -container-type spare -fields disk,physical-size" | awk '{v=$2; u=v; sub(/[0-9.]+/, "", u); sub(/[A-Z]+$/, "", v); if (u == "GB" && v + 0 > 5) print $1}' | paste -sd,)
  say "$n: new spares $dl"
  [ "$(echo "$dl" | tr ',' '\n' | grep -c .)" = 12 ] || { say "$n: expected 12 new 9 GB disks"; exit 1; }
  ONTAP "storage aggregate create -aggregate aggr_netapp$i -node $n -disklist $dl -raidtype raid_dp" | tail -1
done
ONTAP "storage aggregate show -fields aggregate,node,size,availsize,diskcount"
