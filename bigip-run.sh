#!/usr/bin/env bash
# Run a bash command on a BIG-IP through iControl REST and print its output with every
# registration-key-shaped string and the admin password masked.
#   ./bigip-run.sh lb-f5a "tmsh show sys license"
set -euo pipefail
b=$1; shift
SECRETS=${SECRETS_DIR:-/root/scd-secrets}
pw=$(sed -n 's/^PASSWORD=//p' "$SECRETS/$b.env")
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "clab-${LAB:-sonic-clos-dc}-$b")
body=$(python3 -I -c 'import json,sys; print(json.dumps({"command":"run","utilCmdArgs":"-c " + json.dumps(sys.argv[1])}))' "$*")
curl -sk --max-time "${TIMEOUT:-120}" -u "admin:$pw" -H 'Content-Type: application/json' -X POST -d "$body" \
  "https://$ip/mgmt/tm/util/bash" \
  | python3 -I -c '
import json, re, sys
pw = sys.argv[1]
raw = sys.stdin.read()
try:
    out = json.loads(raw).get("commandResult", "")
except ValueError:
    out = "REST error: " + raw[:300]
out = re.sub(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}", "<regkey>", out)
print(out.replace(pw, "<password>"), end="")' "$pw"
