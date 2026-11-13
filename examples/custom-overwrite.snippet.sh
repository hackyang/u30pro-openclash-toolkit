# Buddy 2026-11-13: disable UDP full-cone NAT when not needed (mihomo official).
ruby_edit "$CONFIG_FILE" "['tun']['endpoint-independent-nat']" "false"
exit 0
