#!/usr/bin/env python3
"""Minimal iControl REST client for the lab's BIG-IPs (stdlib only; from twinsite/lab/scripts).

    bigip_api.py <node> GET  /mgmt/tm/sys/provision
    bigip_api.py <node> POST /mgmt/tm/ltm/monitor/http  '{"name": ...}'
    bigip_api.py <node> PUT|PATCH|DELETE <path> [json]
    bigip_api.py <node> UPLOAD <local-file> <name>      (to /var/config/rest/downloads/<name>)

Credentials come from the lab's secrets file; output masks the admin password and anything shaped
like a registration key. A POST that hits an object which already exists is turned into a PATCH of
that object, so the setup scripts can be re-run.
"""
import base64, json, os, re, ssl, subprocess, sys, urllib.error, urllib.request

SECRETS = os.environ.get("SECRETS_DIR", "/root/scd-secrets")   # <unit>.env, mode 600
LAB = os.environ.get("LAB", "sonic-clos-dc")


def creds(node):
    pw = None
    for line in open(f"{SECRETS}/{node}.env"):
        if line.startswith("PASSWORD="):
            pw = line.split("=", 1)[1].strip()
    ip = subprocess.check_output(["docker", "inspect", "-f",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", f"clab-{LAB}-{node}"], text=True).strip()
    return ip, pw


def mask(text, pw):
    text = re.sub(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){3}-[A-Z0-9]{7}", "<regkey>", text)
    return text.replace(pw, "<password>") if pw else text


def call(node, method, path, body=None, headers=None, raw=None):
    ip, pw = creds(node)
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(f"https://{ip}{path}", data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{pw}".encode()).decode())
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=300) as r:
            return r.status, r.read().decode(errors="replace"), pw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace"), pw


def upload(node, local, name):
    blob = open(local, "rb").read(); size = len(blob); step = 1024 * 1024
    for start in range(0, size, step):
        chunk = blob[start:start + step]
        end = start + len(chunk) - 1
        st, out, pw = call(node, "POST", f"/mgmt/shared/file-transfer/uploads/{name}", raw=chunk,
                           headers={"Content-Type": "application/octet-stream",
                                    "Content-Range": f"{start}-{end}/{size}"})
        if st != 200:
            sys.exit(f"upload failed at {start}: {st} {mask(out, pw)[:300]}")
    print(f"uploaded {name} ({size} bytes)")


def main():
    node, method = sys.argv[1], sys.argv[2].upper()
    if method == "UPLOAD":
        return upload(node, sys.argv[3], sys.argv[4])
    path = sys.argv[3]
    body = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
    st, out, pw = call(node, method, path, body)
    if method == "POST" and st == 409 and body and "name" in body:
        name = body["name"]; part = body.get("partition", "Common")
        st, out, pw = call(node, "PATCH", f"{path}/~{part}~{name}", body)
    print(mask(out, pw))
    if st >= 400:
        sys.exit(f"HTTP {st}")


if __name__ == "__main__":
    main()
