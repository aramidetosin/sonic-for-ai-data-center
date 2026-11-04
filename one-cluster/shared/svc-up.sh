#!/bin/bash
# svc-up.sh: Vrf-Svc service node: BIND9 authoritative for dc.lab (dns-ntp1 primary, dns-ntp2 secondary by zone transfer) and a
# forwarder for everything else; chrony NTP server for every VRF. Zone: /shared/dc.lab.zone (gen.py). env ROLE primary|secondary
set -e
mkdir -p /etc/bind /var/bind /run/named; chown -R named:named /var/bind /run/named 2>/dev/null || true
if [ "$ROLE" = primary ]; then
  sed "s/SERIAL/$(date +%s)/" /shared/dc.lab.zone > /var/bind/dc.lab.zone
  Z='zone "dc.lab" { type master; file "/var/bind/dc.lab.zone"; allow-transfer { 10.250.0.12; }; also-notify { 10.250.0.12; }; };'
else
  Z='zone "dc.lab" { type slave; masters { 10.250.0.11; }; file "/var/bind/dc.lab.zone"; };'
fi
cat > /etc/bind/named.conf <<C
options {
  directory "/var/bind"; listen-on { any; }; listen-on-v6 { none; };
  // tenants arrive source-NATed by the PA-VM (10.254.14.3 / 10.254.24.3); Vrf-Mgmt and Vrf-Svc directly
  allow-query { 10.0.0.0/8; 172.16.0.0/12; 127.0.0.1; }; recursion yes; allow-recursion { 10.0.0.0/8; 172.16.0.0/12; 127.0.0.1; };
  forwarders { 8.8.8.8; 1.1.1.1; }; forward only; dnssec-validation no;
};
$Z
C
chown -R named:named /var/bind
named-checkconf; pkill named 2>/dev/null || true; named -u named -c /etc/bind/named.conf
printf 'pool pool.ntp.org iburst\nallow 10.0.0.0/8\nallow 172.16.0.0/12\nlocal stratum 8\n' > /etc/chrony/chrony.conf
pkill chronyd 2>/dev/null || true; chronyd -f /etc/chrony/chrony.conf
echo "$(hostname): named ($ROLE) + chronyd up"
