# U30 Pro / OpenWrt + OpenClash 最终优化调整方案

> **唯一执行版**　定稿：2026-11-13 09:53（实机只读复核）
> 设备：中兴 U30 Pro，第三方固件 `dikeckaan/mu300-linux`（`u30pro-r20261110.125401-g8f1b7ced`），OpenWrt 25.12.5 / mihomo 1.19.34 / OpenClash 0.48.002
> **本文件是唯一执行版**；docs/ 下其他文档按调研时间排列，编号不一致时以本文件为准。
> 本文基于 2026-11-13 实机复核；执行结果见仓库 README 与 CHANGELOG。

---

## 0. 方案总览

最终方案只有 5 步，按顺序执行；其余配置项保持不动。

| # | 动作 | 影响 |
|---|---|---|
| 1 | OTA 配置保全：tar 快照 + 恢复脚本 + 取一份到设备外 | 无 |
| 2 | 关闭软件流量分载 | 短暂，`sleep 10` 后 fw4 自动重插规则 |
| 3 | 关闭 `endpoint-independent-nat`（自定义覆写固化） | OpenClash 重启约 9 秒 |
| 4 | `country` / `log_size` / `urandom_seed` 三个 uci 微调 | WiFi 闪断几秒 |
| 5 | 软件源治理纪律：装包前 `--simulate`、严禁 `apk upgrade` | 无 |

可选（P2，收益有限）：BBR、DNS 异构上游、`find-process-mode`、设备专用插件。

---

## 1. 实机状态（2026-11-13 09:53 复核）

### 已落地，别重复做 / 别动

| 项 | 值 |
|---|---|
| OpenClash | `running`，`config_path=/etc/openclash/config/merged.yaml`，46 节点 |
| 订阅合并 | cron `5 0 * * *`；00:05 实跑 `source=uci count=2`、`merged_nodes=46`、`skip restart` |
| LuCI 订阅记录 | `enabled=0`（必须保持未启用），链接从它读取 |
| url-test 健康检查 | HTTPS / interval 120 / timeout 5000 / lazy false（固化在 `oc_merge.rb`） |
| DNS / 分流 | `respect-rules` + `proxy-server-nameserver`、`prefer-h3:false`、fake-ip、`proxy_mode=rule` |
| Google Play 链路 | `GP_overwrite=1`、`china_ip_route_pass` 现有 **8 个 IP**、QUIC REJECT ×2、RA/DHCPv6/NDP 关闭 |
| 上轮优化 | `chnr_auto_update=1`、`store_fakeip=1`、`enable_meta_sniffer_pure_ip=0` |
| 例外集合预热 | 已写进合并脚本，重启后自动 nslookup 触发 nftset 填充 |
| 备份 | `/root/oc_backup_20261112/`（在 OTA 白名单内） |

### 待执行（复核确认全部仍是原值）

| 项 | 当前值 |
|---|---|
| `firewall.@defaults[0].flow_offloading` | **1**（`flow add` 规则 1 条，conntrack `[OFFLOAD]` **36 条**） |
| `tun.endpoint-independent-nat` | **true** |
| `wireless.radio0.country` | **TR** |
| `system.log_size` | **128** KB |
| `system.urandom_seed` | **0** |
| `tcp_congestion_control` | **cubic** |
| `/root/oc_ota_snapshot/`、`/root/oc_ota_restore.sh` | **不存在** |
| `/etc/sysupgrade.conf` 有效条目、`/etc/mu300/user-packages/wanted` | **均为空** |
| apk 可升级包 | **90 个** |

---

## 2. 三条硬约束（决定方案边界）

1. **这套固件不读 `/etc/sysupgrade.conf`**。升级走 `mu300-update apply`（目录切换 `openwrt` ↔ `openwrt.new`），保留靠脚本第 187–190 行写死的 8 项白名单：`etc/config etc/mu300 etc/unisoc-modem etc/dropbear etc/rc.local etc/crontabs root`。**`/etc/openclash/` 不在其中** → 前两份方案里"写 sysupgrade.conf"的动作作废。
2. **关 flow offload 不用手动重插 nft 规则**。OpenClash 注册了 fw4 include `/var/etc/openclash.include` → `firewall reload` 自动触发 `openclash reload "firewall"`，带 5 s 延迟 + 10 次/5 min 防抖。第二份方案里"必须重启 OpenClash"作废，只在规则没回来时补一次。
3. **包管理器是 `apk` 3.0.5，不是 opkg**；三源混装（官方 25.12.5 + ImmortalWrt 25.12.2 + U30Pro 商店），LuCI 组件版本分裂。**严禁 `apk upgrade`**（会破坏 hostapd/wpad 依赖，可能变砖）。

