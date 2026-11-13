# U30 Pro / OpenWrt + OpenClash 深度优化方案（第二轮）

> 调研时间：2026-11-13 09:27–09:40　设备：U30 Pro / OpenWrt 25.12.5 / mihomo 1.19.34
> 方法：实机 3 轮采集（uci / sysctl / nft / conntrack / API / 日志 / apk 索引）＋ 官方文档 + 社区交叉验证。
> 本文为调研记录；最终执行版见 docs/03。 插件清单见 `U30Pro-Optimization-Plan.md`，本文不重复。

---

## 1. 调研来源与可信度

| 来源 | 用于确认 | 采信 |
|---|---|---|
| mihomo 官方 docs `/en/config/inbound/tun/` | TUN stack、GSO、endpoint-independent-nat、auto-route 依赖、防火墙冲突 | ✅ 官方 |
| mihomo 官方 docs `/en/config/dns/` | respect-rules 依赖、nameserver-policy 优先级、fallback **不是**超时切换、default-nameserver 必须是 IP | ✅ 官方 |
| OpenWrt 官方 SQM 文档 / 论坛 25.12.6 帖 | packet steering 默认值取舍、cake-mq（25.12 起 WIP）、fq_codel 在 CPU 受限时吞吐高约 15% | ✅ 官方/开发者 |
| nftables flowtable 原理（多篇一致） | ingress hook 短路 PREROUTING→FORWARD→POSTROUTING，已建立连接绕过 netfilter 钩子链 | ✅ 机制一致 |
| 华为云社区「OpenWrt 防火墙优化」 | 明确警告：开启 Flow Offloading 会让部分流量绕过 OpenClash 等 DPI 插件 | ✅ 与本例吻合 |
| `33333s/u30pro-store` README | 设备专用包、内核 ABI 约束（上一轮已用） | ✅ 已签名源 |
| 中文 SEO 站 / 微信营销号「一键优化脚本」 | — | ❌ 剔除：夹带 `allow-left:tru` 等错误语法、全端口 sniff、MTU 9000 等不适用建议 |

---

## 2. 实机基线

| 项 | 值 |
|---|---|
| 运行时长 | 22 h 08 m，load 0.04，可用内存 1.26 GB，温度 **最高 60.4 °C**（modem/充电区） |
| 定时任务 | `0 0 * * 1` 两条 OpenClash 任务 + `5 0 * * *` 合并脚本；**今天 00:05 已验证跑通**（`skip restart`，两订阅缓存都已刷新） |
| mihomo | v1.19.34 `with_gvisor`；TUN `stack: system`、`gso: true`、`endpoint-independent-nat: true`、`auto-route/auto-detect-interface/strict-route/auto-redirect` 全 false |
| DNS | `respect-rules: true` + `prefer-h3: false` + `proxy-server-nameserver` 已配；`default-nameserver` 为纯 IP；`nameserver-policy` 分流 cn |
| **软件流量分载** | `firewall.@defaults[0].flow_offloading='1'`，fw4 有 `flowtable ft { hook ingress; devices=sipa_eth0,usb0,wlan0 }`，**conntrack 中 53 条 `[OFFLOAD] mark=0`** |
| **DNS 上游超时** | 08:31–08:32 集中 **82 条** `dial DIRECT (match RuleSet/cn) mihomo --> 223.5.5.5:443 / 120.53.53.53:443 / 223.6.6.6:443 / 1.12.12.12:443 i/o timeout` |
| 内核网络 | cc=`cubic`（**BBR 可用**：`reno bbr cubic`）、`tcp_fastopen=1`、`tcp_ecn=2`、conntrack `350/65536`、rmem/wmem 默认 212992 |
| CPU/收包 | 8 核 schedutil；`br-lan rps=00`、`wlan0=04`、`sipa_eth0=01`；`S25packet_steering` 在跑 |
| apk | **90 个可升级包**；`luci` 同时有 `26.298` 与 `26.312` 两个候选（三源混装实证） |
| 持久化 | `/etc/sysupgrade.conf` 仍为空，`/etc/mu300/user-packages/wanted` 仍为空（上轮 P0 未落地） |

---

## 3. 新发现与判断

### 3.1 软件流量分载与 OpenClash 分流存在结构性冲突（新，P0）

- `forward` 链里 `meta l4proto { tcp, udp } flow add @ft` **无差别**把连接加入 flowtable（未限定 established）。
- flowtable 在 **ingress hook** 生效，命中后直接做 MAC/TTL/NAT 重写并旁路整个 netfilter 钩子链；已 offload 的连接不再经过 `openclash_mangle` 的 `china_ip_route` / mark 判定。
- 实测 53 条 `[OFFLOAD] mark=0`（都是未打 0x162 标记的**国内直连**流），说明当前被加速的确实是直连流量，不是代理流量——**目前没有证据表明已造成泄露**。
- 但风险明确：连接首包判定后就固定路径。HTTP/2 长连接复用、CDN 同 IP 多域名、QUIC 连接迁移时，后续请求可能不再按域名规则重新判定。社区文档也明确警告 Flow Offloading 会绕过 OpenClash 这类 DPI 插件。
- 本机 8 核 / load 0.04，**完全不需要这点转发加速**。关闭的收益是消除上述不确定性，代价只是国内直连多走几次 netfilter 规则。

