# getout

`getout` 是一个 Debian VPS 代理出口管理脚本，支持 SOCKS5 和 WireGuard 两种传输协议，用于快速配置入口代理服务、本机 IPv4 出口代理、以及 IPv4+IPv6 双栈出口代理。

它把入口代理、出口代理、路由接管、DNS 切换、systemd 服务和交互式管理面板整合到一个全局命令里。

## 功能

- 入口模式：使用 `gost` 在当前 VPS 上启动带用户名密码认证的 SOCKS5 服务端。
- WireGuard 入口：在当前 VPS 上启动 WireGuard 隧道服务端，支持 ICMP 流量。
- V4 单栈模式：使用 `hev-socks5-tunnel` 接管本机 IPv4 流量，IPv6 保持原生。
- V4+V6 双栈模式：使用 `hev-socks5-tunnel` 同时接管本机 IPv4 和 IPv6 流量。
- WireGuard V4/Dual 出口：通过 WireGuard 隧道接管流量，支持 ICMP，解决 tun2socks 无法代理 ICMP 的限制。
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

- Debian 11/12/13
- root 权限
- `/dev/net/tun` 可用
- systemd
- `wireguard-tools`（WireGuard 模式需要，脚本会自动安装）
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
getout server     # SOCKS5 入口
getout wg-server  # WireGuard 入口
getout v4         # s5-V4 单栈出口 (tun2socks)
getout dual       # s5-V4+V6 双栈出口 (tun2socks)
getout wg-v4      # WG-V4 单栈出口
getout wg-dual    # WG-V4+V6 双栈出口
getout stop
getout restart
getout status
getout update
getout doctor
getout uninstall
```

## 管理面板

```text
====================================================
                 getout 管理面板
====================================================
1.启动 SOCKS5 入口
2.启动 WireGuard 入口
3.修改入口信息
4.启动 s5-V4 单栈模式 (tun2socks)
5.启动 s5-V4+V6 双栈模式 (tun2socks)
6.启动 WG-V4 单栈模式
7.启动 WG-V4+V6 双栈模式
8.修改出口信息
9.切换至 V4 优先模式
10.查看状态
11.重启 getout
12.更新 getout
13.卸载 getout
14.退出

请选择 [1-14]:
```

菜单会根据当前运行状态动态显示明确动作，例如：

- `关闭 SOCKS5 入口`
- `关闭 WireGuard 入口`
- `关闭 V4 单栈模式`
- `关闭 V4+V6 双栈模式`
- `关闭 WireGuard V4 单栈模式`
- `关闭 WireGuard V4+V6 双栈模式`
- `切换至 V4 优先模式`
- `切换至 V6 优先模式`

## 模式说明

### 入口（SOCKS5）

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

### 入口（WireGuard）

当前 VPS 作为 WireGuard 服务端，通过内核级 WireGuard 隧道提供代理入口。

需要手动配置：服务端私钥、监听端口、隧道地址、对端公钥和对端隧道地址。

WireGuard 入口支持 ICMP 流量转发，这是相比 SOCKS5 的主要优势。

对应服务：

```text
getout-wg.service
```

配置文件：

```text
/etc/getout/server.conf
/etc/getout/wireguard.conf (生成)
```

### V4 单栈模式

通过上游 SOCKS5 接管本机 IPv4 流量，IPv6 保持原生。

适合：希望当前 VPS 的 IPv4 出口走指定 SOCKS5，上游 IPv6 和本机 IPv6 保持直连。

### V4+V6 双栈模式

通过上游 SOCKS5 同时接管本机 IPv4 和 IPv6 流量。

适合：希望当前 VPS 的公网流量统一走指定 SOCKS5 出口。

### WireGuard V4/Dual 出口模式

通过 WireGuard 隧道接管本机流量。支持 V4 单栈和 V4+V6 双栈两种子模式。

相比 tun2socks 模式的主要优势：
- 支持 ICMP 流量（`ping` 可用）
- 内核级实现，性能更好
- UDP 原生支持

需要输入完整的 WireGuard 参数：服务器地址/端口、客户端私钥、服务端公钥、隧道地址、DNS 等。

对应服务：

```text
getout-wg.service
```

配置文件：

```text
/etc/getout/client.conf
/etc/getout/wireguard.conf (生成)
```

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

出口模式会接管本机主动出站流量。tun2socks 模式通过 TUN 设备接管，WireGuard 模式通过内核 WireGuard 接口接管。两种模式均保护关键回包不被错误路由：

- 自动检测 SSH 实际监听端口并保护 SSH 回包，不依赖 SSH 是否使用 22 端口；
- 启动或重启出口模式前会显示 SSH 回包保护检测结果，检测不足时会给出断联风险警告；
- 保护上游 SOCKS5 和运行期 DNS 路由，避免代理回环；
- 使用 nftables/conntrack 保护外部主动连入本机的连接回包，避免影响 sing-box、xray、hysteria、tuic、nginx 等本机入站服务；
- tun2socks 出口模式启动前会校验 nftables 入站回包保护是否可用，校验失败会停止启动，避免保护未生效却静默运行。

`ping`/ICMP 不经过 SOCKS 出口代理（tun2socks 模式），`ping` 不通不代表 TCP/UDP 出口不可用。使用 WireGuard 出口模式时 ICMP 正常工作。建议使用 `curl` 或应用自身连接测试确认出口状态。

## 文件位置

```text
/etc/getout/mode
/etc/getout/server.conf
/etc/getout/client.conf
/etc/getout/tun2socks.yaml           # tun2socks 模式配置（生成）
/etc/getout/wireguard.conf           # WireGuard 模式配置（生成）
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
/usr/local/bin/getout-gost           # SOCKS5 入口二进制
/usr/local/bin/getout-tun2socks      # tun2socks 出口二进制
/etc/systemd/system/getout-gost.service
/etc/systemd/system/getout-tun.service
/etc/systemd/system/getout-wg.service
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

