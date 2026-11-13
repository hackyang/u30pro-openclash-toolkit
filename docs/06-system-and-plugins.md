# U30 Pro / OpenWrt 25.12.5 优化与插件方案

> 调研日期：2026-11-12　设备：Unisoc UMS9632「U30 Pro」5G CPE  
> 所有包名、版本号、路径均已在设备上核实（`apk update` 已跑通，16580 个可用包）。  
> 本文为调研记录；插件清单仍有效。

---

## 0. 设备画像（决定方案边界）

| 项    | 实测值                                                                                                            |
| ---- | -------------------------------------------------------------------------------------------------------------- |
| 硬件   | Unisoc UMS9632，8× ARMv8 @ 2.04 GHz（schedutil），1.5 GB RAM，7.8 GB eMMC                                           |
| 系统   | OpenWrt 25.12.5 r33051，kernel `6.12.94~ba5ca7f3e73618aeece9cc1c14e512c2`，**rootfs 是 ext4 直挂，不是 overlay**       |
| WAN  | `sipa_eth0`，proto `mu300cell`（蜂窝数据），`10.100.253.228/8`（**CGNAT，无公网 IPv4**）+ 公网 IPv6 `240a:42a8:...`            |
| LAN  | `br-lan` 192.168.77.1/24（桥 `usb0` + `wlan0` 5 GHz AP，`aicwf_sdio`）                                             |
| 负载   | load 0.25，可用内存 1.26 GB，温度约 42 °C，swap(zram) 752 MB 已启用                                                         |
| 已有调优 | `packet_steering`、`unisoc-network-performance`、`unisoc-cpu(-cores)`、`u30pro-watchdog`、`mu300-network-recovery` |
| 已装服务 | LuCI、dropbear、dnsmasq-full、firewall4、odhcpd、cron、wpad、**ttyd**（已开 7681）、OpenClash 0.48.002                     |

**结论：资源不是瓶颈，所有「省内存 / 提 CPU」类优化收益为零。** 真正值得做的是配置持久化、蜂窝链路质量、软件源治理。

---

## 1. 前置约束（动手前必读）

1. **包管理器是 `apk`（apk-tools 3.0.5），`opkg` 已不存在**。命令是 `apk -U add <包名>`，不是 `opkg install`。OpenWrt 25.12 起官方切换，已由镜像站与官方文档双向确认。
2. **三源混装**：官方 25.12.5（8 个 feed）＋ ImmortalWrt 25.12.2（luci/packages）＋ U30 Pro 社区商店（`33333s/u30pro-store`）。已出现 LuCI 组件版本分裂：基础 `luci 26.180`，但 `luci-app-ttyd / compat / i18n` 是 `26.304 / 26.312`，源里 `luci-app-sqm` 是 `26.298`。**装通用 luci-app 前先模拟依赖**。
3. **内核模块必须 ABI 匹配**。官方 kmods feed 的 build id `ba5ca7f3e736...` 与本机内核一致 → 从该源装 `kmod-*` 是安全的；U30 Pro 商店的 kmod 另有 `u30pro-kernel-*` 依赖，跨固件会被 apk 直接拒绝。`kmod-sched-cake`、`tc-tiny` 已验证可用；`kmod-sched-fq_codel` 源里没有。
4. **严禁 `apk upgrade`**：官方明确警告会破坏 `hostapd / wpad / ucode-mod` 依赖，可能变砖。升级走 `owut` / Attended Sysupgrade 或官方 OTA。
5. **CGNAT 限制**：无公网 IPv4 → UPnP、端口映射、IPv4 DDNS、WireGuard 直连均无效；公网 IPv6 存在但 RA 已关、Clash 不代理 v6，别指望它做入站。

---

## 2. 方案 A：系统优化（按优先级）

### P0 — 必做：升级后配置会丢

`/etc/sysupgrade.conf` **只有注释、没有任何条 目**，`/etc/mu300/user-packages/wanted` 不存在，而 rootfs 是 ext4 直挂 + A/B 分区 OTA（`slot_suffix=_a`）。一旦 OTA，以下文件都可能不保：

