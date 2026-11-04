# gen-chrony.py (run from the lab root: python3 manifests-ocp/gen-chrony.py): writes the day-1 MachineConfigs manifests/99-<role>-scd-chrony.yaml
# (JSON = valid YAML, copied into the agent ISO by make-iso.sh) and the chrony disruption policy (platform.sh chrony patches it in)
import base64, json
conf = """# the nodes take time only from the lab's two NTP servers in Vrf-Svc (dns-ntp1, dns-ntp2); the RHCOS default public pool is removed
server 10.250.0.11 iburst
server 10.250.0.12 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
"""
src = "data:text/plain;charset=utf-8;base64," + base64.b64encode(conf.encode()).decode()
for role in ("master", "worker"):
    mc = {"apiVersion": "machineconfiguration.openshift.io/v1", "kind": "MachineConfig",
          "metadata": {"name": "99-%s-scd-chrony" % role, "labels": {"machineconfiguration.openshift.io/role": role}},
          "spec": {"config": {"ignition": {"version": "3.4.0"},
                   "storage": {"files": [{"path": "/etc/chrony.conf", "mode": 420, "overwrite": True, "contents": {"source": src}}]}}}}
    open("manifests/99-%s-scd-chrony.yaml" % role, "w").write(json.dumps(mc, indent=1))
pol = {"spec": {"nodeDisruptionPolicy": {"files": [{"path": "/etc/chrony.conf", "actions": [{"type": "Restart", "restart": {"serviceName": "chronyd.service"}}]}]}}}
open("manifests-ocp/machineconfiguration-chrony-policy.json", "w").write(json.dumps(pol, indent=1))
print("written")