### 更新完整性校验

`getout update` 会优先尝试下载同源 `getout.sh.sha256` 并校验下载到的新脚本。如果发布源没有提供该文件，会给出警告并跳过完整性校验，保持一键安装/更新可用。

也可以手动指定期望 SHA256：

```bash
GETOUT_UPDATE_SHA256=<sha256> getout update
```

或指定自定义 checksum 地址：

```bash
GETOUT_UPDATE_SHA256_URL=https://example.com/getout.sh.sha256 getout update
```

注意：当前实现是 SHA256 完整性校验，不是 GPG/minisign 强签名校验。强签名需要额外发布公钥和签名文件。

### 第三方二进制完整性校验

`gost` 和 `hev-socks5-tunnel` 下载完成后会进行 SHA256 校验。脚本内置当前支持架构的固定校验值：

- `gost v2.11.5`: `linux-amd64`、`linux-armv8`
- `hev-socks5-tunnel 2.15.0`: `linux-x86_64`、`linux-arm64`

如果你自行替换上游版本或下载资产，可以用环境变量覆盖期望值：

```bash
GETOUT_GOST_SHA256=<sha256> getout server
GETOUT_HEV_SHA256=<sha256> getout dual
```

## 环境诊断

```bash
getout doctor
```

也可以使用同义命令：

```bash
getout check
```

`doctor` 会检查：

- root 权限、Debian、systemd、TUN、iproute2、curl、sha256sum；
- `wireguard-tools`（`wg`/`wg-quick` 命令）是否可用；
- `/etc/getout` 和配置文件权限；
- 入口/出口二进制和 systemd unit 是否存在；
- 生成的路由脚本语法；
- 当前为出口模式时执行出口 runtime preflight。

## 卸载

```bash
getout uninstall
```

卸载会：

- 停止所有入口/出口服务（含 WireGuard）；
- 清理路由规则；
- 恢复 DNS 和 `/etc/gai.conf`；
- 即使生成的 `routes-down.sh` 缺失或损坏，也会尝试兜底清理 getout 相关路由规则、table 20 默认路由和 nft 表；
- 修改出口、切换 V4/V6 优先、重启出口模式时会先保存运行文件快照，启动失败会尝试恢复旧配置和旧 systemd 文件；
- 禁用 systemd 自启动；
- 删除配置、全局命令、二进制和 systemd unit。

## 测试

仓库内置轻量 Bash 测试：

```bash
tests/run.sh
```

