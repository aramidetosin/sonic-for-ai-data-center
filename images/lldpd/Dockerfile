# c2/lldpd:1: LLDP for the RHCOS nodes of cluster ocp (RHCOS ships no lldpd; NetworkManager only listens). Run as the DaemonSet scd-system/lldpd
# (host network, privileged): it advertises the node name and each physical port (the legs of bond0 / bond1 and the 8 rail NICs) to the switches.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends lldpd && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/usr/sbin/lldpd"]
