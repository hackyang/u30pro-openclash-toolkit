#!/bin/sh
# Buddy 2026-11-12  Daily node-pool merge.
# Subscription URLs are read from LuCI: 配置订阅 -> 订阅地址 (one URL per line).
# The LuCI record MUST stay DISABLED; this script does the real updating.
# If the record is missing/empty, built-in URLs below are used as fallback.
DEF1='https://example.com/subscription-1'
DEF2='https://example.com/subscription-2?token=REPLACE_ME'
OUT=/etc/openclash/config/merged.yaml
CACHE=/etc/openclash/subscription_cache
LOG=/tmp/oc_merge_subs.log
mkdir -p "$CACHE"

ADDR=$(uci -q get openclash.@config_subscribe[0].address 2>/dev/null)
SRC=uci
if [ -z "$ADDR" ]; then
  ADDR=$(printf '%s\n%s' "$DEF1" "$DEF2")
  SRC=builtin-fallback
fi
printf '%s\n' "$ADDR" | tr -d '\r' | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*#' > /tmp/oc_urls.txt
N=$(wc -l < /tmp/oc_urls.txt)
[ "$N" -ge 1 ] || { echo "[$(date '+%F %T')] no valid URL in LuCI record, abort" >> "$LOG"; exit 1; }

if [ "$1" = "--show" ]; then
  echo "source=$SRC count=$N (query strings hidden)"
  i=0
  while IFS= read -r u; do i=$((i+1)); echo "  $i: ${u%%\?*}"; done < /tmp/oc_urls.txt
  exit 0
fi

echo "[$(date '+%F %T')] === merge check (source=$SRC count=$N) ===" >> "$LOG"
fetch() {
  url="$1"; dst="$2"; cache="$3"
  try=0
  while [ "$try" -lt 2 ]; do
    if curl -s -L --max-time 30 -A 'clash-verge/v2.4.5' "$url" -o "$dst" && [ -s "$dst" ] && grep -q '^proxies:' "$dst"; then
      cp "$dst" "$cache"; return 0
    fi
    try=$((try+1))
    [ "$try" -lt 2 ] && sleep 2
  done
  echo "[$(date '+%F %T')] WARN fetch failed after 2 tries, using cache (source $dst)" >> "$LOG"
  [ -s "$cache" ] && cp "$cache" "$dst" && return 0
  return 1
}
i=0; FILES=""
while IFS= read -r url; do
  i=$((i+1)); dst="/tmp/oc_src_$i.yaml"; cache="$CACHE/sub$i.yaml"
  fetch "$url" "$dst" "$cache" || { echo "source $i unavailable, abort" >> "$LOG"; exit 1; }
  FILES="$FILES $dst"
done < /tmp/oc_urls.txt

NEW=/tmp/oc_merge_new.yaml
ruby /root/oc_merge.rb $FILES "$NEW" >> "$LOG" 2>&1 || { echo 'merge failed, abort' >> "$LOG"; exit 1; }
[ -s "$NEW" ] || { echo 'empty output, abort' >> "$LOG"; exit 1; }
SIG=$(cat "$NEW.sig" 2>/dev/null); LAST=$(cat "$CACHE/last.sig" 2>/dev/null)
if [ -f "$OUT" ] && [ -n "$SIG" ] && [ "$SIG" = "$LAST" ]; then
  echo "[$(date '+%F %T')] node pool unchanged, skip restart" >> "$LOG"
  rm -f "$NEW" "$NEW.sig"; exit 0
fi
mv "$NEW" "$OUT"; echo "$SIG" > "$CACHE/last.sig"; rm -f "$NEW.sig"
uci set openclash.config.config_path="$OUT"; uci commit openclash
/etc/init.d/openclash restart >> "$LOG" 2>&1
# Warm up china_ip_route_pass: dnsmasq only populates the nftset when a listed domain is resolved.
for h in services.googleapis.cn googleapis.cn www.googleapis.cn xn--ngstr-lra8j.com connectivitycheck.gstatic.com; do
  nslookup "$h" >/dev/null 2>&1
done
echo "[$(date '+%F %T')] === pass-set warmup done ===" >> "$LOG"
echo "[$(date '+%F %T')] === node pool updated, OpenClash restarted ===" >> "$LOG"
exit 0