测试覆盖：

- `getout.sh` 语法；
- 生成的 `routes-up.sh` / `routes-down.sh` 语法；
- 出口 runtime 快照恢复，包括删除 preflight 前不存在、失败后新生成的文件；
- 出口 preflight 失败回滚；
- `systemctl daemon-reload` 在出口/入口模式写 service 后失败时的回滚；
- `build.sh` 生成的 `getout.sh` / `getout.sh.sha256` 没有漂移；
- 更新 SHA256 校验成功/失败路径。
- 第三方二进制 SHA256 校验成功/失败路径。

## 维护结构

`getout.sh` 仍然作为单文件发布，方便 raw GitHub 安装/更新、复制恢复和 SHA256 校验。开发态源码拆分在 `src/*.sh`，通过 `build.sh` 生成发布态单文件：

```bash
./build.sh
```

生成的 `getout.sh` 顶部会带有 generated 提示；正常开发请修改 `src/*.sh` 后重新 build。

模块职责、维护规则和验证门禁见 [`MAINTAINING.md`](MAINTAINING.md)。

## 注意事项

- 仅支持 Debian。
- WireGuard 模式需要 `wireguard-tools`，脚本会自动安装；需要自行生成或提供密钥对。
- WireGuard 出口模式下 `ping`/ICMP 正常工作，不受 tun2socks 限制。
- 脚本会在常规下载失败后临时修改 `/etc/resolv.conf` 使用 DNS64，DNS64 下载结束后恢复。
- 出口模式运行时会临时修改 `/etc/resolv.conf` 和 `/etc/gai.conf`，停止或卸载时恢复。
- `/etc/resolv.conf` 和 `/etc/gai.conf` 的恢复依赖首次接管前保存的原始备份和 checksum；如果备份缺失或运行期间被外部修改，脚本会警告并避免盲目覆盖当前内容。
- 出口模式启动前会创建临时 nftables 表做兼容性预检，预检失败不会继续启动。
- `/etc/getout` 会设置为私有目录，配置文件包含代理账号密码。
- 脚本在读取配置文件前会校验配置由 root 拥有，且 group/other 不可写。
- 入口模式必须设置用户名密码；用户名和密码不能包含空白字符或 URL 保留字符。
- `ping`/ICMP 不经过 SOCKS 出口代理，出口连通性请优先用 TCP/UDP 应用测试。
- 请确保 VPS 面板已开启 TUN。
- 交互录入和状态页都会明文显示入口/出口密码，请只在可信终端使用。

## 已知限制与排障

- 交互录入和 `status` 会明文显示入口/出口密码，这是为了在可信终端快速核对配置；不要把状态页截图或日志发到公开场所。
- `ping`/ICMP 不经过 SOCKS 出口代理（tun2socks 模式），排障时请优先使用 `curl` 或真实应用连接测试。WireGuard 出口模式下 ICMP 正常工作。
- `/etc/resolv.conf` 若由 systemd-resolved、NetworkManager、VPS 面板等外部组件并发管理，getout 会尽量保留外部修改并报警；遇到 DNS 异常时先检查 `/etc/getout/resolv.conf.*` 和当前 `/etc/resolv.conf`。
- 出口模式依赖 TUN、nftables、conntrack/fib 规则能力；如果 `getout doctor` 或启动 preflight 失败，请先按错误提示处理内核/系统能力问题。
- 更新后如果服务正在运行，建议执行 `getout restart`，让 systemd unit 和路由脚本刷新到最新版本。
- 当前 SHA256 是完整性校验，不是强签名；如果需要更强供应链保护，请使用可信网络、固定 SHA256，或后续接入 GPG/minisign 签名发布。
- `gost` 和 `hev-socks5-tunnel` 第三方二进制当前做固定 SHA256 完整性校验，但仍不是 GPG/minisign 强签名；高安全场景请自行固定可信来源或接入强签名验证。

## 已测试环境

- Debian GNU/Linux 11 bullseye
- Debian GNU/Linux 13 trixie
- x86_64
- IPv6 VPS
- IPv4 VPS
- `gost v2.11.5`
- `hev-socks5-tunnel 2.15.0`
- `wireguard-tools 1.0.20210223`

## License

MIT