**结论：建议关闭，属预防性加固，不是修已发生的故障。**

### 3.2 DNS 上游集体超时是链路层问题，配置层无法根治（新，观察项）

- 82 条集中在同一分钟，目标全是国内 DoH 的多个 IP（223.5.5.5、120.53.53.53、223.6.6.6、1.12.12.12），与 `sipa_eth: fail to send, ret -115` 的 modem 唤醒时间吻合 → 蜂窝链路瞬断。
- 官方 DNS 文档明确：**`fallback` 是"备份解析服务器 + 污染判定"，不是超时自动切换机制**，文档里没有超时阈值/重试/健康检查配置项。所以"加个 fallback 就能解决超时"是错的。
- 当前 DNS 结构本身合规：`respect-rules` 配了 `proxy-server-nameserver`、`prefer-h3: false`（官方强烈不建议两者同开）、`default-nameserver` 是纯 IP、`nameserver-policy` 优先于 `nameserver` —— **这些别动**。

**结论：只做轻量冗余加固，不做大改；根因在固件/驱动。**

### 3.3 有官方依据的小项

- `endpoint-independent-nat: true`：官方原文 *"Performance might drop slightly, so it is not recommended to enable it when not needed"*。本机 QUIC 已被 `OpenClash QUIC REJECT` 强制回退 TCP，UDP 全锥 NAT 收益很低 → **可关**。
- `stack: system`：官方推荐 `mips`（默认），且 `system/mixed` 在桌面防火墙开启时不可用；但本机 Linux + fw4 下 system 已稳定运行 22 h、Play 下载正常，且 OpenClash 的 `fake-ip-mix` 用自管 nft 规则接管。**切换 stack 属实验项，不建议为"跟官方默认"而改**。
- `auto-route/auto-detect-interface/strict-route/auto-redirect` 全 false：这是 OpenClash 的设计（它自己写 nft 规则），**照抄通用 mihomo 模板去开启会冲突**。
- BBR：内核已编译可用，当前 `cubic`。只影响**本机发起的 TCP**（mihomo→节点、订阅拉取），对转发流量无效；`tun.congestion-controller` 仅在 `mips` 栈生效，别混淆。

### 3.4 明确不要动

| 项 | 依据 |
|---|---|
| packet steering / irqbalance | OpenWrt 开发者：默认单 CPU 转向足够，`all CPUs` 变体可能浪费 10–20% 周期；8 核 load 0.04 无瓶颈 |
| conntrack_max / rmem / wmem / sysctl 全家桶 | count 350/65536，资源充裕，通用"一键优化脚本"不适用本机 |
| `respect-rules` / `prefer-h3` / `proxy-server-nameserver` / `nameserver-policy` | 官方要求，当前配置正确 |
| `gso` / `tcp-concurrent` / `unified-delay` / `sniffer` / `fake-ip-filter` | 已验证有效，上轮已调优 |
| 健康检查 HTTPS / interval 120 / lazy false | 上轮修复，alive 30→40，警告归零 |
| `sipa_eth -115`、`aicwf_sdio debugfs` | 展锐闭源驱动行为，只有换固件 |

---

## 4. 执行方案（按优先级）

### P0-1　配置持久化（上轮 P0，仍未做，最高优先）

```sh
cat >> /etc/sysupgrade.conf <<'EOF'
/root/oc_merge_subs.sh
/root/oc_merge.rb
/root/oc_clean_nodes.sh
/etc/openclash/config/merged.yaml
/etc/openclash/subscription_cache/
/etc/openclash/custom/
/etc/openclash/overwrite/
/etc/config/openclash
/etc/config/firewall
/etc/config/dhcp
/etc/crontabs/root
EOF

tar czf /mnt/mu300-disk/u30pro-config-backup.tar.gz \
  /etc/config /etc/crontabs /etc/apk/world /etc/apk/repositories.d \
  /root/oc_merge_subs.sh /root/oc_merge.rb /root/oc_clean_nodes.sh \
  /etc/openclash/config /etc/openclash/custom /etc/openclash/overwrite \
  /etc/openclash/subscription_cache /etc/sysupgrade.conf
```

> 取一份 tar 到电脑。A/B OTA 可能整包替换 system 分区，`sysupgrade.conf` 未必生效。

### P0-2　关闭软件流量分载

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci commit firewall
/etc/init.d/firewall reload
/etc/init.d/openclash restart        # 让 OpenClash 重新插入 fw4 规则
```

验证：

```sh
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack     # 应逐步归零
nft list ruleset | grep -c 'flow add'            # 应为 0
/etc/init.d/openclash status                     # running
nft list ruleset | grep -c 'OpenClash QUIC REJECT'   # 2
curl -s --max-time 10 -x http://Clash:<pwd>@127.0.0.1:7890 \
  -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204   # 204
