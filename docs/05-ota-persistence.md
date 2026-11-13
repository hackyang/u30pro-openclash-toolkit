# U30 Pro（第三方固件）三问定案 + OTA 安全方案

> 调研：2026-11-13 09:44–09:55　实机脚本逐行核查 + 上游 `dikeckaan/mu300-linux` README/PR 交叉验证。
> 本文为调研记录；结论已并入 docs/03。

---

## 0. 三问速览

| # | 问题 | 确定答案 |
|---|---|---|
| ① | A/B OTA 是否读 `sysupgrade.conf` | **不读，写了也无效。** 这套固件不用 OpenWrt `sysupgrade`，走 `mu300-update apply`：新文件系统解到 `<os>.new`，复制**固定白名单**后整体切换。保留清单见 §2。 |
| ② | 关 flow offload 后 nft 规则是否要手动重插 | **不用。** OpenClash 注册了 fw4 include：`firewall.openclash.path=/var/etc/openclash.include`，内容就是 `/etc/init.d/openclash reload "firewall"`。`firewall reload` 会自动触发重插，带 5 s 延迟与 5 min/10 次防抖。等 6–10 s 再验证即可。 |
| ③ | 关 `endpoint-independent-nat` 是否影响游戏/P2P | **对当前零影响。** 实测 UDP 62 条 / TCP 1367 条（4.3%）；UDP 端口 49×`:123`（NTP）+ 13×`:8443`（节点），活跃连接 7 条全是 TCP，UDP 443 已被 QUIC REJECT 全挡。无游戏/语音/P2P/QUIC 流量。 |

---

## 1. 固件身份（决定所有结论）

| 项 | 值 |
|---|---|
| 项目 | `dikeckaan/mu300-linux`（ZTE F50 / MU300 / U30 Air / **U30 Pro** 第三方 Linux 固件） |
| 本机镜像 | `u30pro-r20261110.125401-g8f1b7ced-sc44fd2f9`，OpenWrt 25.12.5，kernel 6.12.94-u30pro-p1，`source_dirty: true` |
| 存储布局 | `mu300root-container`：`/dev/mmcblk0p84` 同时挂 `/` 与 `/mnt/mu300-disk`；根文件系统是 `/mnt/mu300-disk/openwrt/`（ext4 容器，非 overlay） |
| 启动槽 | `sprdboot.slot_suffix=_a`（bootloader 层 A/B，但 Linux 侧更新是**目录切换** `openwrt` ↔ `openwrt.new`，旧版留作 `.old` 回滚） |
| 升级入口 | `/opt/mu300/bin/mu300-update`（`check/apply/rollback/rollback-boot/kernel/clean/report`）、面板 `System → Update` |
| 中断恢复 | `/etc/init.d/unisoc-ota` + `/usr/lib/unisoc-ota/engine.py`（journal.json） |
| 自装包恢复 | `/etc/init.d/mu300-user-packages` → `S99mu300-user-packages`；状态命令 `mu300-user-packages status` |
| 固件版本注意 | 本机是 `r20261110.125401` 三段式，**早于**上游 PR #224 的 `vYYYY.MM.DD.N` 四段式「全量 carry」；因此适用的是 `keep_list()` **白名单**，不是「所有用户文件自动带过去」 |

---

## 2. ① OTA 到底保留什么

`/opt/mu300/bin/mu300-update` 第 187–190 行原文：

```sh
openwrt) echo "etc/config etc/mu300 etc/unisoc-modem etc/dropbear etc/rc.local etc/crontabs root" ;;
```

| 路径 | 是否保留 | 本项目的东西 |
|---|---|---|
| `/etc/config` | ✅ | `openclash`（订阅记录、覆写开关、config_path）、`dhcp`、`firewall`、`wireless` |
| `/etc/crontabs` | ✅ | `5 0 * * * /root/oc_merge_subs.sh` + 两条 OpenClash 任务 |
| `/root` | ✅ | `oc_merge_subs.sh`、`oc_merge.rb`、`oc_clean_nodes.sh`、`oc_backup_20261112/` |
| `/etc/mu300` | ✅ | `user-packages/`、`image-packages`、`image-version` |
| `/etc/rc.local` `/etc/dropbear` `/etc/unisoc-modem` | ✅ | — |
| **`/etc/openclash/`** | ❌ **不在白名单** | `config/merged.yaml`、`subscription_cache/`、`custom/openclash_custom_chnroute_pass.list`、`overwrite/Google_Play`、运行时 `merged.yaml` |
| `/etc/apk/world`、`repositories.d/` | ❌ 包管理器自身文件 | 自定义 feed（官方 + ImmortalWrt + U30Pro 商店） |
| `/tmp`、缓存 | ❌ 明确不保留 | 所有日志、`/tmp/openclash.log` |

