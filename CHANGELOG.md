# Changelog

## 0.1.9

- 修复出口模式 preflight 失败时不会恢复刚写入运行文件的问题，启动、修改出口、切换优先级和重启出口模式都会先回滚旧配置再退出。
- 运行文件快照现在会记录快照前不存在的文件，回滚时删除预检前新生成的 `tun2socks.yaml`、路由脚本、systemd 文件和模式文件，避免失败后留下半写入状态。
- 扩大出口模式运行文件回滚保护窗口，避免 `systemctl daemon-reload` 等 preflight 前失败绕过回滚。
- 清理重复的 resolver 元数据常量定义。

## 0.1.8

- 运行期 DNS 备份/恢复增加 symlink 元数据、目标文件备份和 checksum 标记，避免破坏 resolver manager 管理的 `/etc/resolv.conf`。
- `/etc/resolv.conf` 和 `/etc/gai.conf` 在 getout 运行期间被外部修改时，不再强行恢复旧备份；旧备份会归档为 conflict 文件，后续启动重新备份当前状态。
- `/etc/gai.conf` 恢复增加 checksum 保护，降低覆盖管理员并发修改的风险。
- 出口模式 preflight 增加临时 nftables 表和规则创建测试，提前发现内核/nft 规则兼容性问题。
- 修改出口、切换 V4/V6 优先、重启出口模式增加运行文件快照和启动失败回滚。
- 新生成的 `getout-tun.service` 立即设置为 root-only 权限，并保持重启时的优先模式不被重置。

## 0.1.7

- 改进运行期 DNS 和 `/etc/gai.conf` 的备份/恢复保护，增加 getout 管理标记；原始备份缺失时不再盲目覆盖未知 DNS。
- nftables/conntrack 入站回包保护改为显式校验，失败时阻止出口模式继续启动，避免保护未生效却静默运行。
- `cleanup_rules` 增加内置兜底清理，即使 `routes-down.sh` 缺失或损坏，也会尝试清理 getout 相关 fwmark、table 20、nft 表和旧版 SSH 规则。
- 出口模式启动、重启、修改出口信息、切换 V4/V6 优先模式前增加 runtime 预检，校验 tun2socks、路由脚本和 nft 可用性。
- `getout update` 在服务运行中时支持交互确认后立即重启，使服务文件和路由脚本刷新生效。
- source 配置文件前增加 root 拥有且 group/other 不可写校验，降低配置文件权限回退后的风险。

## 0.1.6

- 入口模式强制启用用户名密码，避免误配置为公网开放代理。
- 收紧入口/出口认证字符校验，避免 URL 保留字符导致 gost 监听地址解析异常。
- `/etc/getout` 改为私有目录，入口/出口配置和 tun2socks 配置写入后设置为 `600` 权限。
- `routes-down.sh` 改为循环清理重复路由规则，并兼容清理旧版 `sport 22` SSH 保护规则。
- `routes-up.sh` 添加规则前先清理同类规则，降低重复规则残留风险。
- `/etc/gai.conf` 临时处理改用 `mktemp`，避免可预测 `/tmp` 文件名。
- DNS64 临时修改 `/etc/resolv.conf` 时增加 RETURN trap 恢复保护。
- `getout update` 在服务运行中时提示执行 `getout restart` 刷新服务文件和路由脚本。
- 启动/重启出口模式前显示 SSH 回包保护检测结果，弱检测时给出断联风险警告。

## 0.1.5

- 新增外部入站连接回包保护：使用 nftables/conntrack 标记外部主动连入本机的连接，避免出口模式影响 sing-box、xray、hysteria、tuic、nginx 等入站服务。
- SSH 回包保护改为自动检测实际 SSH 监听端口，不再只保护默认 22 端口。
- 修复出口模式重启时未刷新 `routes-up.sh` / `routes-down.sh` 的问题，确保更新后的路由逻辑立即生效。
- 新增 V4/V6 优先模式切换，默认 V6 优先；V4 优先使用 IPv4 DNS 并优先选择 IPv4 地址，V6 优先使用 IPv6 DNS 并优先选择 IPv6 地址。
- 移除运行期 DNS 根据 IPv4 能力自动判断的逻辑。
- README 更新管理面板、DNS 策略、路由保护和 ICMP 说明。

## 0.1.4

- 二进制下载改为先常规下载，失败后再使用 DNS64 兜底，兼容纯 IPv4 VPS。

## 0.1.3

- 运行期 DNS 改为根据机器 IPv4 能力自动选择。
- 检测到默认 IPv4 路由或公网 IPv4 出口可用时使用 `8.8.8.8` / `1.1.1.1`。
- 未检测到 IPv4 能力时继续使用 IPv6 DNS。
- README 重新定位为 VPS 代理出口管理脚本，不再描述为纯 IPv6 专用。
- README 移除 wget 备选安装说明，只保留 curl 不落盘安装方式。

## 0.1.2

- 更新下载增加 cache-bust，避免 GitHub raw 短时间缓存旧脚本导致校验失败。

## 0.1.1

- 新增全局命令 `/usr/local/bin/getout`。
- 新增不落盘一键安装方式：`bash <(curl -fsSL ...)`。
- 新增 `getout update` 和管理面板更新入口。
- 状态页新增版本信息。
- 状态页移除运行期 DNS 展示。
- 卸载时清理全局命令。

## 0.1.0

- 初始版本。
- 支持入口模式、V4 单栈模式、V4+V6 双栈模式。
- 支持交互式管理面板。
- 支持入口/出口互斥、修改入口信息、修改出口信息、重启、状态查看和卸载。
- 下载阶段固定 DNS64。
- 运行期 DNS 使用普通 IPv6 resolver。
