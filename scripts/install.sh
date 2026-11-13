#!/bin/sh
# Idempotent deploy: copy scripts to /root, set perms, add cron.
# Does NOT touch running config, does NOT restart OpenClash.
set -e
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[ -f /etc/openwrt_release ] || { echo "ERROR: run this on the OpenWrt device"; exit 1; }
for c in ruby uci crontab curl nslookup nft; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c"; exit 1; }
done

for f in oc_merge_subs.sh oc_merge.rb oc_clean_nodes.sh oc_warm_pass.sh oc_ota_restore.sh; do
    [ -f "$SRC/$f" ] || { echo "ERROR: missing $SRC/$f"; exit 1; }
    cp "$SRC/$f" "/root/$f"
done
chmod 700 /root/oc_merge_subs.sh /root/oc_clean_nodes.sh \
          /root/oc_warm_pass.sh /root/oc_ota_restore.sh
chmod 644 /root/oc_merge.rb
echo "scripts installed to /root"

# The LuCI record stores subscription URLs. Never create it automatically
# (it contains tokens) and never enable it.
ADDR=$(uci -q get openclash.@config_subscribe[0].address 2>/dev/null || true)
if [ -z "$ADDR" ]; then
    echo "WARN: no LuCI subscribe record found."
    echo "      Create ONE record with one URL per line, keep it DISABLED."
    echo "      The merge script falls back to placeholder URLs until then."
else
    EN=$(uci -q get openclash.@config_subscribe[0].enabled 2>/dev/null || echo "?")
    [ "$EN" = "0" ] || echo "WARN: subscribe record enabled=$EN -> set to 0 (must stay disabled)"
    echo "subscribe record found (enabled=$EN)"
fi

if crontab -l 2>/dev/null | grep -q 'oc_merge_subs.sh'; then
    echo "cron entry already present"
else
    (crontab -l 2>/dev/null || true; echo '5 0 * * * /root/oc_merge_subs.sh') | crontab -
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    echo "cron added: 5 0 * * * /root/oc_merge_subs.sh"
fi

cat <<'EOF'

Next steps:
  /root/oc_merge_subs.sh --show     # verify URLs (query strings hidden)
  /root/oc_merge_subs.sh            # first merge -> generates merged.yaml
  uci set openclash.config.config_path=/etc/openclash/config/merged.yaml
  uci commit openclash
  /etc/init.d/openclash restart
  /root/oc_warm_pass.sh             # re-populate china_ip_route_pass

EOF