**推论（重要）**：
1. `/etc/sysupgrade.conf` → **不读**；脚本注释明确 `sysupgrade would flash the eMMC`，作者刻意避开它。可写但只是兜底，别依赖。
2. OTA 后 `/etc/openclash/` 会变成新镜像自带的那套：`config_path` 仍指向 `merged.yaml`，但文件不在 → **OpenClash 首启可能起不来，或直到次日 0:05 合并脚本才重建**。这是真实空窗。
3. 合并脚本 + cron + uci 订阅记录三者都保留 → 0:05 会自动重建 `merged.yaml` 和缓存；**但 `custom/chnroute_pass.list` 不会自动重建**，Google Play 例外名单会丢。
4. 自装包：`mu300-update apply` 会读 `/etc/apk/world` 算出「镜像外的包」写入 `NEW/etc/mu300/user-packages/wanted`，新系统首启联网自动重装，并把它们的 `/etc/config/` 设置从 `orphaned-config/` 放回去。**但 feed 地址不保留** → 从 U30Pro 商店/ImmortalWrt 源装的包会重装失败，需 `mu300-user-packages keep FILE.apk`（存到 `/etc/mu300/user-apks/`，在白名单内）。
5. 上游 README 专门点名本场景：*"If such a proxy (OpenClash) had pointed dnsmasq at itself, the device reports it and never falls back to the connection's resolvers by itself: `mu300-user-packages repair-dns` does that on request."* → OTA 后若 DNS 挂了，用这条修。

---

## 3. ② fw4 include 机制（逐行证据）

```sh
$ uci show firewall.openclash
firewall.openclash=include
firewall.openclash.type='script'
firewall.openclash.path='/var/etc/openclash.include'

$ cat /var/etc/openclash.include
/etc/init.d/openclash reload "firewall"
```

`/etc/init.d/openclash` `reload_service()` 第 3999 行起：

```sh
if pidof clash >/dev/null && [ "$enable" == "1" ] && [ "$1" == "firewall" ]; then
   sleep 5                      # 避免系统未就绪
   ... MAX_RELOAD=10 / 300s 防抖 ...
```

`set_firewall()` 在 1263 行负责注册这个 include。规则本身是运行时 `nft add chain` / `nft insert rule` 写入（1547–1564 行），不落盘到 `/etc/nftables.d/`（那里只有注释模板）。

**结论**：`firewall reload` → fw4 执行 include → OpenClash 5 s 后重插全部 nft 链。**不需要手动重启 OpenClash**；只有规则没回来时才补一次 `reload "firewall"` 或 `restart`。

---

## 4. ③ UDP 实测数据

| 指标 | 值 |
|---|---|
| `[UDP]` / `[TCP]` 日志 | 62 / 1367（4.3%） |
| UDP 端口 | 49 × `:123` NTP、13 × `:8443`（节点）；`:443` = 0 |
| UDP 目标 | `1.openwrt.pool.ntp.org`、`time.windows.com`、`time.xtracloud.net`、`time.apple.com`、`pool.ntp.org` + 3 个节点 IP |
| 活跃连接 | 7 条全部 TCP，UDP 0 |
| QUIC | `OpenClash QUIC REJECT` 已挡 1755 包，UDP 443 全回退 TCP |

官方 mihomo 文档：`endpoint-independent-nat` *"Performance might drop slightly, so it is not recommended to enable it when not needed."*

**结论**：当前没有依赖 UDP 全锥 NAT 的业务，关闭零影响。判定规则（不用猜）：

```sh
grep '\[UDP\]' /tmp/openclash.log | grep -vE ':123|:8443|:443' | wc -l
```

结果 > 0 且集中在游戏/语音/P2P 端口时，保留 `true` 或开回来；否则可关。

---

## 5. 执行方案

### P0-1　把自定义文件放进「会被保留」的位置

现有备份目录 `/root/oc_backup_20261112/` 已在白名单内。补一份完整快照：

```sh
mkdir -p /root/oc_ota_snapshot
tar czf /root/oc_ota_snapshot/openclash-custom.tar.gz \
  /etc/openclash/config /etc/openclash/custom \
  /etc/openclash/overwrite /etc/openclash/subscription_cache \
  /etc/apk/world /etc/apk/repositories.d \
  /etc/config /etc/crontabs /etc/rc.local
cp /root/oc_ota_snapshot/openclash-custom.tar.gz /mnt/mu300-disk/   # 同一分区，额外一份
```

再取一份到电脑（离线保险）。

### P0-2　写 OTA 后恢复脚本（放 `/root/`，会被保留）

`/root/oc_ota_restore.sh`：

```sh
#!/bin/sh
# Run once after mu300-update apply + reboot.
set -e
S=/root/oc_ota_snapshot/openclash-custom.tar.gz
[ -f "$S" ] || { echo "snapshot missing"; exit 1; }
tar xzf "$S" -C /                       # 恢复 /etc/openclash/* 与 feed 配置
uci set openclash.config.config_path=/etc/openclash/config/merged.yaml
uci commit openclash
/root/oc_merge_subs.sh --show            # 确认订阅记录还在
/etc/init.d/openclash restart
echo "restored. verify: /etc/init.d/openclash status && nft list set inet fw4 china_ip_route_pass"
```

