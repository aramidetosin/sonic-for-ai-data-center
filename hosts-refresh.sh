#!/bin/bash
# hosts-refresh.sh: rewrite containerlab's block in /etc/hosts from the RUNNING lab containers (name, mgmt address, short id, clab kind label),
# so `ssh admin@clab-sonic-clos-dc-<node>` resolves after node-recreate.sh (which re-creates containers outside `clab deploy`).
# Only the lines between the CLAB-sonic-clos-dc markers change; a dated backup is kept; the file is rewritten in place (same inode).
set -eu
S="###### CLAB-sonic-clos-dc-START ######"; E="###### CLAB-sonic-clos-dc-END ######"
grep -qx "$S" /etc/hosts && grep -qx "$E" /etc/hosts || { echo "hosts-refresh: markers not found, /etc/hosts left alone" >&2; exit 1; }
blk=$(docker ps --filter name=^clab-sonic-clos-dc- --format "{{.Names}}" | sort | while read -r n; do
  ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"clab-sonic-clos-dc\"}}{{.IPAddress}}{{end}}" $n)
  [ -n "$ip" ] || continue
  printf "%s\t%s %s\t# Kind: %s\n" "$ip" "$n" "$(docker inspect -f "{{.Id}}" $n | cut -c1-12)" "$(docker inspect -f "{{index .Config.Labels \"clab-node-kind\"}}" $n)"
done)
cp -p /etc/hosts /etc/hosts.bak-$(date +%Y%m%d-%H%M%S)
python3 - "$S" "$E" "$blk" <<"PY"
import sys
s, e, blk = sys.argv[1:4]
t = open("/etc/hosts").read().split("\n"); i, j = t.index(s), t.index(e)
open("/etc/hosts", "r+").write("\n".join(t[:i + 1] + blk.split("\n") + t[j:]))
with open("/etc/hosts", "r+") as f: f.truncate(len("\n".join(t[:i + 1] + blk.split("\n") + t[j:]).encode()))
PY
echo "hosts-refresh: $(echo "$blk" | grep -c .) lab containers in /etc/hosts"
