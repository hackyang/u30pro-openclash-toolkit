# 00 · 架构与最终状态

## 设备画像

| 项 | 实测 |
|---|---|
| 硬件 | Unisoc UMS9632，8× ARMv8 @ 2.04 GHz，1.5 GB RAM，7.8 GB eMMC |
| 系统 | OpenWrt 25.12.5，kernel 6.12.94-u30pro；**rootfs 是 ext4 直挂，不是 overlay** |
| 包管理器 | `apk` 3.0.5（`opkg` 已移除） |
| WAN | `sipa_eth0` / `mu300cell` 蜂窝，`10.100.253.228/8`（CGNAT，无公网 IPv4） |
| LAN | `br-lan` `192.168.77.1/24` = `usb0` + `wlan0` 5 GHz AP |
| 负载 | load 0.29，可用内存 1.26 GB → **任何「省 CPU / 省内存」优化收益为零** |
| 升级 | `mu300-update apply` 目录切换（`openwrt` ↔ `openwrt.new`），不是 `sysupgrade` |

## 数据流

```
客户端 (WiFi/USB)
   ↓ DNS 查询
dnsmasq (劫持) → Clash DNS 7874 → fake-ip / nameserver-policy
   ↓ 连接
fw4 nft：china_ip_route 判定 → 命中中国 IP 直接 return（优先于 Clash 规则）
   ↓ 未命中
TUN (stack: system) → mihomo 规则匹配
   ├─ RuleSet(google) / overseas-ai / tiktok → 节点选择（url-test）
   ├─ RuleSet(cn) / apple-cn / cn-ip         → DIRECT
   └─ MATCH                                  → 节点选择
```

**关键点**：`china_ip_route=1` 在 nft 层工作，优先级高于 Clash 规则。解析到国内 CDN 的境外服务域名（如 `services.googleapis.cn`）会被硬直连，必须在 `china_ip_route_pass` 里加例外。

## 最终配置

| 类别 | 项 | 值 |
|---|---|---|
| 分流 | `proxy_mode` | `rule` |
| DNS | 模式 | fake-ip-mix / `respect-rules: true` + `proxy-server-nameserver`、`prefer-h3: false` |
| DNS | 上游 | 境外 DoH；国内 DoH 仅用于 `nameserver-policy` 的 cn 分流 |
| 节点 | 池 | 46 个（两订阅合并后过滤伪节点），`节点选择 = 自动选择`（不固定） |
| 健康检查 | url-test | `https://cp.cloudflare.com/generate_204` / interval 120 / timeout 5000 / `lazy: false` / expected-status 204 |
| 防火墙 | `flow_offloading` | `0`（关软件流量分载，避免 flowtable 旁路 mangle 规则） |
| 防火墙 | QUIC | `OpenClash QUIC REJECT` ×2，强制 UDP 443 回退 TCP（必须 REJECT 不能 DROP） |
| 防火墙 | `china_ip_route_pass` | 域名 + 静态 IP 例外；**运行时 nft set，重启/reload 后需预热** |
| TUN | `endpoint-independent-nat` | `false`（官方：不需要时建议关） |
| IPv6 | `ra` / `dhcpv6` / `ndp` | 全 `disabled`（否则 v6 绕过 Clash） |
| 覆写 | `Google_Play` | 启用 |
| 系统 | `chnr_auto_update` / `store_fakeip` | `1` / `1` |
| 系统 | `enable_meta_sniffer_pure_ip` | `0` |
| 系统 | `country` / `log_size` / `urandom_seed` | `CN` / `512` / `1` |

## 定时任务

```
5 0 * * * /root/oc_merge_subs.sh                              # 每日节点池合并
0 0 * * 1 /usr/share/openclash/openclash.sh                   # OpenClash 周任务
0 0 * * 1 /usr/share/openclash/openclash_chnroute.sh          # 大陆 IP 列表更新
```

`00:05` 而非 `00:00`：避开周一三条任务同秒触发。

## 升级保留边界

`keep_list()` 白名单只有 8 项：

```
etc/config etc/mu300 etc/unisoc-modem etc/dropbear
etc/rc.local etc/crontabs root
```

| 保留 | 丢失 |
|---|---|
| `/root/oc_*.sh`、`oc_merge.rb`、`oc_backup_*/` | `/etc/openclash/` **整个目录** |
| `/etc/crontabs/root`（cron） | `merged.yaml`、订阅缓存、`custom/`、`overwrite/` |
| `/etc/config/openclash`（订阅记录 + 开关） | 运行时 `china_ip_route_pass` 集合 |

## 别动清单

- `stack: system`、`auto-route / strict-route / auto-detect-interface / auto-redirect` 全 false —— OpenClash 自管 nft 规则，照抄通用 mihomo 模板会冲突。
- `respect-rules` + `proxy-server-nameserver` + `prefer-h3: false` —— 官方要求，别「优化」坏。
- `gso` / `tcp-concurrent` / `unified-delay` / `sniffer` / `fake-ip-filter` / 健康检查参数 —— 已验证有效。
- packet steering / irqbalance / conntrack / rmem / wmem / sysctl 全家桶 —— 8 核无瓶颈，厂商已调优。
- `sipa_eth: fail to send -115`、`aicwf_sdio debugfs` —— 展锐闭源驱动行为，只有换固件。
- **严禁 `apk upgrade`**（会破坏 hostapd / wpad 依赖，可能变砖）。

## 基线检查

```sh
/etc/init.d/openclash status
/root/oc_merge_subs.sh --show
crontab -l | grep oc_merge
nft list set inet fw4 china_ip_route_pass
nft list ruleset | grep -c 'flow add'          # 期望 0
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack   # 期望 0
curl -s --max-time 10 -x http://<user>:<pwd>@127.0.0.1:7890 \
  -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204   # 204
```

分流回归：`www.google.com → RuleSet(google) → 代理`、`www.baidu.com → RuleSet(cn) → DIRECT`。