`chmod 700 /root/oc_ota_restore.sh`。

> 可选自动：把 `/root/oc_ota_restore.sh` 调用追加到 `/etc/rc.local`（白名单内）。**先手动跑一次验证成功**再启用自动，避免开机时与 OpenClash 启动时序打架。

### P0-3　自装包的 feed 兜底

装任何来自 U30Pro 商店 / ImmortalWrt 源的包后：

```sh
/opt/mu300/bin/mu300-user-packages keep /path/to/pkg.apk   # 存到 /etc/mu300/user-apks/（白名单内）
/opt/mu300/bin/mu300-user-packages status
```

并把 feed 文件也放进 P0-1 的 tar（已包含）。

### P1　关软件流量分载（一键，可回滚）

```sh
# 0) 快照当前规则，便于对比
nft list ruleset > /root/oc_ota_snapshot/nft.before

# 1) 关闭
uci set firewall.@defaults[0].flow_offloading='0'
uci commit firewall
/etc/init.d/firewall reload
sleep 10                                  # 等 include 的 5s + 重插

# 2) 逐项验证（按②的确定结论，这些是保险项）
nft list ruleset > /root/oc_ota_snapshot/nft.after
grep -c 'OpenClash QUIC REJECT' /root/oc_ota_snapshot/nft.after          # 期望 2
grep -c 'openclash_mangle'       /root/oc_ota_snapshot/nft.after          # 期望 >0
grep -c 'flow add'               /root/oc_ota_snapshot/nft.after          # 期望 0
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack                              # 逐步归零
/etc/init.d/openclash status                                             # running
nft list set inet fw4 china_ip_route_pass | head -8                       # 例外名单仍在
curl -s --max-time 10 -x http://Clash:<pwd>@127.0.0.1:7890 \
  -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204   # 204
```

规则没回来时才补：

```sh
/etc/init.d/openclash reload "firewall"
sleep 8
```

回滚：

```sh
uci set firewall.@defaults[0].flow_offloading='1'
uci commit firewall
/etc/init.d/firewall reload
sleep 10
```

### P2　关 endpoint-independent-nat

在 `/etc/openclash/custom/openclash_custom_overwrite.sh` 的 `exit 0` 前加（用覆写固化，避免每天重建覆盖）：

```sh
ruby_edit "$CONFIG_FILE" "['tun']['endpoint-independent-nat']" "false"
```

`/etc/init.d/openclash restart` → `/configs` API 确认 `false`。判定规则见 §4；出现游戏/P2P 时改回 `true`。

### OTA 前后检查清单

| 时机 | 命令 |
|---|---|
| 升级前 | `mu300-update check`、`mu300-user-packages status`、确认 P0-1 tar 已取到电脑 |
| 升级 | `mu300-update apply` → `reboot`（本机 `check` 走 GitHub 返回 403，可用 `apply --from FILE\|DIR` 离线包） |
| 首启后 | `/root/oc_ota_restore.sh`；`mu300-update report`（看哪些文件被移到 `/etc/mu300/update-kept/`）；`mu300-user-packages status` |
| 兜底 | DNS 不通时 `mu300-user-packages repair-dns`；异常时 `mu300-update rollback` |

---

## 6. 风险提醒

- **`/etc/sysupgrade.conf` 别当救命稻草**：这套固件不读它。真正生效的是 `keep_list()` 8 个白名单路径。
- **`/etc/openclash/` 会丢**：这是本次最实质的风险。不备份 → OTA 后 `config_path` 指向不存在的文件，OpenClash 可能起不来，且 `chnroute_pass` 例外名单丢失会让 Google Play 下载问题复发。
- 本机固件早于上游「全量 carry」版本（PR #224，`v2026.10.28` 起），**不能按 README 新版本的「所有用户文件都带过去」来理解**。升级到新版本后白名单逻辑可能变化，届时重新核对 `keep_list()`。
- `mu300-update apply` 会替换内核 → 之前强调的 **kmod ABI 匹配**在升级后需重新验证；装过内核模块的，升级后重查 `apk list -I kernel` 与 kmod feed。
- 自定义 apk feed（U30Pro 商店走 `raw.githubusercontent.com`）不在白名单，且本机 `mu300-update` 访问 GitHub 已 403 → OTA 后自装包可能重装失败。用 `keep` 存 `.apk` 本地副本。
- 关 flow offload 后 `sleep 10` 再验证；fw4 include 有 5 s 延迟 + 10 次/5 min 防抖，短时间内反复 reload 可能被抑制。
- `source_dirty: true` 表示这不是干净 release 构建，升级行为可能与上游 README 有差异 → 一切以本机 `/opt/mu300/bin/mu300-update` 实际脚本为准。
