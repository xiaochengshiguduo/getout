# getout

`getout` 是一个 Debian VPS 代理出口管理脚本，用于快速配置入口 SOCKS5 服务、本机 IPv4 出口代理、以及 IPv4+IPv6 双栈出口代理。

它把入口代理、出口代理、路由接管、DNS 切换、systemd 服务和交互式管理面板整合到一个全局命令里。

## 功能

- 入口模式：使用 `gost` 在当前 VPS 上启动 SOCKS5 服务端。
- V4 单栈模式：使用 `hev-socks5-tunnel` 接管本机 IPv4 流量，IPv6 保持原生。
- V4+V6 双栈模式：使用 `hev-socks5-tunnel` 同时接管本机 IPv4 和 IPv6 流量。
- 全局命令：首次运行后自动安装 `/usr/local/bin/getout`，之后直接输入 `getout` 打开管理面板。
- 一键更新：支持 `getout update` 或在管理面板选择 `8.更新 getout`。
- 自动 DNS 策略：检测到默认 IPv4 路由或公网 IPv4 出口可用时使用 IPv4 DNS，否则使用 IPv6 DNS。
- 下载阶段先尝试常规下载，失败后使用 DNS64 兜底，兼容 IPv4、IPv6 和双栈 VPS。
- SSH / 上游 SOCKS5 / DNS 路由保护，降低出口模式接管路由后断联的风险。
- 入口/出口互斥：启动入口模式会停止出口模式；启动出口模式会停止入口模式。
- 自启动跟随当前状态：运行中则启用开机自启，手动关闭则关闭开机自启。
- 支持修改入口信息、修改出口信息、重启、状态查看、更新、卸载清理。

## 系统要求

- Debian 11/12
- root 权限
- `/dev/net/tun` 可用
- systemd
- 支持 IPv4、IPv6 或双栈 VPS

## 快速使用

一键安装并打开管理面板：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh)
```

首次运行会自动安装全局命令：

```text
/usr/local/bin/getout
```

之后直接运行：

```bash
getout
```

也可以直接运行指定命令：

```bash
getout server
getout v4
getout dual
getout status
getout stop
getout restart
getout update
getout uninstall
```

## 管理面板

```text
====================================================
                 getout 管理面板
====================================================
1.启动入口模式
2.修改入口信息
3.启动 V4 单栈模式
4.启动 V4+V6 双栈模式
5.修改出口信息
6.重启 getout
7.查看状态
8.更新 getout
9.卸载 getout
10.退出

请选择 [1-10]:
```

菜单会根据当前运行状态动态显示明确动作，例如：

- `关闭入口模式`
- `关闭 V4 单栈模式`
- `关闭 V4+V6 双栈模式`

## 模式说明

### 入口模式

当前 VPS 作为 SOCKS5 服务端，对外提供代理入口。

对应服务：

```text
getout-gost.service
```

配置文件：

```text
/etc/getout/server.conf
```

### V4 单栈模式

通过上游 SOCKS5 接管本机 IPv4 流量，IPv6 保持原生。

适合：希望当前 VPS 的 IPv4 出口走指定 SOCKS5，上游 IPv6 和本机 IPv6 保持直连。

### V4+V6 双栈模式

通过上游 SOCKS5 同时接管本机 IPv4 和 IPv6 流量。

适合：希望当前 VPS 的公网流量统一走指定 SOCKS5 出口。

## DNS 策略

出口模式运行时，`getout` 会根据当前 VPS 网络能力自动选择运行期 DNS：

- 检测到默认 IPv4 路由或公网 IPv4 出口可用：使用 `8.8.8.8` / `1.1.1.1`。
- 未检测到 IPv4 能力：使用 `2001:4860:4860::8888` / `2606:4700:4700::1111`。

下载二进制时会先尝试常规下载，失败后再使用 DNS64 兜底，以兼容 IPv4、IPv6 和双栈环境。

停止出口模式或卸载时会恢复原始 DNS。

## 文件位置

```text
/etc/getout/mode
/etc/getout/server.conf
/etc/getout/client.conf
/etc/getout/tun2socks.yaml
/etc/getout/routes-up.sh
/etc/getout/routes-down.sh
/usr/local/bin/getout
/usr/local/bin/getout-gost
/usr/local/bin/getout-tun2socks
/etc/systemd/system/getout-gost.service
/etc/systemd/system/getout-tun.service
```

## 更新

```bash
getout update
```

也可以在管理面板选择：

```text
8.更新 getout
```

更新成功后会显示当前版本。

## 卸载

```bash
getout uninstall
```

卸载会：

- 停止入口/出口服务；
- 清理路由规则；
- 恢复 DNS；
- 禁用 systemd 自启动；
- 删除配置、全局命令、二进制和 systemd unit。

## 注意事项

- 仅支持 Debian。
- 脚本会在常规下载失败后临时修改 `/etc/resolv.conf` 使用 DNS64，DNS64 下载结束后恢复。
- 出口模式运行时会临时修改 `/etc/resolv.conf`，停止或卸载时恢复。
- 请确保 VPS 面板已开启 TUN。
- 状态页会明文显示入口/出口密码，请只在可信终端使用。

## 已测试环境

- Debian GNU/Linux 11 bullseye
- x86_64
- IPv6 VPS
- IPv4 VPS
- `gost v2.11.5`
- `hev-socks5-tunnel 2.15.0`

## License

MIT
