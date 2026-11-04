#!/bin/bash
# rail-roce.sh [switch ...]: Dell's RoCEv2 profile on every rail switch.
# `roce enable` asks to confirm, saves the configuration and reboots the switch once; KLISH -c cannot answer the prompt, so the command is
# typed into an interactive sonic-cli. A switch that already runs the profile is skipped. Done = PORT_QOS_MAP of its first port holds
# pfc_enable 3,4 after the reboot. Log: logs/roce-<sw>.log
cd "$(dirname "$0")"; . ./lib.sh; mkdir -p logs
SWS=("$@"); [ $# -eq 0 ] && SWS=($(awk '$2 ~ /^rail-/ {print $2}' mgmt-hosts.txt))
one() {
  local n=$1 i
  if SW $n 'sonic-cli -c "show running-configuration"' | grep -q "^roce enable"; then say "$n: roce already enabled"; else
    local boot; boot=$(SW $n 'cat /proc/sys/kernel/random/boot_id')
    { sleep 3; echo "configure terminal"; sleep 2; echo "roce enable"; sleep 3; echo "y"; sleep 30; } |
      sshpass -p admin ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@"$(mip $n)" sonic-cli > logs/roce-$n.log 2>&1
    # the profile is saved before the reboot, which follows a minute or two later: done = a NEW boot with swss running
    for i in $(seq 1 80); do
      [ "$(SW $n 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" != "$boot" ] && SW $n 'systemctl is-active swss' 2>/dev/null | grep -qx active && break
      sleep 15; done
    [ $i = 80 ] && { say "$n: no reboot seen after 20 min"; return 1; }
  fi
  for i in $(seq 1 40); do
    SW $n 'redis-cli -n 4 hget "PORT_QOS_MAP|Ethernet0" pfc_enable' 2>/dev/null | grep -qx "3,4" && { say "$n: RoCE profile active (pfc_enable 3,4)"; return 0; }
    sleep 15; done
  say "$n: RoCE profile NOT active"; return 1
}
rc=0; for n in "${SWS[@]}"; do one $n & done; for j in $(jobs -p); do wait $j || rc=1; done; exit $rc
