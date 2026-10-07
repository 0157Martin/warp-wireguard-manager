# warp-wireguard-manager

作者：**Martin&林知远**
使用 WGCF 注册 Cloudflare WARP，通过 WireProxy 暴露仅本机可访问的 SOCKS5 代理。它不创建系统默认路由，不接管 SSH、DNS、Caddy 或软件更新流量。

## 一键安装、验证与卸载

```bash
# 安装到 127.0.0.1:40000，并完成真实 WARP 流量验证
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/warp-wireguard-manager/main/install.sh) install

# 验证版本、服务、监听和 Cloudflare trace（必须返回 warp=on）
warp-wireguard version
warp-wireguard status
warp-wireguard test 40000

# 彻底卸载服务、账户、配置、二进制和管理命令
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/warp-wireguard-manager/main/install.sh) uninstall
```

自定义本机 SOCKS5 端口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/warp-wireguard-manager/main/install.sh) install 41000
bash <(curl -fsSL https://raw.githubusercontent.com/0157Martin/warp-wireguard-manager/main/install.sh) verify 41000
```

```bash
warp-wireguard install 40000
warp-wireguard status
warp-wireguard test 40000
warp-wireguard stop
warp-wireguard start
warp-wireguard diagnose
warp-wireguard repair 40000
warp-wireguard uninstall
```

运行时文件位于 `/etc/warp-wireguard-manager`，服务名为 `warp-wireguard-manager.service`。发布资产从 WGCF 与 WireProxy 的 GitHub Releases 获取，并使用上游 `checksums.txt` 校验 SHA-256。WireProxy 固定为已验证的 `1.0.8`，避免生产安装无条件跟随上游 `latest`；升级固定版本前必须重新验证 SOCKS5 监听和 WireGuard 出站。

安装和修复会等待本机监听最多 45 秒。若服务提前失败或超时，脚本会直接显示经过密钥与 UUID 脱敏的 systemd 状态和最近日志，避免只报告“端口未监听”。

WireProxy 的 WireGuard 引擎需要内核提供 IPv6 地址族，即使服务器没有公网 IPv6 路由、实际出口使用 IPv4。脚本会在安装前实际创建并绑定一个临时 IPv6 UDP socket；若地址族不可用，会明确停止并提示检查 sysctl 与 `ipv6.disable=1` 内核启动参数。它不会自行修改系统网络开关。

服务单元保留文件系统与权限隔离，但不设置 `RestrictAddressFamilies`。WireGuard Go 网络栈可能使用 SOCKS5 监听之外的 socket family；错误限制会让宿主机测试正常而服务内返回 `address family not supported by protocol`。

安装与修复不会把“进程已启动”当作成功。脚本依次测试 WGCF 原入口、Cloudflare consumer/Zero Trust IPv4 入口以及官方 WireGuard 端口 `2408/4500/500/1701`，通过本机 SOCKS5 请求 Cloudflare trace；只有返回 `warp=on` 才保存端点并报告安装完成。全部失败时停止服务并明确报告机房可能限制非官方 WireGuard。

本项目供 `v2ray-manager` 作为可替换 WARP 后端调用，也可以独立使用。对调用方提供统一的 `install/status/test/start/stop/diagnose/repair/uninstall/version` 接口。
