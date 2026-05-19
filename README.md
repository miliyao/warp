# Cloudflare WARP Policy Routing

在 Ubuntu/Debian VPS 上部署 Cloudflare WARP，并只让 Google / YouTube /
Gemini 等目标走 WARP 出口。SSH、建站和其它普通流量继续走 VPS 原生线路。

## 功能

- 使用 `wgcf` 生成 Cloudflare WARP WireGuard 配置。
- 自动给 `wgcf.conf` 加 `Table = off`，避免 WARP 接管主路由。
- 自动移除 wgcf 生成的 DNS 和 IPv6 配置，兼容禁用 IPv6 的 VPS。
- 使用 `ipset + iptables mark + ip rule` 实现策略路由。
- 自动拉取 Google 官方 IPv4 段：
  `https://www.gstatic.com/ipranges/goog.json`
- 默认覆盖 Google Search、YouTube、Gemini、Google APIs、gstatic、
  googlevideo 等 Google 自有前端。
- 无 Web 面板，无额外常驻应用；只保留 systemd 定时刷新任务。

## 一键安装

```bash
curl -fsSL "https://raw.githubusercontent.com/miliyao/warp/main/deploy_warp_route.sh?$(date +%s)" | INSTALL_SOURCE=remote bash
```

如果担心 `main` 缓存，建议使用固定 commit URL。

## 状态检查

```bash
warp-route-status
```

常用检查命令：

```bash
systemctl status wg-quick@wgcf.service --no-pager
systemctl status warp-route-refresh.timer --no-pager
ip link show wgcf
ip rule show
ip route show table 51820
ipset list WARP_GOOGLE | head -40
```

检查出口 IP：

```bash
curl -4 https://api.ipify.org
curl -4 --interface wgcf https://api.ipify.org
```

## 默认分流

官方 Google IPv4 段会进入：

```text
WARP_GOOGLE
```

域名解析补充会进入：

```text
WARP_IPS
```

默认域名包含：

- `google.com`
- `googleapis.com`
- `gstatic.com`
- `youtube.com`
- `googlevideo.com`
- `ytimg.com`
- `gemini.google.com`
- `generativelanguage.googleapis.com`
- `ai.google.dev`

规则文件：

```text
/etc/warp-route/rules.json
```

修改规则后手动刷新：

```bash
warp-route-apply
```

系统也会每 30 分钟自动刷新一次 DNS 解析和 Google 官方 IP 段。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/miliyao/warp/main/uninstall_warp_route.sh | bash
```

卸载会清理 systemd 服务、iptables、ip rule、路由表、ipset 和项目文件。
`/etc/wireguard/wgcf.conf` 会保留，避免意外删除 WARP 凭据。

## 说明

这个项目处理的是 VPS 本机发起的流量，也就是 `iptables OUTPUT` 链。
如果你要分流其它客户端转发进来的流量，需要额外处理 `PREROUTING/FORWARD`
或代理程序本身的出站策略。