---

## 3. 最终执行方案（统一编号）

### P0　必须做（2 项，按顺序）

#### P0-1　OTA 配置保全

```sh
mkdir -p /root/oc_ota_snapshot
tar czf /root/oc_ota_snapshot/openclash-custom.tar.gz \
  /etc/openclash/config /etc/openclash/custom \
  /etc/openclash/overwrite /etc/openclash/subscription_cache \
  /etc/apk/world /etc/apk/repositories.d \
  /etc/config /etc/crontabs /etc/rc.local
cp /root/oc_ota_snapshot/openclash-custom.tar.gz /mnt/mu300-disk/
```

**然后把这份 tar 取到电脑**（`scp root@192.168.77.1:/root/oc_ota_snapshot/openclash-custom.tar.gz .`）。这是设备外唯一保险。

写 `/root/oc_ota_restore.sh`（`chmod 700`）：

```sh
#!/bin/sh
# Run once after mu300-update apply + reboot.
set -e
S=/root/oc_ota_snapshot/openclash-custom.tar.gz
[ -f "$S" ] || { echo "snapshot missing"; exit 1; }
tar xzf "$S" -C /
uci set openclash.config.config_path=/etc/openclash/config/merged.yaml
uci commit openclash
/root/oc_merge_subs.sh --show
/etc/init.d/openclash restart
echo "verify: /etc/init.d/openclash status && nft list set inet fw4 china_ip_route_pass"
```

> 可选自动：验证成功后把调用追加到 `/etc/rc.local`（白名单内）。**不要未经验证就启用**，避免与 OpenClash 启动时序打架。
> 装过第三方源的包：`/opt/mu300/bin/mu300-user-packages keep /path/pkg.apk`。
> OTA 后 DNS 挂了：`mu300-user-packages repair-dns`；异常回滚 `mu300-update rollback`。

#### P0-2　关软件流量分载

依据：`flowtable ft` 挂 ingress hook，命中后旁路整个 netfilter 钩子链；已 offload 的连接不再经过 `openclash_mangle` 的 mark 判定。当前 36 条 `[OFFLOAD] mark=0` 都是国内直连流，**没有证据表明已泄露**，但 HTTP/2 连接复用、CDN 同 IP 多域名时首包定路径存在不确定性。8 核 load 0.29，不需要这点加速。

```sh
nft list ruleset > /root/oc_ota_snapshot/nft.before
uci set firewall.@defaults[0].flow_offloading='0'
uci commit firewall
/etc/init.d/firewall reload
sleep 10                                   # 等 fw4 include 的 5s 重插
```

验证（逐项，见 §4）：

```sh
nft list ruleset > /root/oc_ota_snapshot/nft.after
grep -c 'OpenClash QUIC REJECT' /root/oc_ota_snapshot/nft.after   # 期望 2
grep -c 'openclash_mangle'      /root/oc_ota_snapshot/nft.after   # 期望 >0
grep -c 'flow add'              /root/oc_ota_snapshot/nft.after   # 期望 0
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack                      # 逐步归零
/etc/init.d/openclash status                                     # running
nft list set inet fw4 china_ip_route_pass | head -8                # 8 个 IP 仍在
```

规则没回来才补：`/etc/init.d/openclash reload "firewall"` → `sleep 8`。

一键回滚：

```sh
uci set firewall.@defaults[0].flow_offloading='1'; uci commit firewall
/etc/init.d/firewall reload; sleep 10
```

---

### P1　建议做（3 项，零依赖、可回滚）

#### P1-1　关 `endpoint-independent-nat`

官方原文 *"Performance might drop slightly, so it is not recommended to enable it when not needed."* 实机 UDP 62 条 / TCP 1367 条，UDP 只有 49×NTP `:123` + 13×节点 `:8443`，活跃连接全 TCP，UDP 443 已被 QUIC REJECT 挡 1755 包 → **当前零影响**。

