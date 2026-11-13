# u30pro-openclash-toolkit

在 **中兴 U30 Pro（第三方 `mu300-linux` 固件）** 上，把两个 Clash 订阅合并成一个节点池、修复 Google Play 下载、实现「国外代理 / 国内直连」，并保证升级 OTA 后配置可恢复的一套脚本与实战笔记。

> 实测环境：OpenWrt 25.12.5 / OpenClash 0.48.002 / mihomo 1.19.34 / apk-tools 3.0.5。
> 其他设备请按实际情况调整路径、接口名和内核参数。

## 解决什么问题

| 症状 | 根因 | 本仓库的做法 |
|---|---|---|
| Google Play 能登录、下载失败 | 下载走 `android.clients.google.com` → `*.googleusercontent.com` / `gvt1.com` / `dl.google.com`，且大量 QUIC；登录不经过这条链路 | DNS 修正 + `china_ip_route_pass` 例外 + QUIC REJECT + 关 IPv6 RA |
| 节点「大面积死亡」、长连接随机断 | url-test 健康检查用了 **HTTP** 的 generate_204 且 `lazy: true`，内核警告整批误判 | 改成 HTTPS / interval 120 / timeout 5000 / `lazy: false`，固化在合并脚本里 |
| 两个订阅想合并又不想改规则 | 两个订阅返回的都是**完整 Clash 配置**，第三方订阅转换会替换规则、并让 token 过别人服务器 | 本地 Ruby 只合并 `proxies`，骨架沿用订阅 1 |
| 每天更新总重启、断网 | 订阅内容字段顺序每次变化，全文 `cmp` 永远不同 | 签名只取 `name/type/server/port`，节点不变则跳过重启 |
| OTA 后 OpenClash 起不来 | 这套固件不走 `sysupgrade`，`keep_list()` 白名单不含 `/etc/openclash/` | tar 快照 + 恢复脚本 + 例外集合预热 |

## 目录

```
scripts/    可直接部署到路由器 /root 的脚本
docs/       结论、排障手册、踩坑记录、按时间排列的原始调研
examples/   例外名单、覆写片段、crontab 示例
```

| 文档 | 内容 |
|---|---|
| [00-overview.md](docs/00-overview.md) | 架构、最终状态、关键配置清单、别动清单 |
| [01-troubleshooting.md](docs/01-troubleshooting.md) | 按症状查的排障流程 + 一键基线命令 |
| [02-lessons-learned.md](docs/02-lessons-learned.md) | **经验**：15 条踩坑，现象 / 根因 / 处置 |
| 03–06 | 原始调研记录（最终优化方案、深度调优、OTA 持久化、系统与插件清单） |

## 快速开始

1. 在 LuCI「配置订阅」建 **一条**记录，「订阅地址」每行一个 URL，**保持未启用**（启用会让 OpenClash 把多行当成一个 URL 下载）。脚本从 `openclash.@config_subscribe[0].address` 读取。
2. 部署脚本：

   ```sh
   sh scripts/install.sh          # 只复制脚本、设权限、加 cron，不重启
   /root/oc_merge_subs.sh --show  # 确认读到的链接（隐藏 query 中的 token）
   /root/oc_merge_subs.sh         # 首次合并并生成 merged.yaml
   ```

3. 把 `config_path` 指向 `/etc/openclash/config/merged.yaml`，重启 OpenClash。详细验证清单见 [01-troubleshooting.md](docs/01-troubleshooting.md#基线检查)。

## 脚本

| 文件 | 作用 |
|---|---|
| `oc_merge_subs.sh` | 每日主脚本。从 LuCI 读 N 个订阅 → 失败重试 1 次 → 缓存兜底 → 调 Ruby 合并 → 签名比对 → 有变化才重启 |
| `oc_merge.rb` | 合并节点池、过滤机场流量提示伪节点、重建代理组、给 url-test 组写健康检查参数、生成稳定签名 |
| `oc_clean_nodes.sh` | 兼容入口，内部调用主脚本（合并过程已含过滤） |
| `oc_warm_pass.sh` | 预热 `china_ip_route_pass`：该 nft set 是运行时集合，`firewall reload` 或重启后会被清空 |
| `oc_ota_restore.sh` | OTA 重启后执行一次：解包配置、重设 `config_path`、重启、预热 |
| `install.sh` | 幂等部署，不修改任何运行中配置 |

## 关键设计

- **不依赖第三方订阅转换**：token 不出设备，规则不被模板覆盖。
- **订阅数量不限**：`oc_merge_subs.sh` 逐行读取，`oc_merge.rb` 接受任意多个源文件，同名节点自动加 `S2-` 前缀。
- **断网最小化**：节点池签名不变 → 不写配置、不重启；拉取失败 → 用缓存，不中断服务。
- **后台可见但不托管**：LuCI 那条记录必须保持未启用，它只是「链接的存放处」；真正的更新入口是 cron。
- **健康检查固化在生成逻辑里**，订阅每天重拉也不会被覆盖。

## 安全与隐私

- 仓库内所有订阅 URL、Clash secret、代理密码均已替换为 `example.com` / `REPLACE_*` 占位符。
- **不要提交** `/etc/config/openclash`、`merged.yaml`、`subscription_cache/`、备份 tar、`.ota` 包；`.gitignore` 已排除常见后缀，但仍请自行核对。
- 文档中的 `192.168.77.1` 是示例内网地址，示例凭据仅用于说明诊断方式，不是建议的口令配置。
- **不包含**固件自带的 `engine.py` / `rpc.py` / `boot.py` / LuCI 视图 JS 等第三方代码，也不包含任何 IPA 内容。

## 免责声明

刷写启动镜像、改动防火墙与 TUN 配置可能导致设备无法启动或网络中断。操作前先备份、确认有串口/TTL 或恢复途径。本仓库按 MIT 提供，无任何担保。

## License

[MIT](LICENSE)
