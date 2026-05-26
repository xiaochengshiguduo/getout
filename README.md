# getout

`getout` 是一个 Debian 专用的出口代理管理脚本，适合纯 IPv6 VPS 使用。

它把入口 SOCKS5 服务端、IPv4 全局出口、IPv4+IPv6 双栈全局出口整合到一个脚本里，并提供交互式管理面板。

## 功能

- 入口模式：使用 `gost` 启动本机 SOCKS5 服务端。
- V4 单栈模式：使用 `hev-socks5-tunnel` 接管 IPv4 流量，IPv6 保持原生。
- V4+V6 双栈模式：使用 `hev-socks5-tunnel` 同时接管 IPv4 和 IPv6 流量。
- 下载阶段固定使用 DNS64，方便纯 IPv6 机器直接拉取 GitHub Release 二进制。
- 运行期 DNS 使用普通 IPv6 resolver，停止或卸载时自动恢复。
- SSH 安全保护：自动保护当前 SSH 来源、上游 SOCKS5 地址、DNS 地址，避免全局路由接管后断连。
- 入口/出口互斥：启动入口模式会停止出口模式；启动出口模式会停止入口模式。
- 自启动跟随当前状态：运行中则启用开机自启，手动关闭则关闭开机自启。
- 首次运行自动安装全局命令 `getout`。
- 支持修改入口信息、修改出口信息、重启、状态查看、一键更新、卸载清理。

## 系统要求

- Debian 11/12
- root 权限
- `/dev/net/tun` 可用
- systemd
- 纯 IPv6 或双栈 VPS 均可

## 快速使用

一键安装并打开管理面板：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh)
```

如果当前系统没有 `curl`，也可以使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/xiaochengshiguduo/getout/main/getout.sh | bash
```

首次运行会自动安装全局命令：

```bash
getout
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

本机作为 SOCKS5 服务端，对外提供代理入口。

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

适合：IPv6-only VPS 想要访问 IPv4 网络。

### V4+V6 双栈模式

通过上游 SOCKS5 同时接管 IPv4 和 IPv6 流量。

适合：希望本机所有公网流量统一走指定 SOCKS5 出口。

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
- 脚本会在下载二进制阶段临时修改 `/etc/resolv.conf` 使用 DNS64，下载结束后恢复。
- 出口模式运行时会临时修改 `/etc/resolv.conf` 为普通 IPv6 DNS，停止或卸载时恢复。
- 请确保 VPS 面板已开启 TUN。
- 状态页会明文显示入口/出口密码，请只在可信终端使用。

## 已测试环境

- Debian GNU/Linux 11 bullseye
- x86_64
- 纯 IPv6 VPS
- `gost v2.11.5`
- `hev-socks5-tunnel 2.15.0`

## License

MIT
