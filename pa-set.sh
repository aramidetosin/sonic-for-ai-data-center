#!/bin/bash
# pa-set.sh <xpath> <element> | pa-set.sh --delete <xpath> | pa-set.sh --commit : PAN-OS config API helpers for the sonic-clos-dc PA-VM
cd "$(dirname "$0")"; . ./lib.sh
K=$(pakey)   # lib.sh, the password from appliances.env in the POST body
A() { curl -sk --max-time 60 -G "https://$PA/api/" --data-urlencode "key=$K" "$@"; echo; }
case "$1" in
  --delete) A --data-urlencode type=config --data-urlencode action=delete --data-urlencode "xpath=$2" ;;
  --commit)
    j=$(curl -sk "https://$PA/api/?type=commit&key=$K" --data-urlencode "cmd=<commit></commit>" | sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p')
    for i in $(seq 1 60); do sleep 4; r=$(A --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$j</id></jobs></show>")
      echo "$r" | grep -q "<status>FIN</status>" && { echo "commit $j: $(echo "$r" | sed -n 's:.*<result>\([A-Z]*\)</result>.*:\1:p' | head -1)"; break; }; done ;;
  *) A --data-urlencode type=config --data-urlencode action=set --data-urlencode "xpath=$1" --data-urlencode "element=$2" ;;
esac
