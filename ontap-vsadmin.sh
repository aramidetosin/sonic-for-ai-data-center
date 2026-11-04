#!/bin/bash
# ontap-vsadmin.sh: the vsadmin account of every SVM in ontap.env (svm-prod, svm-dev, svm-gpu) gets the lab's vsadmin password and is unlocked
# (Trident logs in with it on the SVM management LIF). the password comes from appliances.env (ONTAP_VSADMIN_PW); the REST
# credentials reach curl on stdin (-K -), the JSON body through a file descriptor; neither is on a command line or printed.
cd "$(dirname "$0")"; . ./lib.sh; . ./ontap.env
[ -n "${ONTAP_VSADMIN_PW:-}" ] || { say "ONTAP_VSADMIN_PW missing (appliances.env)"; exit 1; }
for cl in $SVMS; do v=SVM_$cl; read -r SVM _r <<<"${!v}"
  uuid=$(ontap_rest GET "/svm/svms?name=$SVM" | python3 -c "import sys,json; r=json.load(sys.stdin).get('records',[]); print(r[0]['uuid'] if r else '')")
  [ -n "$uuid" ] || { say "vsadmin $SVM: no such SVM"; continue; }
  # the password (an unchanged one answers 400 "must be different": it is already set), then the lock, each judged on its own
  pw=$(ontap_rest PATCH "/security/accounts/$uuid/vsadmin" -H 'Content-Type: application/json' \
         --data-binary @<(python3 -c 'import json,os; print(json.dumps({"password": os.environ["ONTAP_VSADMIN_PW"]}))') \
       | python3 -c 'import sys,json; t=sys.stdin.read().strip(); d=json.loads(t) if t else {}; m=d.get("error",{}).get("message",""); print("set" if not m else ("already set" if "must be different" in m else "ERROR " + m))')
  lk=$(ontap_rest PATCH "/security/accounts/$uuid/vsadmin" -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}' --data-binary '{"locked": false}')
  say "vsadmin $SVM: password $pw, unlock HTTP $lk"
done