- `/root/oc_merge_subs.sh`、`/root/oc_merge.rb`、`/root/oc_clean_nodes.sh`
- `/etc/openclash/config/merged.yaml`、`/etc/openclash/subscription_cache/`
- `/etc/openclash/custom/openclash_custom_chnroute_pass.list`、`/etc/openclash/overwrite/Google_Play`
- `/etc/config/openclash`、`/etc/config/dhcp`、`/etc/crontabs/root`、`/etc/apk/world`

动作：

```sh
# 1) 追加到 sysupgrade 保留列表（先确认本机 OTA 是否真的读取这个文件）
cat >> /etc/sysupgrade.conf <<'EOF'
/root/oc_merge_subs.sh
/root/oc_merge.rb
/etc/openclash/config/merged.yaml
/etc/openclash/subscription_cache/
/etc/openclash/custom/
/etc/openclash/overwrite/
/etc/config/openclash
/etc/config/dhcp
/etc/crontabs/root
EOF

# 2) 更可靠：独立打包 + 恢复脚本，放到同一 eMMC 分区
tar czf /mnt/mu300-disk/u30pro-config-backup.tar.gz \
  /etc/config /etc/crontabs /etc/apk/world /etc/apk/repositories.d \
  /root/oc_merge_subs.sh /root/oc_merge.rb /root/oc_clean_nodes.sh \
  /etc/openclash/config /etc/openclash/custom /etc/openclash/overwrite \
  /etc/openclash/subscription_cache /etc/sysupgrade.conf
```

> 风险：A/B OTA 可能整包替换 system 分区，`/etc/sysupgrade.conf` 未必生效。必须**实测一次恢复流程**或定期把 tar 备份取到外部，别假设它有效。

### P0 — 必做：软件源治理

```sh
apk list -a luci-app-sqm          # 看实际会拉哪个 feed 的哪个版本
apk add --simulate luci-app-sqm   # 先看依赖解析，不落盘
```

- 优先从 **U30 Pro 商店**装设备专用包（见方案 B），其次官方源；ImmortalWrt 源只用来补中文包/主题。
- 国内访问 `downloads.openwrt.org` 可用（本次 `apk update` 成功），但 U30 Pro feed 走 `raw.githubusercontent.com`，若失败可换 USTC/ZJU 镜像或临时走代理（apk 读 `http_proxy/https_proxy`）。
- 每次装包后把包名追加到 `/etc/mu300/user-packages/wanted`，借助开机服务 `S99mu300-user-packages` 在 OTA 后自动重装。

### P1 — 建议：配置微调（零依赖、可回滚）

| 项          | 现状                                    | 建议             | 命令 / 说明                                                                                                          |
| ---------- | ------------------------------------- | -------------- | ---------------------------------------------------------------------------------------------------------------- |
| WiFi 国家码   | `radio0.country='TR'`                 | 改 `CN`         | `uci set wireless.radio0.country='CN'; uci commit wireless; wifi reload`。当前信道 36/40/44/48 在 CN 下同样可用；改的是合规性与邻居兼容 |
| 日志缓冲       | `log_size=128` KB                     | 提到 512         | `uci set system.@system[0].log_size=512; uci commit system`。仅 24 条驱动报错就快占满，/tmp 有 733 MB，无害                      |
| 随机种子       | `urandom_seed='0'`                    | 改 `1`          | `uci set system.@system[0].urandom_seed=1; uci commit system`                                                    |
| NTP        | `0..3.openwrt.pool.ntp.org`           | 可选换国内          | `ntp.aliyun.com` / `cn.pool.ntp.org`；当前时间已准，收益小                                                                  |
| WPA3       | `encryption='psk2'`                   | 可选 `sae-mixed` | 老设备兼容性可能下降，先小范围试                                                                                                 |
| SSH        | 密码 + RootPasswordAuth                 | 可选改密钥          | **会影响现有 SSH 连接方式，不建议强改**；WAN input 已是 REJECT                                                                     |
| dnsmasq 监听 | 在 `10.100.253.228:53`（WAN 侧 CGNAT 地址） | 别动             | `localservice=1` 已有；改 listen 可能破坏 OpenClash DNS 劫持链路                                                             |

