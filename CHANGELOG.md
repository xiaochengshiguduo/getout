# Changelog

## 2.0.1

- 修复测试套件：错误消息匹配修正（`入口模式启动失败` → `入口启动失败`），菜单编号测试改为通用匹配以适应菜单扩展。
- `write_wg_client_conf` 增加第 9 个可选参数 `priority_mode`，与 `write_client_conf` 设计对齐；`switch_priority_mode` WG 分支去掉重复 `PRIORITY_MODE` 行追加逻辑。
- `start_wg_server` 移除回滚后无意义的 `systemctl restart`（死代码）。

## 2.0.0

- 新增 WireGuard 协议支持，入口模式和出口模式均可选择 SOCKS5 或 WireGuard。
- 入口 WireGuard 模式：交互式输入密钥对、端口、对端信息，自动写入 WireGuard 配置和 systemd 服务。
- 出口 WireGuard 模式：支持 V4 优先和 V4+V6 双栈，路由保护、DNS 策略与 SOCKS5 模式完全一致。
- 管理面板、restart/uninstall/status/doctor 全面适配 WireGuard 实例。
- CLI 新增子命令 `wg-server`、`wg-v4`、`wg-dual`。
- 菜单交互标签统一：入口为"SOCKS5 模式"/"WireGuard 模式"，出口为"s5-V4"/"s5-V4+V6"/"WG-V4"/"WG-V4+V6"。

## 1.0.0

- 调整交互管理面板顺序：`查看状态` 移到第 7 项，`重启 getout` 移到第 8 项。
- 管理面板移除 `环境诊断` 入口，`getout doctor` / `getout check` 命令仍然保留。

## 0.3.3

- 第三方二进制下载增加固定 SHA256 完整性校验，覆盖 `gost v2.11.5` 和 `hev-socks5-tunnel 2.15.0` 当前支持的 Linux 架构。
- 支持通过 `GETOUT_GOST_SHA256` / `GETOUT_HEV_SHA256` 覆盖期望校验值，方便自行固定替换资产。
- README/SECURITY 补充第三方二进制校验说明，并将系统要求同步为 Debian 11/12/13。
- 测试增加第三方二进制 SHA256 校验成功/失败路径。

## 0.3.2

- 修复出口模式 stop/restart 可能导致当前 SSH/控制面连接失联的问题。
- `routes-down.sh` 和 fallback 清理现在先撤销全局 `lookup TABLE_ID -> tun0` 接管，再删除 SSH/入站回包保护规则。
- `getout-tun.service` 增加 `ExecStop=$ROUTES_DOWN`，正常停止时先清理路由再停止 tun2socks，同时保留 `ExecStopPost=$ROUTES_DOWN` 兜底异常退出。
- 测试增加 stop cleanup 顺序和 systemd stop 钩子校验。

## 0.3.1

- 加固 `build.sh`：校验模块清单中模块存在、没有重复项、没有遗漏未列入构建顺序的 `src/*.sh`。
- 生成的 `getout.sh` 增加提示，说明它由 `build.sh` 从 `src/*.sh` 生成，不应直接编辑。
- 测试增加生成提示检查，继续确保 build 产物没有漂移。
- 本次为构建/维护流程加固，不改变 getout 运行行为。

## 0.3.0

- 将开发态源码机械拆分到 `src/*.sh`，按模块维护；发布态仍保留单文件 `getout.sh`。
- 新增 `build.sh`，按固定顺序拼接 `src/*.sh`，校验语法，并重新生成 `getout.sh.sha256`。
- 更新 `MAINTAINING.md`，记录模块职责、生成流程和验证门禁。
- `tests/run.sh` 增加 build 产物漂移检查，避免修改 `src/*.sh` 后忘记重新生成发布文件。
- 本次为结构重构，不改变入口/出口行为。

## 0.2.2

- 入口和出口交互录入密码时改为明文显示，和 `status` 明文展示配置的设计保持一致。
- 优化出口上游 SOCKS5 用户名/密码提示，明确无认证上游代理可以留空；入口模式仍强制用户名密码，避免开放代理。

## 0.2.1

- 增加 `getout.sh` 顶部维护地图和模块分区标记，降低单文件脚本继续维护和审查的成本。
- 新增 `MAINTAINING.md`，记录单文件发布策略、后续变更规则、测试门禁和未来开发态拆模块方案。
- 保持功能行为不变，仍以单文件 `getout.sh` 作为发布产物。

## 0.2.0

- 新增 `tests/run.sh`，固化语法、路由脚本生成、出口回滚、入口回滚和更新校验的轻量测试。
- 入口模式增加 server 快照和回滚保护，`systemctl daemon-reload` 或启动失败时会恢复旧入口配置、旧 systemd 文件和模式文件。
- 新增 `getout doctor` / `getout check` 环境诊断命令，检查系统能力、配置权限、服务文件、路由脚本语法和出口 runtime preflight。
- 更新/安装流程增加可选 SHA256 完整性校验，支持同源 `getout.sh.sha256`、`GETOUT_UPDATE_SHA256` 和 `GETOUT_UPDATE_SHA256_URL`。
- README 增加测试说明、环境诊断、更新完整性校验和已知限制/排障章节。

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
