#!/bin/bash
# pa-load.sh [xml]: load bootstrap/fw.xml into the running PA-VM: import, partial REPLACE of network and vsys (a merge would keep
# rules and routes the generator no longer has), validate, commit (replace, not merge).
cd "$(dirname "$0")"; . ./lib.sh; XML=${1:-bootstrap/fw.xml}; F=$(basename "$XML")
K=$(pakey)   # lib.sh, the password from appliances.env in the POST body
op() { curl -sk "https://$PA/api/?type=op&key=$K" --data-urlencode "cmd=$1"; }
echo "import: $(curl -sk "https://$PA/api/?type=import&category=configuration&key=$K" -F "file=@$XML;filename=$F" | grep -o 'status="[a-z]*"')"
DEV="/config/devices/entry[@name='localhost.localdomain']"
for p in network "vsys/entry[@name='vsys1']"; do
  echo "replace $p: $(op "<load><config><partial><mode>replace</mode><from-xpath>$DEV/$p</from-xpath><to-xpath>$DEV/$p</to-xpath><from>$F</from></partial></config></load>" | grep -o 'status="[a-z]*"')"
done
# the hostname only (fw-pa): deviceconfig itself is not replaced (it holds the management settings)
H=$(grep -o '<hostname>[^<]*</hostname>' "$XML" | head -1)
echo "hostname: $(curl -sk "https://$PA/api/?type=config&action=set&key=$K" --data-urlencode "xpath=$DEV/deviceconfig/system" --data-urlencode "element=$H" | grep -o 'status="[a-z]*"')"
./pa-set.sh --commit
