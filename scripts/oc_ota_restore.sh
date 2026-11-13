#!/bin/sh
# Buddy 2026-11-13  Run ONCE after mu300-update apply + reboot.
set -e
S=/root/oc_ota_snapshot/openclash-custom.tar.gz
[ -f "$S" ] || { echo "snapshot missing"; exit 1; }
tar xzf "$S" -C /
uci set openclash.config.config_path=/etc/openclash/config/merged.yaml
uci commit openclash
/root/oc_merge_subs.sh --show
/etc/init.d/openclash restart
/root/oc_warm_pass.sh
echo "verify: /etc/init.d/openclash status && nft list set inet fw4 china_ip_route_pass"
