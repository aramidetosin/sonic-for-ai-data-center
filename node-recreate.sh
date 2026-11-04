#!/bin/bash
# node-recreate.sh <node> [--from <old container>] [--template <inspect.json>] [--keep-disk] [--dry-run]: re-create one linux-kind node of the RUNNING lab from the topology
# (gen.py nodes.json + sonic-clos-dc.clab.yml), as `containerlab deploy` would have made it, without touching any other node.
# Used by the migration from one cluster to three to re-image the 17 OpenShift VMs (ocp-prod-worker1 > prod-cp1, ...), to rename bastion-ocp > bastion-gpu, and to
# re-address probe-prod / probe-dev and bastion-prod / bastion-dev (a container's env and binds cannot change in place).
#   1. the template: <old container> (default: <node> itself): its labels, network, privileges, sysctls, restart policy (docker inspect)
#   2. an RHCOS node (scd/rhcos-node): the guest is powered off from inside (ssh core@, as down.sh), the container waits for qemu to exit
#   3. the old container is removed (its veths die with it); an RHCOS node's VM disk directory is MOVED aside to nodes/.onecluster-20261030/<old>
#      (same filesystem, nothing deleted; --keep-disk keeps it in place for a node that keeps its name and disk)
#   4. the new container: name, hostname, management address, image, env, binds and exec from nodes.json; containerlab's labels re-pointed
#   5. every link of <node> in the topology re-made (relink.sh: the leaf side gets its tc redirect back, a Linux host re-bonds, an RHCOS node's
#      wrapper bridges the new veths itself once they all exist), then the node's exec commands (host-up.sh ...) as containerlab runs them
#   6. checks: the container runs, every link exists on both sides; an RHCOS node holds (HOLD_FILE) until ocp-install.sh releases its cluster
# Log: logs/recreate-<node>-<time>/. --dry-run prints the docker create arguments and the links, changes nothing.
set -u
cd "$(dirname "$0")"; . ./lib.sh
NEW=${1:?node}; shift; OLD=$NEW; KEEP=0; DRY=0; TPL=""
while [ $# -gt 0 ]; do case $1 in --from) OLD=$2; shift 2;; --keep-disk) KEEP=1; shift;; --dry-run) DRY=1; shift;; --template) TPL=$2; shift 2;; *) echo "unknown $1"; exit 2;; esac; done
LOG=logs/recreate-$NEW-$(date +%Y%m%d%H%M%S); mkdir -p $LOG
python3 -c "import json,sys; n=json.load(open('nodes.json'))['nodes']; sys.exit(0 if '$NEW' in n else 1)" || { echo "$NEW is not a linux node in nodes.json (gen.py)"; exit 1; }
if [ -n "$TPL" ]; then cp "$TPL" $LOG/template.json   # a saved inspect of the node (its container is gone)
else docker inspect $C-$OLD > $LOG/template.json 2>/dev/null || { echo "no template container $C-$OLD (use --template <inspect.json>)"; exit 1; }; fi
IMG_NEW=$(python3 -c "import json; print(json.load(open('nodes.json'))['nodes']['$NEW']['image'])")
python3 - $LOG/template.json "$NEW" "$PWD" "$C" "$LAB" > $LOG/create.args <<'EOF'
import json, os, sys
t = json.load(open(sys.argv[1]))[0]; new, lab_dir, C, LAB = sys.argv[2:6]
spec = json.load(open(os.path.join(lab_dir, "nodes.json")))
mgmt, s = spec["mgmt"], spec["nodes"][new]
c, h = t["Config"], t["HostConfig"]
net = list(t["NetworkSettings"]["Networks"])[0]
a = ["--name", "%s-%s" % (C, new), "--hostname", new, "--network", net, "--ip", "%s.%d" % (mgmt, s["mgmt"])]
if h.get("Privileged"): a.append("--privileged")
if c.get("Tty"): a.append("-t")          # containerlab keeps a linux node alive with a TTY and open stdin (its /bin/sh waits on it)
if c.get("OpenStdin"): a.append("-i")
rp = (h.get("RestartPolicy") or {}).get("Name")
if rp and rp != "no": a += ["--restart", rp]
for k, v in (h.get("Sysctls") or {}).items(): a += ["--sysctl", "%s=%s" % (k, v)]
for x in h.get("ExtraHosts") or []: a += ["--add-host", x]
for d in h.get("Devices") or []: a += ["--device", "%s:%s:%s" % (d["PathOnHost"], d["PathInContainer"], d["CgroupPermissions"])]
labels = dict(c.get("Labels") or {})
old = labels.get("clab-node-name", "")
labels.update({"clab-node-name": new, "clab-node-longname": "%s-%s" % (C, new), "clab-node-group": s["group"],
               "clab-node-lab-dir": os.path.join(lab_dir, C, new), "clab-topo-file": os.path.join(lab_dir, LAB + ".clab.yml"), "containerlab": LAB})
for k, v in labels.items():
    if k.startswith(("clab", "containerlab")): a += ["--label", "%s=%s" % (k, v)]
for k, v in s["env"].items(): a += ["-e", "%s=%s" % (k, v)]
for b in s["binds"]:   # containerlab resolves a relative bind against the topology file's directory
    src, rest = b.split(":", 1)
    a += ["-v", "%s:%s" % (src if src.startswith("/") else os.path.join(lab_dir, src), rest)]
a.append(s["image"])   # the image's own entrypoint and command (a changed image brings its own)
print("\n".join(a))
EOF
[ -s $LOG/create.args ] || { echo "could not build the create arguments"; exit 1; }
# the node's links from the topology (both endpoints, pairs)
L=$(python3 - $TOPO $NEW <<'EOF'
import re, sys
n = sys.argv[2]; out = []
for l in open(sys.argv[1]):
    m = re.search(r'endpoints: \["([^"]+)", "([^"]+)"\]', l)
    if m and n in (m.group(1).split(":")[0], m.group(2).split(":")[0]): out += [m.group(1), m.group(2)]
print(" ".join(out))
EOF
)
NL=$(( $(echo $L | wc -w) / 2 ))
if [ $DRY = 1 ]; then echo "docker create:"; sed 's/^/  /' $LOG/create.args | grep -v -E '^  -e .*(PASS|KEY|SECRET)'; echo "links ($NL): $L"; exit 0; fi
RHCOS=0; [ "$(docker inspect -f '{{.Config.Image}}' $C-$OLD)" = scd/rhcos-node:1 ] && RHCOS=1
say "$NEW: from $C-$OLD (image $(docker inspect -f '{{.Config.Image}}' $C-$OLD) > $IMG_NEW), $NL links"
# 2. an RHCOS guest shuts down from inside: its filesystems stay clean even though the disk is set aside
if [ $RHCOS = 1 ] && [ "$(docker inspect -f '{{.State.Running}}' $C-$OLD)" = true ]; then
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $C-$OLD)
  ssh $SSHO -o ConnectTimeout=8 core@$ip "sudo systemctl poweroff" >/dev/null 2>&1; rc=$?
  # ssh exits 255 when it cannot connect: a guest paused by QEMU (a disk write failed with ENOSPC) or hung cannot shut down from inside
  if [ $rc = 255 ]; then say "$NEW: $OLD ($ip) does not answer ssh: no clean shutdown possible, the container is stopped"; else say "$NEW: guest poweroff sent to $OLD ($ip)"; fi
  [ $rc = 255 ] || for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' $C-$OLD)" = false ] && break; docker exec $C-$OLD pgrep -x qemu-system-x86 >/dev/null 2>&1 || break; sleep 5; done
  say "$NEW: $OLD guest $(docker exec $C-$OLD pgrep -x qemu-system-x86 >/dev/null 2>&1 && echo 'STILL RUNNING, stopping the container' || echo down)"
