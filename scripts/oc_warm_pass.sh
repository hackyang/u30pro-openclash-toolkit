#!/bin/sh
# Buddy 2026-11-13  Re-populate china_ip_route_pass after firewall reload / OTA restore.
for h in services.googleapis.cn googleapis.cn www.googleapis.cn xn--ngstr-lra8j.com connectivitycheck.gstatic.com; do
  nslookup "$h" >/dev/null 2>&1
done