### P2 — 明确「不要做」

- **不要装 `irqbalance`**：`packet_steering` + `unisoc-cpu*` 已做多核中断/收包调优，重复且可能冲突。
- **不要装 `watchcat`**：已有 `u30pro-watchdog`、`mu300-network-recovery`、`unisoc-ota` 三重恢复。
- **不要装 `adblock` / AdGuard Home / mosdns**：OpenClash 已有 `awavenue-ads` + `category-ads-all` REJECT（实测拦截 279 次），DNS 链路由 dnsmasq→7874→Clash，再加一层只会互相打架。
- **不要装通用 `luci-app-sqm`**：见方案 B，用设备专用 QoS 更合适。
- **不要动 CPU 调频、`tcp_*` sysctl、conntrack 参数**：8 核 + 1.2 GB 可用 + load 0.25，没有瓶颈。

### 不可优化项（厂商闭源驱动）

- `sipa_eth: fail to send, ret -115`（当日 24 次）与 dmesg 里 `sipa_eth_wakeup_cp / pkt need nodelay, wakeup phycp now` 同源，是**展锐 modem 省电唤醒**时的临时发包失败（`-115=EINPROGRESS`），伴随 `sipa_eth: tcp_ack_handle_new` 日志。
- `aicwf_sdio ... debugfs: Directory ... already present`（客户端重连时）无害但刷屏。
- 二者都在厂商驱动/固件层，**OpenWrt 配置改不了，别用 sysctl/tc 去「修」**；只有固件更新或换固件能解决。若观察到下载长连接被它打断，再考虑上报或换固件版本。

---

## 3. 方案 B：插件清单（包名全部已在索引中验证）

### 第一档：强烈推荐（设备专用，零 ABI 风险，来自 U30 Pro 商店）

| 包名                      | 用途                                                       | 为什么适合这台                                                                                      |
| ----------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `luci-app-u30pro-qos`   | **蜂窝防卡顿**：上/下行各自开关，fq_codel 或 cake；cake 可填 0 按 RTT 自动找速率 | 5G 链路带宽波动大、bufferbloat 明显；这是给 `mu300cell` 专门写的，比通用 SQM 靠谱。依赖 `tc-tiny`（已验证可用），默认两个方向都关，安全可回退 |
| `luci-app-ttl`          | 固定蜂窝侧发出的 IPv4 TTL / IPv6 跳数（nftables egress 规则）          | CPE 多设备共享场景，部分运营商靠 TTL 识别热点共享；页面在「网络 → TTL 与跳数限制」                                            |
| `u30pro-screen-thermal` | 屏幕显示 CPU / 电池 / 主板 / 充电 / 射频温度                           | 8 核 + 5G modem，实测 42 °C，机身屏幕能直接看                                                             |
| `u30pro-screen-clients` | 屏幕显示已连设备（DHCP 租约）                                        | 随身 WiFi 场景直观                                                                                 |

安装（装前先 `apk update`）：

```sh
apk -U add luci-app-u30pro-qos luci-app-ttl \
  u30pro-screen-thermal u30pro-screen-clients
```

### 第二档：按需可选

