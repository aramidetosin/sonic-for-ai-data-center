#!/bin/bash
# chat-e2e.sh: client-lan1 > PA outside .142/.143 > F5 VIP (WAF) > APISIX (key) > LiteLLM (in the tenant's own cluster) > model.dc.lab (F5 model VIP,
# rd-gpu) > the gpu cluster's models. Each tenant's key is read on its own bastion (namespace platform), passed by environment, never printed.
cd "$(dirname "$0")"; . ./lib.sh
CL=$C-client-lan1
q=$(grep -o '"alias": *"[^"]*"' gen-platform.py | head -1 | cut -d'"' -f4)
for t in $TENANTS; do
  K=$(docker exec $C-bastion-$t oc -n platform get secret inference-api-key -o jsonpath='{.data.key}' | base64 -d)
  for m in lfm2.5-24b $q; do
    body='{"model":"'$m'","max_tokens":48,"messages":[{"role":"user","content":"In one sentence: what does a leaf-spine network do?"}]}'
    r=$(docker exec -e K="$K" -e BODY="$body" $CL sh -c 'curl -sk -m 600 -H "apikey: $K" -H content-type:application/json https://inference.'$t'.dc.lab/models/'$m'/proxy/v1/chat/completions -d "$BODY" -w "\n%{http_code} %{time_total}s"')
    echo "$t $m: $(echo "$r" | tail -1) | $(echo "$r" | head -n -1 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"].strip()[:150].replace("\n"," "), "| tokens", d["usage"]["completion_tokens"])
except Exception as e: print("unparsed:", sys.stdin.read()[:200])' 2>&1)"
  done
  unset K
done
