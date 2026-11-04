#!/bin/bash
# node-resize.sh <switch> <MiB>: give one Dell SONiC switch VM more memory (the leaves panicked on OOM, SONiC's panic_on_oom). The container's
# environment cannot change in place, so the container is re-created from its OWN spec (image, network + address, labels, binds, sysctls, launcher)
# with QEMU_MEMORY=<MiB>; every link of it in the topology is re-made (relink.sh); its configuration is pushed again from configs/<sw>.cli
# (sonic-apply.sh: the VM's disk lives in the container and starts fresh); the running configuration before and after is compared line by line;
# the switch must be back in the fabric (underlay + EVPN 4/4, its ESI-LAG peers LR, VXLAN tunnels to the other VTEPs) before the script returns 0.
# One leaf of an ESI-LAG pair at a time: the partner carries every dual-homed link meanwhile.
set -u
cd "$(dirname "$0")"; . ./lib.sh
SWN=${1:?switch}; MEM=${2:?MiB}; N=$C-$SWN; LOG=logs/resize-$SWN-$(date +%Y%m%d%H%M%S); mkdir -p $LOG
docker inspect $N >/dev/null 2>&1 || { echo "$N does not exist"; exit 1; }
cur=$(docker inspect $N --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^QEMU_MEMORY=//p'); say "$SWN: QEMU_MEMORY now ${cur:-default (4096)}, target $MEM"
# 1. the state to come back to
timeout 180 bash -c ". ./lib.sh; KL $SWN 'show running-configuration'" > $LOG/running-before.txt 2>&1
timeout 120 bash -c ". ./lib.sh; KL $SWN 'show evpn es'" | awk '$1 ~ /^00:/ && $2 ~ /L/ {print $3}' | sort > $LOG/es-before.txt   # its local ES
grep -q '^router bgp' $LOG/running-before.txt || { echo "$SWN: no running configuration read, stop"; exit 1; }
# 2. the container, re-created from its own spec with the new memory
docker inspect $N > $LOG/inspect.json
python3 - $LOG/inspect.json $MEM > $LOG/create.args <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))[0]; mem = sys.argv[2]; c, h = d["Config"], d["HostConfig"]
net = list(d["NetworkSettings"]["Networks"].items())[0]
a = ["--name", d["Name"].lstrip("/"), "--hostname", c["Hostname"], "--network", net[0], "--ip", net[1]["IPAMConfig"]["IPv4Address"] if net[1].get("IPAMConfig") else net[1]["IPAddress"]]
if h.get("Privileged"): a.append("--privileged")
for e in c.get("Env") or []:
    if not e.startswith("QEMU_MEMORY="): a += ["-e", e]
a += ["-e", "QEMU_MEMORY=" + mem]
for k, v in (c.get("Labels") or {}).items(): a += ["--label", "%s=%s" % (k, v)]
for b in h.get("Binds") or []: a += ["-v", b]
for x in h.get("ExtraHosts") or []: a += ["--add-host", x]
for k, v in (h.get("Sysctls") or {}).items(): a += ["--sysctl", "%s=%s" % (k, v)]
if c.get("Entrypoint"): a += ["--entrypoint", c["Entrypoint"][0]]
a.append(c["Image"]); a += (c["Entrypoint"] or [])[1:] + (c.get("Cmd") or [])
print("\n".join(a))
EOF
mapfile -t ARGS < $LOG/create.args
say "$SWN: re-creating the container ($(grep -c . $LOG/create.args) args)"
docker rm -f $N >/dev/null && docker create "${ARGS[@]}" >/dev/null && docker start $N >/dev/null || { echo "$SWN: re-create failed (spec in $LOG/inspect.json)"; exit 1; }
# 3. its links, from the topology
L=$(python3 - $TOPO $SWN <<'EOF'
import re, sys
sw = sys.argv[2]; out = []
for l in open(sys.argv[1]):
    m = re.search(r'endpoints: \["([^"]+)", "([^"]+)"\]', l)
    if m and sw in (m.group(1).split(":")[0], m.group(2).split(":")[0]): out += [m.group(1), m.group(2)]
print(" ".join(out))
EOF
)
sleep 5; say "$SWN: $(( $(echo $L | wc -w) / 2 )) links"; ./relink.sh $L > $LOG/relink.txt 2>&1; grep -c "link " $LOG/relink.txt
# 4. the configuration, from the source of record
./sonic-apply.sh $SWN 2>&1 | tail -1
sleep 30
timeout 180 bash -c ". ./lib.sh; KL $SWN 'show running-configuration'" > $LOG/running-after.txt 2>&1
norm() { grep -vE '^\s*$|^!|Building configuration|^Current configuration' "$1" | sed 's/[[:space:]]*$//' | sort -u; }
diff <(norm $LOG/running-before.txt) <(norm $LOG/running-after.txt) > $LOG/running.diff; say "$SWN: running configuration differs in $(grep -c '^[<>]' $LOG/running.diff) lines (before < / after >; $LOG/running.diff)"
# 5. back in the fabric
for i in $(seq 1 40); do
  u=$(timeout 120 bash -c ". ./lib.sh; KL $SWN 'show bgp ipv4 unicast summary'" | awk '/established/ {print $NF}')
  e=$(timeout 120 bash -c ". ./lib.sh; KL $SWN 'show bgp l2vpn evpn summary'" | awk '/established/ {print $NF}')
  t=$(timeout 120 bash -c ". ./lib.sh; KL $SWN 'show vxlan tunnel'" | grep -c oper_up)
  timeout 120 bash -c ". ./lib.sh; KL $SWN 'show evpn es'" | awk '$1 ~ /^00:/ && $2 ~ /LR/ {print $3}' | sort > $LOG/es-after.txt   # local ES seen by the partner too
  [ "$u" = 4 ] && [ "$e" = 4 ] && [ "$t" -ge 11 ] && cmp -s $LOG/es-before.txt $LOG/es-after.txt && break; sleep 15; done
m=$(docker exec $N sh -c 'ps -eo args | grep -m1 [q]emu' | grep -oE ' -m [0-9]+' | awk '{print $2}')
say "$SWN: VM memory ${m:-?} MiB; underlay ${u:-0}/4, EVPN ${e:-0}/4, VXLAN tunnels up $t; local ES before $(grep -c . $LOG/es-before.txt), LR after $(grep -c . $LOG/es-after.txt)"
[ "$m" = "$MEM" ] && [ "$u" = 4 ] && [ "$e" = 4 ] && [ "$t" -ge 11 ] && cmp -s $LOG/es-before.txt $LOG/es-after.txt && [ ! -s $LOG/running.diff ]
