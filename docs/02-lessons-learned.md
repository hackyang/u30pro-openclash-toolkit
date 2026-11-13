# 02 · 踩坑记录

每条格式：**现象 → 根因 → 处置**。全部来自 2026-11-12/13 的实机诊断，不是通用清单。

### 1. 登录能过、下载必挂
Play 登录只用 `accounts.google.com` / `play.google.com` API；下载要先向 `android.clients.google.com` 换凭证，再去 `*.googleusercontent.com` / `dl.google.com` / `*.gvt1.com` 拉文件，大量走 QUIC。**别按「Google 通不通」判断**，要单独测 CDN 域名和长连接。

### 2. 规则写了「走代理」却不生效
`china_ip_route=1` 在 nft 层把命中中国 IP 的连接直接 `return`，**优先于 Clash 规则**。`services.googleapis.cn` 解析到国内 CDN（120.253.253.x）→ 被硬直连。规则里的 `DOMAIN-SUFFIX,googleapis.cn,PROXY` 等于白写。→ 把域名写进 `china_ip_route_pass` 例外名单。

### 3. 节点「同一秒集体死亡」
url-test 用 `http://cp.cloudflare.com/generate_204` + `lazy: true`。内核反复警告 HTTP 会被节点劫持、不兼容重复 HEAD 请求；整批节点 delay 归 0，连跑了 1359 次的主力节点也被判死。→ 改 HTTPS / interval 120 / timeout 5000 / `lazy:false` / `expected-status:204`，alive 30→40，警告归零。

### 4. 按名字拉黑「坏节点」会误伤
最初 216 条 `i/o timeout` 全指向 Korea 02，看起来该删。修好健康检查后它变成全池最快（57 ms）、被使用 779 次。→ **修检查机制，不删节点**。节点质量随时间变化，静态黑名单必然过期。

### 5. QUIC 要 REJECT 不要 DROP
`DROP` 让客户端等超时才回退 TCP；`REJECT` 立刻回退。fw4/nftables 环境下写进 OpenClash 自定义防火墙规则，别用 iptables 临时命令（重启丢）。

### 6. IPv6 绕过整个代理
LAN 的 `ra/dhcpv6/ndp` 全是 relay、`br-lan` 有公网 `240a:.../64`，但 Clash `ipv6: false`、TUN 只配 IPv4。手机拿到 v6 后 Google 流量不经过 Clash。→ 关 RA/DHCPv6/NDP。此时 `dns.ipv6:false` 已够，**不要再折腾 `filter_aaaa`**。

### 7. 不要对完整 Clash 订阅做第三方转换
两个订阅返回的都是带 `dns` / `rules` / `proxy-groups` 的完整配置。走订阅转换会替换整套规则，且 token 要过别人服务器。→ 本地只合并 `proxies`，骨架沿用其中一个订阅。

### 8. `cmp` 全文比对在动态订阅上永远失败
订阅里 banner / 字段顺序每次变化，导致「每天重启一次」。→ 签名只取 `name|type|server|port` 排序后取 MD5；不变就不写配置、不重启。代价：机场只改密码/uuid 而不动这四项时不会触发重载，需手动跑一次。

### 9. LuCI「多行地址 + 在线转换关闭」是坏组合
OpenClash 会把带换行的两行当成**一个 URL** 下载，必然失败。→ 订阅记录保持**未启用**，只当链接存放处；更新由 cron + 脚本负责。LuCI 表单保存还可能重写 section 导致记录被清掉，改完要复核。

### 10. 第三方固件不读 `sysupgrade.conf`
`mu300-update apply` 是目录切换，保留靠脚本里写死的 8 项白名单，`/etc/openclash/` 不在其中。→ 只写 `sysupgrade.conf` 是假备份。必须 tar 快照 + 恢复脚本，且快照要放在 `/root`（白名单内）并取一份到设备外。

### 11. `firewall reload` 清空运行时 nft set
`china_ip_route_pass` 的元素靠 dnsmasq 的 nftset 在域名被解析时动态填充，不落盘。实测关 flow offload 后集合 8→0。→ 建预热脚本，在所有会重启的规则路径后调用；手动 `firewall reload` 后自己跑一次。

### 12. flow offloading 与 TUN 分流结构性冲突
`flowtable ft` 挂 ingress，命中后旁路整个 netfilter 钩子链，已 offload 的连接不再经过 `openclash_mangle`。8 核 load 0.29 不需要这点加速 → 关掉。**但不必手动重启 OpenClash**：OpenClash 注册了 fw4 include（`firewall reload` → `openclash reload "firewall"`，5 s 延迟 + 防抖），`sleep 10` 后验证即可。

### 13. `wifi reload` 断 SSH；长命令也会断
本机通过 WiFi 连路由器时，`wifi reload` 会让客户端掉线，重连可能要几分钟，别误判成 AP 挂了。超长 `echo '<base64>' | base64 -d > file` 也曾导致 SSH EOFError → 改 **1000 字符分块 + sha256 校验**，长文件写入一律用此法。

### 14. `apk` 不是 `opkg`；严禁 `apk upgrade`
OpenWrt 25.12 起用 apk-tools。三源混装（官方 + ImmortalWrt + 设备商店）会拉到版本分裂的 LuCI 组件。装包前先 `apk add --simulate`；`apk upgrade` 会破坏 hostapd/wpad 依赖，可能变砖。升级走固件 OTA 整包。

### 15. 覆写会被每日重建覆盖；有些开关是「一次性标志」
`tun.endpoint-independent-nat` 若只改运行 yaml，第二天 0:05 就没了 → 用 `custom/openclash_custom_overwrite.sh` 的 `ruby_edit` 固化，或写进生成逻辑。`filter_aaaa_dns` 则相反：OpenClash 启动时把它当一次性标志复位为 0，别反复设它。

### 16. DNS 上游集体超时不是配置问题
一分钟 82 条国内 DoH `i/o timeout`，与 `sipa_eth: fail to send, ret -115`（展锐 modem 省电唤醒）同时出现。→ 链路瞬断，配置层无法根治；`fallback` 官方定义是污染判定，不是超时切换。只补异构上游做轻量冗余，别大改 DNS。

### 17. `GLOBAL` 组可能是 `DIRECT`
误切全局会全直连，看起来像「代理挂了」。面板里指一个节点，或别用全局模式。

### 18. 诊断要从数据出发，别照抄通用模板
`auto-route/strict-route: true`、`stack: mips`、全端口 sniff、MTU 9000、sysctl 全家桶、irqbalance / watchcat / adblock 这类「必装必调」清单，在这台 OpenClash 混合模式 + 厂商已调优的 CPE 上要么冲突要么收益为零。先采集基线，再决定动不动。
