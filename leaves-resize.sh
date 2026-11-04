#!/bin/bash
# leaves-resize.sh [MiB]: every front-end leaf to <MiB> (6144), one at a time, the "b" leaf of a pair before its "a"; each leaf's ESI-LAG partner
# must be healthy before it goes down (underlay 4/4, its local ES all LR); stops at the first leaf that does not come back clean (node-resize.sh rc).
cd "$(dirname "$0")"; . ./lib.sh; MEM=${1:-6144}
for p in 1:control 2:control 3:compute 4:compute 5:storage 6:border; do n=${p%%:*}; r=${p#*:}
  for x in b a; do sw=leaf$n$x-$r; y=$([ $x = b ] && echo a || echo b); partner=leaf$n$y-$r
    cur=$(docker inspect $C-$sw --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^QEMU_MEMORY=//p')
    [ "$cur" = "$MEM" ] && { say "$sw: already $MEM"; continue; }
    u=$(timeout 120 bash -c ". ./lib.sh; KL $partner 'show bgp ipv4 unicast summary'" | awk '/established/ {print $NF}')
    l=$(timeout 120 bash -c ". ./lib.sh; KL $partner 'show evpn es'" | awk '$1 ~ /^00:/ && $2 ~ /L/ && $2 !~ /R/' | wc -l)
    [ "$u" = 4 ] && [ "$l" = 0 ] || { say "STOP: partner $partner not healthy (underlay $u/4, $l local ES without the peer)"; exit 1; }
    ./node-resize.sh $sw $MEM || { say "STOP: $sw did not come back clean (logs/resize-$sw-*)"; exit 1; }
    say "$sw: done"; done; done
say "all leaves at $MEM MiB"; ./rmac-refresh.sh   # the other leaves still hold the re-created leaves' old router MACs