| 包名                                               | 用途                                                | 注意                                                         |
| ------------------------------------------------ | ------------------------------------------------- | ---------------------------------------------------------- |
| `luci-app-sms-forward`                           | SIM 短信转发到 Telegram/Bark/钉钉/飞书/Webhook 等，支持过滤与分段合并 | **设备已自带 `S96unisoc-sms-forward`**，先确认厂商版能力再装，避免两套短信服务抢同一接口 |
| `u30pro-screen-speedtest` / `u30pro-screen-data` | 屏幕测速（10 MB）/ 移动数据开关                               | 测速会消耗蜂窝流量                                                  |
| `luci-theme-u30pro`                              | 设备专用 LuCI 主题（机身示意图、屏幕实时画面、手机抽屉菜单）                 | README 要求 **p542-s120 起**固件；本机 `r33051` 版本对应关系未确认，装前先查固件版本 |
| `luci-app-banip` + `banip`                       | 恶意 IP 封锁                                          | 内存够（1.2 GB），但 OpenClash 已有广告规则、WAN 是 CGNAT，边际收益有限          |
| `luci-app-statistics` + `collectd`，或 `netdata`   | 长期流量/温度/负载图表                                      | 会持续写盘；eMMC 有 7.5 GB 空闲，装得下，但 Clash 面板 + 屏幕插件已够日常用          |
| `tcpdump` `htop` `iperf3` `ethtool`              | 排查工具（全部验证可用）                                      | 建议只在排障时临时装，用完 `apk del`                                    |

### 第三档：明确不建议

| 包 / 类别                                                         | 原因                                            |
| -------------------------------------------------------------- | --------------------------------------------- |
| `adblock` / AdGuard Home / mosdns / smartdns                   | 与 OpenClash 的 DNS 劫持和广告规则重复，且 fake-ip 链路敏感    |
| `irqbalance` / `watchcat` / `luci-app-sqm` / `turboacc`        | 厂商已有对应机制或设备专用替代（见上）                           |
| `miniupnpd` / `ddns-scripts` / IPv4 端口映射 / WireGuard 直连        | CGNAT `10.100.253.228/8`，无公网 IPv4，装了也不生效      |
| `luci-app-eqosplus` / `luci-app-bandix` / `luci-app-wireguard` | 在这台设备的三个源里**查不到**（`apk list -a` 为空），别照抄通用清单   |
| Docker / 网盘 / 离线下载类                                            | 8 核 1.5 GB 虽然跑得动，但这是随身 CPE（电池 + 发热），不该当 NAS 用 |

---

## 4. 执行顺序与回滚

1. 先做 P0 备份：`tar` 打包 + 写 `/etc/sysupgrade.conf`，备份取一份到电脑。
2. `apk update` → `apk add --simulate <包名>` 检查依赖 → 再正式 `apk -U add`。
3. 一次只装一类，装完验证 LuCI 能打开、`/etc/init.d/openclash status` 仍 `running`、`/root/oc_merge_subs.sh --show` 仍读到 2 个订阅。


4. 把新装包名写进 `/etc/mu300/user-packages/wanted`。
5. 回滚：`apk del <包名>`（先 `--simulate`），配置改动用备份 tar 恢复。
6. **永远不要 `apk upgrade`**；升级走官方 OTA / `owut`，并在升级后重新核对本方案 P0 的文件是否还在。

验证基线（每次改动后跑）：

```sh
/etc/init.d/openclash status
/root/oc_merge_subs.sh --show
crontab -l | grep oc_merge
nft list set inet fw4 china_ip_route_pass
logread | grep -c 'sipa_eth: fail to send'
```

---

## 5. 风险提醒

- **最高风险是 OTA 丢配置**：ext4 直挂 + A/B 分区 + 空 `sysupgrade.conf` + 空 `user-packages/wanted`，四者叠加。备份必须先做且取到设备外。
- **第二风险是 LuCI 版本分裂**：三源混装，通用 `luci-app-*` 可能拉到 ImmortalWrt 的 `26.298` 而基础是官方 `26.180`；设备专用包无此问题，优先选它们。
- `luci-app-u30pro-qos` 默认全关，开启后 cake 会自动测速找速率，**蜂窝流量计费用户注意它产生的探测流量**。
- 装 `luci-theme-u30pro` 会立即切换主题，且对固件版本有要求，失败可能导致 LuCI 打不开 → 确保 ttyd（7681）和 SSH（22）可用再装。
- TTL 固定涉及运营商策略，属灰色使用，自行判断合规性。
- 所有设备专用插件以 root 运行屏幕脚本，**只装 U30 Pro 商店这一个已签名源里的包**，别加来路不明的 feed。
