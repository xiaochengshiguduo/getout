# getout

`getout` 是一个 Debian VPS 代理出口管理脚本，用于快速配置入口 SOCKS5 服务、本机 IPv4 出口代理、以及 IPv4+IPv6 双栈出口代理。

它把入口代理、出口代理、路由接管、DNS 切换、systemd 服务和交互式管理面板整合到一个全局命令里。

## 功能

- 入口模式：使用 `gost` 在当前 VPS 上启动带用户名密码认证的 SOCKS5 服务端。
- V4 单栈模式：使用 `hev-socks5-tunnel` 接管本机 IPv4 流量，IPv6 保持原生。
- V4+V6 双栈模式：使用 `hev-socks5-tunnel` 同时接管本机 IPv4 和 IPv6 流量。
- 全局命令：首次运行后自动安装 `/usr/local/bin/getout`，之后直接输入 `getout` 打开管理面板。
- 一键更新：支持 `getout update` 或在管理面板选择 `9.更新 getout`。
- V4/V6 优先模式：可在管理面板动态切换 V4 优先或 V6 优先，默认 V6 优先。
- 运行期 DNS 策略：V4 优先模式使用 IPv4 DNS，V6 优先模式使用 IPv6 DNS。
- 下载阶段先尝试常规下载，失败后使用 DNS64 兜底，兼容 IPv4、IPv6 和双栈 VPS。
- SSH / 上游 SOCKS5 / DNS / 外部入站连接回包路由保护，降低出口模式接管路由后断联或影响本机代理服务的风险。
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
6.切换至 V4 优先模式
7.重启 getout
8.查看状态
9.更新 getout
10.卸载 getout
11.退出

请选择 [1-11]:
```

菜单会根据当前运行状态动态显示明确动作，例如：

- `关闭入口模式`
- `关闭 V4 单栈模式`
- `关闭 V4+V6 双栈模式`
- `切换至 V4 优先模式`
- `切换至 V6 优先模式`

## 模式说明

### 入口模式

当前 VPS 作为 SOCKS5 服务端，对外提供代理入口。

入口模式必须设置用户名和密码，避免误配置为公网开放代理。

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

## V4/V6 优先模式与 DNS 策略

出口模式运行时，`getout` 默认使用 V6 优先模式。你可以在管理面板选择：

- `切换至 V4 优先模式`
- `切换至 V6 优先模式`

V4 优先模式会：

- 使用 `8.8.8.8` / `1.1.1.1` 作为运行期 DNS；
- 调整 `/etc/gai.conf`，让双栈域名优先选择 IPv4 地址。

V6 优先模式会：

- 使用 `2001:4860:4860::8888` / `2606:4700:4700::1111` 作为运行期 DNS；
- 调整 `/etc/gai.conf`，让双栈域名优先选择 IPv6 地址。

下载二进制时会先尝试常规下载，失败后再使用 DNS64 兜底，以兼容 IPv4、IPv6 和双栈环境。

停止出口模式或卸载时会恢复原始 DNS 和 `/etc/gai.conf`。`getout` 会记录符号链接、目标文件和 checksum 信息；如果检测到原始备份缺失或运行期间文件被外部修改，会保留当前内容并给出警告，避免盲目恢复到未知内容。

`/etc/gai.conf` 影响的是 glibc 地址选择；部分 Go、Rust、Node 或静态链接程序可能使用自己的解析和地址排序逻辑。

## 路由保护

出口模式会接管本机主动出站流量，同时保护关键回包不被错误送入 `tun0`：

- 自动检测 SSH 实际监听端口并保护 SSH 回包，不依赖 SSH 是否使用 22 端口；
- 启动或重启出口模式前会显示 SSH 回包保护检测结果，检测不足时会给出断联风险警告；
- 保护上游 SOCKS5 和运行期 DNS 路由，避免代理回环；
- 使用 nftables/conntrack 保护外部主动连入本机的连接回包，避免影响 sing-box、xray、hysteria、tuic、nginx 等本机入站服务；
- 出口模式启动前会校验 nftables 入站回包保护是否可用，校验失败会停止启动，避免保护未生效却静默运行。

`ping`/ICMP 不经过 SOCKS 出口代理，`ping` 不通不代表 TCP/UDP 出口不可用。建议使用 `curl` 或应用自身连接测试确认出口状态。

## 文件位置

```text
/etc/getout/mode
/etc/getout/server.conf
/etc/getout/client.conf
/etc/getout/tun2socks.yaml
/etc/getout/routes-up.sh
/etc/getout/routes-down.sh
/etc/getout/resolv.conf.orig
/etc/getout/resolv.conf.getout
/etc/getout/resolv.conf.meta
/etc/getout/resolv.conf.target.orig
/etc/getout/gai.conf.orig
/etc/getout/gai.conf.getout
/etc/getout/gai.conf.meta
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
9.更新 getout
```

更新成功后会显示当前版本。

如果 getout 服务正在运行，更新时会提示是否立即执行：

```bash
getout restart
```

这样可以刷新 systemd 服务文件、`routes-up.sh` 和 `routes-down.sh`。如果跳过自动重启，请稍后手动执行 `getout restart`。

## 卸载

```bash
getout uninstall
```

卸载会：

- 停止入口/出口服务；
- 清理路由规则；
- 恢复 DNS 和 `/etc/gai.conf`；
- 即使生成的 `routes-down.sh` 缺失或损坏，也会尝试兜底清理 getout 相关路由规则、table 20 默认路由和 nft 表；
- 修改出口、切换 V4/V6 优先、重启出口模式时会先保存运行文件快照，启动失败会尝试恢复旧配置和旧 systemd 文件；
- 禁用 systemd 自启动；
- 删除配置、全局命令、二进制和 systemd unit。

## 注意事项

- 仅支持 Debian。
- 脚本会在常规下载失败后临时修改 `/etc/resolv.conf` 使用 DNS64，DNS64 下载结束后恢复。
- 出口模式运行时会临时修改 `/etc/resolv.conf` 和 `/etc/gai.conf`，停止或卸载时恢复。
- `/etc/resolv.conf` 和 `/etc/gai.conf` 的恢复依赖首次接管前保存的原始备份和 checksum；如果备份缺失或运行期间被外部修改，脚本会警告并避免盲目覆盖当前内容。
- 出口模式启动前会创建临时 nftables 表做兼容性预检，预检失败不会继续启动。
- `/etc/getout` 会设置为私有目录，配置文件包含代理账号密码。
- 脚本在读取配置文件前会校验配置由 root 拥有，且 group/other 不可写。
- 入口模式必须设置用户名密码；用户名和密码不能包含空白字符或 URL 保留字符。
- `ping`/ICMP 不经过 SOCKS 出口代理，出口连通性请优先用 TCP/UDP 应用测试。
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