用自定义覆写固化（避免每天 0:05 重建覆盖），在 `/etc/openclash/custom/openclash_custom_overwrite.sh` 的 `exit 0` **之前**插入：

```sh
ruby_edit "$CONFIG_FILE" "['tun']['endpoint-independent-nat']" "false"
```

然后 `/etc/init.d/openclash restart`，`/configs` API 确认 `false`。

判定规则（不用猜，日后出现游戏/语音/P2P 时先跑）：

```sh
grep '\[UDP\]' /tmp/openclash.log | grep -vE ':123|:8443|:443' | wc -l
```

结果 > 0 且集中在游戏/P2P 端口 → 把这行删掉或改回 `true`。

#### P1-2　三个系统微调

```sh
uci set wireless.radio0.country='CN'; uci commit wireless; wifi reload
uci set system.@system[0].log_size=512; uci commit system
uci set system.@system[0].urandom_seed=1; uci commit system
```

| 项 | 现状 → 目标 | 理由 |
|---|---|---|
| `country` | TR → CN | 合规 + 邻居兼容；当前 36/40/44/48 在 CN 下仍可用 |
| `log_size` | 128 → 512 KB | 128 KB 太小，驱动报错就刷满；/tmp 有 733 MB |
| `urandom_seed` | 0 → 1 | 保存随机种子 |

> `wifi reload` 会短暂断 WiFi，几秒恢复。

#### P1-3　软件源治理（一次性，之后是纪律）

```sh
apk list -U | grep -c upgradable        # 当前 90
apk add --simulate luci-app-<name>      # 装任何包前先看依赖解析
```

- **永远不要 `apk upgrade`**，也不要单独升级 LuCI（有两个候选版本 26.298 / 26.312）。要升走官方 OTA / `owut` 整包。
- 优先 U30Pro 商店的设备专用包，其次官方源；ImmortalWrt 源只补中文包/主题。
- 装包后 `mu300-user-packages status` 确认；OTA 后 `mu300-update report` 看被挪到 `/etc/mu300/update-kept/` 的文件。
- `wanted` 由 `mu300-update apply` 自动计算，**不用手写**；但 feed 地址不在白名单 → 靠 `keep` 存本地 `.apk`。

---

### P2　可选（收益有限，可不做）

| 项 | 说明 |
|---|---|
| BBR | `net.ipv4.tcp_congestion_control=bbr` + `net.core.default_qdisc=fq`（写 `/etc/sysctl.d/99-u30pro.conf`）。内核已带，但**只改善本机发起的 TCP**（mihomo→节点、订阅拉取），对转发流量无效；若日后启用 `luci-app-u30pro-qos`（cake）需重新评估 `default_qdisc` |
| DNS 轻量冗余 | 08:31 曾集中 82 条国内 DoH `i/o timeout`，与 `sipa_eth -115` 的 modem 唤醒同时 → **链路瞬断，配置层无法根治**。给 `direct-nameserver` 补异构上游只是多一个候选。**不要加 `fallback` 来"解决超时"**，官方定义它是污染判定不是超时切换 |
| `find-process-mode: strict` → `off` | 规则里无 `PROCESS-NAME`，收益极小；需用覆写固化 |
| 设备专用插件 | `luci-app-u30pro-qos`、`luci-app-ttl`、`u30pro-screen-thermal`、`u30pro-screen-clients` 仍未安装，四者在索引里全部存在。详见 `U30Pro-Optimization-Plan.md` §3；cake 自动测速会产生蜂窝流量 |
| 温度观察 | 最高 60.4 °C（modem/充电区），`u30pro-screen-thermal` 可在机身屏幕直看 |

---

### 明确不做（改了会坏 / 收益为零）

