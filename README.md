# warp-wireguard-manager

使用 WGCF 注册 Cloudflare WARP，通过 WireProxy 暴露仅本机可访问的 SOCKS5 代理。它不创建系统默认路由，不接管 SSH、DNS、Caddy 或软件更新流量。

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

运行时文件位于 `/etc/warp-wireguard-manager`，服务名为 `warp-wireguard-manager.service`。发布资产从 WGCF 与 WireProxy 的 GitHub Releases 获取，并使用上游 `checksums.txt` 校验 SHA-256。

安装和修复会等待本机监听最多 45 秒。若服务提前失败或超时，脚本会直接显示经过密钥与 UUID 脱敏的 systemd 状态和最近日志，避免只报告“端口未监听”。

本项目供 `v2ray-manager` 作为可替换 WARP 后端调用，也可以独立使用。对调用方提供统一的 `install/status/test/start/stop/diagnose/repair/uninstall/version` 接口。
