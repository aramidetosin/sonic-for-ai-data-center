#!/usr/bin/env python3
"""ontap-shell.py <node> "<cmd>": run one command in the ONTAP simulator's diag system shell of a node (vsim_makedisks needs it).
The diag and cluster admin passwords come from /root/scd-secrets/appliances.env (ONTAP_DIAG_PW, ONTAP_PW; mode 600, never printed)."""
import os, re, shlex, sys, pexpect
env = {k: (shlex.split(v) or [""])[0] for k, v in (l.strip().split("=", 1) for l in open(os.path.join(os.environ.get("SCD_SECRETS", "/root/scd-secrets"), "appliances.env")) if "=" in l and not l.startswith("#"))}   # shell-quoted values
os.environ["SSHPASS"] = env["ONTAP_PW"]   # sshpass -e: the cluster admin password by environment, never on a command line
node, cmd = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
p = pexpect.spawn("sshpass -e ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@172.21.30.41",
                  encoding="utf-8", timeout=120)
p.expect("::>")
if node == "--unlock-diag":   # a fresh simulator: diag is locked with no password. Set the LAB password (appliances.env), then unlock; a no-op when unlocked
    locked = lambda: re.search(r"^diag\s+console\s+password\s+\S+\s+yes\b", p.before, re.M)   # the "Acct Locked" column of the plain table
    p.sendline("security login show -user-or-group-name diag"); p.expect("::>")
    if not locked():
        print("diag: already unlocked"); p.sendline("exit"); sys.exit(0)
    p.sendline("security login password -username diag"); p.expect("[Ee]nter a new password:")
    p.sendline(env["ONTAP_DIAG_PW"]); p.expect("[Ee]nter it again:"); p.sendline(env["ONTAP_DIAG_PW"]); p.expect("::>")
    p.sendline("security login unlock -username diag"); p.expect("::>")
    p.sendline("security login show -user-or-group-name diag"); p.expect("::>")
    ok = not locked(); print("diag: unlocked" if ok else "diag: STILL LOCKED"); p.sendline("exit"); sys.exit(0 if ok else 1)
p.sendline("set -privilege diag -confirmations off"); p.expect(r"\*>")
p.sendline("systemshell -node %s" % node)
if p.expect(["login:", "[Pp]assword:"]) == 0:
    p.sendline("diag"); p.expect("[Pp]assword:")
p.sendline(env["ONTAP_DIAG_PW"]); p.expect(r"%\s*$")
# the system shell is tcsh: run the command under sh (single quotes not allowed in it), then print the exit status the tcsh way
assert "'" not in cmd, "no single quotes in the command"
p.sendline("sh -c '%s'; echo __RC=$status" % cmd); p.expect(r"__RC=(\d+)\r?\n", timeout=3600); out = p.before; rc = int(p.match.group(1))
print("\n".join(out.splitlines()[1:]).strip())
p.expect(r"%\s*$"); p.sendline("exit"); p.expect(r"\*>"); p.sendline("exit")
sys.exit(rc)
