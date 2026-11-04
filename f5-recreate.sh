#!/bin/bash
# f5-recreate.sh <unit>: create a BIG-IP node container the way containerlab does, for a running lab (containerlab 0.82 refuses a node-filtered
# deploy on a running lab, and `restart` needs an existing container). Spec copied from the peer unit's container (image, mgmt network,
# labels, privileges, launcher command), with this unit's name, address, env file and lab dir. The admin password is read from the unit's
# env file and never printed. Links: ./relink.sh afterwards. only for a unit whose licence key is free.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
U=${1:?unit}; P=$( [ $U = lb-f5a ] && echo lb-f5b || echo lb-f5a ); PC=$C-$P; UC=$C-$U
IP=$(awk -v n=$U '$2==n {print $1}' mgmt-hosts.txt); ENVF=/root/scd-secrets/$U.env; DIR=$PWD/clab-sonic-clos-dc/$U
docker inspect $UC >/dev/null 2>&1 && { echo "$UC exists"; exit 1; }
mkdir -p $DIR/config
pw=$(sed -n 's/^PASSWORD=//p' $ENVF)
labels=(); while IFS= read -r l; do labels+=(--label "$l"); done < <(docker inspect $PC | jq -r ".[0].Config.Labels | to_entries[] | \"\(.key)=\(.value)\"" | sed "s/$P/$U/g")
hosts=(); while IFS= read -r h; do hosts+=(--add-host "$h"); done < <(docker inspect $PC | jq -r ".[0].HostConfig.ExtraHosts[]")
envs=(); while IFS= read -r e; do envs+=(-e "$e"); done < <(docker inspect $PC | jq -r ".[0].Config.Env[] | select(test(\"^(CLAB_|QEMU_|CONNECTION_MODE|USERNAME|VERSION|no_proxy|NO_PROXY)\"))" | sed "s/$P/$U/g")
docker create --name $UC --hostname $U --privileged --network clab-$LAB --ip $IP --env-file $ENVF "${envs[@]}" "${labels[@]}" "${hosts[@]}" \
  -v $DIR/config:/config --entrypoint uv $(docker inspect $PC | jq -r ".[0].Config.Image") \
  run /launch.py --username admin --password "$pw" --hostname $U.dc.lab --connection-mode tc --trace >/dev/null
docker start $UC >/dev/null
echo "$UC created on $IP and started"