| 项 | 理由 |
|---|---|
| 写 `/etc/sysupgrade.conf` 当备份 | 这套固件不读它；前两份方案的这条动作作废 |
| 关 flow offload 后手动重启 OpenClash | fw4 include 自动重插；只在验证失败时补 `reload "firewall"` |
| 按名字剔除 Korea 02 / Malaysia / US 04 等"坏节点" | **已推翻**：Korea 02 后来是全池最快 57ms、被用 779 次。修健康检查机制才是正解，已修 |
| `filter_aaaa` | 已主动放弃：`dns.ipv6:false` + RA 关闭已足够；OpenClash 还会把 `filter_aaaa_dns` 当一次性标志复位 |
| `stack: system` → `mips`、`auto-route/strict-route/auto-redirect: true` | OpenClash 自管 nft 规则，照抄通用 mihomo 模板会冲突 |
| `respect-rules` / `prefer-h3` / `proxy-server-nameserver` / `nameserver-policy` | 官方要求，当前配置正确，别"优化"坏 |
| `gso` / `tcp-concurrent` / `unified-delay` / `sniffer` / `fake-ip-filter` / 健康检查参数 | 已验证有效 |
| packet steering / irqbalance / conntrack / rmem / wmem / sysctl 全家桶 | 8 核 + 1.26 GB 可用 + load 0.29，无瓶颈；厂商已有 `unisoc-cpu*` 调优 |
| `adblock` / AdGuard Home / mosdns / smartdns | 与 OpenClash DNS 劫持 + 广告 REJECT 重复，会打架 |
| `watchcat` / `luci-app-sqm` / UPnP / DDNS / WireGuard 直连 | 已有三重看门狗；CGNAT 无公网 IPv4 |
| `sipa_eth: fail to send -115`、`aicwf_sdio debugfs` | 展锐闭源驱动行为，只有换固件 |

---

## 4. 执行顺序与验证

```
P0-1 快照 + 取到电脑  →  P0-2 关 offload（sleep 10）→  验证
   →  P1-1 关 EIN（覆写 + restart）→ 验证
   →  P1-2 三个 uci 微调  →  P1-3 源治理（纪律，非一次性动作）
   →  P2 按需，一次一项
```

**每次改动后统一跑这套基线**：

```sh
/etc/init.d/openclash status
/root/oc_merge_subs.sh --show
crontab -l | grep oc_merge
nft list set inet fw4 china_ip_route_pass
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack
grep -c 'level=\(warning\|error\)' /tmp/openclash.log
curl -s --max-time 10 -x http://Clash:<pwd>@127.0.0.1:7890 \
  -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204   # 204
```

分流回归：`www.google.com → RuleSet(google) → 代理`、`223.5.5.5 / www.baidu.com → RuleSet(cn) → DIRECT`；**再下一次 Google Play 下载复测一次**（现有成功记录：累计 368 MB）。

---

## 5. 风险提醒

- **最高风险仍是 OTA 丢配置**：`/etc/openclash/` 整个目录不在白名单。不备份 → OTA 后 `config_path` 指向不存在的文件，OpenClash 可能起不来；`chnroute_pass` 例外名单丢失会让 Google Play 下载问题**复发**。这是 P0-1 必须先做的原因。
- 本机固件早于上游「全量 carry」版本（PR #224，`v2026.10.28` 起），适用 `keep_list()` 白名单；**升级到新版后重新核对** `/opt/mu300/bin/mu300-update` 的 `keep_list()`。`source_dirty: true`，一切以本机脚本为准。
- 关 flow offload 后 `sleep 10` 再验证；fw4 include 有防抖，别短时间反复 reload。
- P1-1 用覆写固化，但**覆写文件本身在 `/etc/openclash/custom/`**，OTA 会丢 → 已包含在 P0-1 的 tar 里，恢复脚本会还原。
- 订阅 token 在 `/etc/config/openclash`（644）、`/root/oc_merge_subs.sh`（700）、tar 快照里，别外贴。
- 后台那条订阅记录**必须保持未启用、别删**；删了脚本回退到内置旧链接。
- 节点变化会在 00:05 重启 OpenClash，断网约 9 秒。
- 一切配置改动前先备份：`cp /etc/config/{openclash,firewall,dhcp,system,wireless} /root/oc_backup_20261112/`。

---

## 附：文档关系

| 文档 | 定位 | 本文如何处理 |
|---|---|---|
| `U30Pro-Optimization-Plan.md` | 设备画像 + 插件清单 | 插件部分仍有效，§P2 引用；其 P0 的 `sysupgrade.conf` 动作**作废** |
| `U30Pro-Deep-Optimization-Plan.md` | 深度探测 + flow offload / DNS 发现 | 结论保留，编号统一；"关 offload 必须重启 OpenClash"**修正**为 firewall reload 自动重插 |
| `U30Pro-OTA-and-3Questions-Plan.md` | 三问定案 + OTA 白名单 | 事实与命令全部保留，作为 P0 / P1-1 的依据；「P0+P1」口语所指即此文编号 |