```

> 回滚：`uci set firewall.@defaults[0].flow_offloading='1' && uci commit firewall && /etc/init.d/firewall reload && /etc/init.d/openclash restart`。

### P0-3　软件源治理

```sh
apk list -U | grep -c upgradable        # 当前 90
apk add --simulate luci-app-<name>      # 装任何包前先看依赖解析
```

- **严禁 `apk upgrade`**（官方警告破坏 hostapd/wpad/ucode-mod 依赖，可能变砖）。
- `luci` 有两个候选版本 → 不要单独升级 LuCI；要升就走官方 OTA / `owut` 整包。
- 装包后把包名写入 `/etc/mu300/user-packages/wanted`，靠 `S99mu300-user-packages` 在 OTA 后自动重装。
- 可选镜像加速：`sed -i 's|downloads.openwrt.org|mirrors.ustc.edu.cn/openwrt|g' /etc/apk/repositories.d/distfeeds.list`（USTC 有 25.12 完整镜像；U30Pro feed 走 GitHub raw，失败时另配代理）。

### P1-1　关闭 endpoint-independent-nat（用自定义覆写固化，避免每天重建覆盖）

在 `/etc/openclash/custom/openclash_custom_overwrite.sh` 的 `exit 0` 前加：

```sh
ruby_edit "$CONFIG_FILE" "['tun']['endpoint-independent-nat']" "false"
```

然后 `/etc/init.d/openclash restart`，用 `/configs` API 确认 `endpoint-independent-nat: false`。

### P1-2　DNS 轻量冗余（缓解，不根治）

在合并脚本生成的覆写里给 `direct-nameserver` 补第三个异构上游（不同运营商），例如 `https://dns.alidns.com/dns-query` 之外再加一个；**不要**加 `fallback` 来"解决超时"（官方定义不符）。其余 DNS 结构保持不变。

> 预期效果：链路瞬断时多一个候选；82 条超时仍可能出现。若持续复现，优先查 modem/固件而非 Clash 配置。

### P1-3　BBR（可选，收益有限）

```sh
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-u30pro.conf <<'EOF'
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF
sysctl -p /etc/sysctl.d/99-u30pro.conf
sysctl -n net.ipv4.tcp_congestion_control    # bbr
```

> 只改善本机发起的 TCP；若日后启用 `luci-app-u30pro-qos`（cake），重新评估 `default_qdisc`。

### P1-4　沿用上轮 P1（仍未落地）

| 命令 | 作用 |
|---|---|
| `uci set wireless.radio0.country='CN'; uci commit wireless; wifi reload` | 合规 + 邻居兼容，当前 36/40/44/48 在 CN 下仍可用 |
| `uci set system.@system[0].log_size=512; uci commit system` | 128 KB 太小，驱动报错就占满 |
| `uci set system.@system[0].urandom_seed=1; uci commit system` | 保存随机种子 |

### P2　观察 / 可选

- 温度最高 60.4 °C → 装 `u30pro-screen-thermal`（上轮第二档）在机身屏幕直接看。
- `find-process-mode: strict` → `off`（规则里无 PROCESS-NAME），收益极小，可顺手做，需用覆写固化。
- `apk -U add luci-app-u30pro-qos luci-app-ttl`（上轮第一档）仍未安装；开启 cake 会产生蜂窝探测流量。

---

## 5. 验证清单（每次改动后）

```sh
/etc/init.d/openclash status
/root/oc_merge_subs.sh --show
crontab -l | grep oc_merge
nft list set inet fw4 china_ip_route_pass
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack
grep -c 'level=\(warning\|error\)' /tmp/openclash.log
logread | grep -c 'sipa_eth: fail to send'
```

分流回归：`www.google.com → RuleSet(google) → 代理`、`223.5.5.5/www.baidu.com → RuleSet(cn) → DIRECT`；Play 下载复测一次。

---

## 6. 风险提醒

- **最高风险仍是 OTA 丢配置**：`sysupgrade.conf` 空 + `wanted` 空 + ext4 直挂 + A/B 分区 + 90 个可升级包。先备份、取到设备外。
- 关 flow offload 后须**重启 OpenClash**让其重新插 nft 规则，否则可能出现规则缺失；改完按第 5 节逐项验证。
- `endpoint-independent-nat` 关闭后，若有游戏/P2P 依赖 UDP 全锥 NAT，可能受影响 → 观察后再定。
- BBR / `default_qdisc=fq` 与将来启用的 cake/cake-mq 需重新评估。
- **不要照抄通用 mihomo 模板**：`auto-route/strict-route/auto-redirect: true`、`stack: mips`、全端口 sniffer、MTU 9000 在这台 OpenClash 混合模式设备上都不适用。
- 官方明确：`fallback` 不是超时切换机制；`respect-rules` 必须配 `proxy-server-nameserver` 且不要与 `prefer-h3` 同开——当前配置正确，别"优化"坏。