fi
# 3. the old container goes; an RHCOS node's disk is moved aside (never deleted)
if docker inspect $C-$OLD >/dev/null 2>&1; then docker rm -f $C-$OLD >/dev/null || { echo "could not remove $C-$OLD"; exit 1; }; fi
if [ $RHCOS = 1 ] && [ $KEEP = 0 ] && [ -d nodes/$OLD/vm ]; then
  A=nodes/.onecluster-20261030; mkdir -p $A
  [ -e $A/$OLD ] && { echo "$A/$OLD exists already: not moving the disk of $OLD, stop"; exit 1; }
  mv nodes/$OLD $A/$OLD && say "$NEW: old VM disk directory moved to $A/$OLD"
fi
[ $RHCOS = 1 ] || [ "$IMG_NEW" = scd/rhcos-node:1 ] && mkdir -p nodes/$NEW/vm
mkdir -p $C/$NEW
mapfile -t ARGS < $LOG/create.args
docker create "${ARGS[@]}" > $LOG/create.out 2>&1 && docker start $C-$NEW >/dev/null || { echo "$NEW: create/start failed ($LOG/create.out)"; exit 1; }
# 5. the links (relink.sh waits for nothing: the RHCOS wrapper waits up to 240 s for all its ethN; the others are re-bonded or redirected)
sleep 3; ./relink.sh $L > $LOG/relink.txt 2>&1; say "$NEW: $(grep -c '^\[' $LOG/relink.txt) links re-made"
python3 -c "import json; [print(e) for e in json.load(open('nodes.json'))['nodes']['$NEW']['exec']]" | while read -r e; do
  docker exec $C-$NEW bash -c "$e" > $LOG/exec.txt 2>&1 < /dev/null; say "$NEW: exec '$e' rc=$?"; done
# 6. checks
miss=0; for ep in $L; do n=${ep%%:*}; e=${ep#*:}; [ "$n" = pnet0 ] && continue
  docker exec $C-$n test -e /sys/class/net/$e 2>/dev/null || { miss=$((miss+1)); echo "  missing $ep" >> $LOG/missing.txt; }; done
st=$(docker inspect -f '{{.State.Status}}' $C-$NEW)
extra=""; [ "$IMG_NEW" = scd/rhcos-node:1 ] && { sleep 5; extra=", wrapper: $(docker logs $C-$NEW 2>&1 | grep -E 'holding|released|booting' | tail -1)"; }
./hosts-refresh.sh >/dev/null || say "$NEW: /etc/hosts not refreshed (hosts-refresh.sh)"   # the new container keeps its name in /etc/hosts
say "$NEW: $st, $NL links, $miss endpoints missing$extra"
[ "$st" = running ] && [ $miss = 0 ]
