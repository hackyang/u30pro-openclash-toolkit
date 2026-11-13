# 01 · 排障手册

## 症状 1 · Google Play 能登录、下载失败

登录只用 `accounts.google.com` / `play.google.com` API；下载要先从 `android.clients.google.com` 换凭证，再去 `*.googleusercontent.com` / `dl.google.com` / `*.gvt1.com` 拉文件，且大量走 QUIC（UDP 443）。**两条链路不同**。

**5 秒定位**：把 OpenClash 从 Rule 临时切 Global，WiFi 断开重连再试。

- 能下 → 分流规则漏 CDN 域名 → 补 `DOMAIN-SUFFIX` 或换「大陆 IP 直连、其余代理」。
- 还是不能下 → QUIC / DNS / IPv6 / 节点问题，按下面顺序排。

| 检查 | 命令 / 位置 | 期望 |
|---|---|---|
| CDN 域名解析 | `nslookup dl.google.com`、`play-lh.googleusercontent.com` | fake-ip `198.18.x.x`，命中 `RULE-SET,google → 节点选择` |
| DNS 上游 | 覆写设置 → DNS | 境外 DoH；填国内 DNS 会污染境外 CDN |
| QUIC | `nft list ruleset \| grep 'OpenClash QUIC REJECT'` | 2 条，且是 **REJECT** 不是 DROP |
| IPv6 | `uci get dhcp.lan.ra` | `disabled`；否则 v6 直连绕过 Clash |
| 例外集合 | `nft list set inet fw4 china_ip_route_pass` | 非空；空了跑 `/root/oc_warm_pass.sh` |
| 系统时间 | `date` | NTP 同步，时间错会导致证书校验失败 |
| 手机侧 | 清 Play 商店 / Google Play 服务 / **下载管理器** 缓存 | — |

**最隐蔽的一条**：`china_ip_route=1` 在 nft 层把命中中国 IP 的流量直接 `return`，**优先于 Clash 规则**。`services.googleapis.cn` / `www.googleapis.cn` 解析成国内 CDN（120.253.253.x），规则里写的「走代理」等于白写。必须把它们写进 `examples/chnroute_pass.list.example` 那样的例外名单。

## 症状 2 · 节点大面积 dead、长连接随机断

先看健康检查配置，不要急着按名字删节点。

```sh
grep -nA8 'name: 自动选择' /etc/openclash/merged.yaml
grep -c 'recommended to use HTTPS' /tmp/openclash.log
```

若 `url:` 是 `http://cp.cloudflare.com/generate_204` 且 `lazy: true`：内核会警告「HTTP 可能被节点劫持 / 不兼容重复 HEAD 请求」，表现为**同一秒整批节点 delay 归 0**，连正在用的主力节点也被判死。这是误判，不是节点集体故障。

修复（已固化在 `scripts/oc_merge.rb`）：HTTPS + interval 120 + timeout 5000 + `lazy: false` + `expected-status: 204`。实测 alive 30 → 40，警告归零。

`fallback` 不是超时切换机制（官方定义是「备份解析服务器 + 污染判定」），别指望加 fallback 解决超时。

## 症状 3 · 重启 / `firewall reload` 后 Google 系异常

`china_ip_route_pass` 是运行时 nft set，不是落盘配置。`firewall reload` 或 OpenClash 重启会把它清空（实测 8 → 0），dnsmasq 只有在例外名单里的域名**被解析过**才会通过 nftset 重新填充。

```sh
/root/oc_warm_pass.sh
nft list set inet fw4 china_ip_route_pass | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | wc -l
```

`oc_merge_subs.sh` 和 `oc_ota_restore.sh` 都已在重启后自动调用它。手动 `firewall reload` 之后要自己跑一次。

## 症状 4 · OTA 后 OpenClash 起不来

这套第三方固件不读 `/etc/sysupgrade.conf`。`config_path` 仍指向 `merged.yaml`，但 `/etc/openclash/` 整个目录已被新镜像替换。

```sh
/root/oc_ota_restore.sh          # 解包 + 重设 config_path + 重启 + 预热
/etc/init.d/openclash status
nft list set inet fw4 china_ip_route_pass
/root/oc_merge_subs.sh --show
```

DNS 仍不通：固件自带 `mu300-user-packages repair-dns`（OpenClash 曾把 dnsmasq 指向自己）。异常回滚：`mu300-update rollback`。升级前务必把 tar 快照取到设备外。

## 症状 5 · 订阅更新后节点减少 / 出现「剩余流量」节点

机场订阅里常把「剩余流量 / 距离下次重置 / 套餐到期 / 官网」也当节点输出。`oc_merge.rb` 用正则过滤并重名加 `S2-` 前缀。若换订阅后命名变了，改 `BOGUS` 正则，不要手工改生成的 `merged.yaml`（每天会被覆盖）。

LuCI 后台那条订阅记录**多行地址 + 在线转换关闭**会被 OpenClash 当成一个 URL 下载，必然失败 → 保持未启用，让脚本自己读。

## 症状 6 · 切 Global 后全部直连

`GLOBAL` 组可能 `now=DIRECT`。在面板里给它指一个节点，或避免用全局模式。

## 症状 7 · DNS 上游集体超时

一分钟几十条国内 DoH `i/o timeout`，且同时出现 `sipa_eth: fail to send, ret -115` → 蜂窝 modem 省电唤醒导致的链路瞬断，**配置层无法根治**。只做轻量冗余（补异构上游），别大改 DNS 结构。持续复现应查固件/驱动。

## 基线检查

```sh
/etc/init.d/openclash status
/root/oc_merge_subs.sh --show
crontab -l | grep oc_merge
nft list set inet fw4 china_ip_route_pass
nft list ruleset | grep -c 'flow add'
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack
grep -c 'level=\(warning\|error\)' /tmp/openclash.log
logread | grep -c 'sipa_eth: fail to send'
```
