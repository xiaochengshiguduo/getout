# Security Notes

- 交互录入和 `getout.sh status` 会显示配置中的入口/出口密码明文。
- 请不要在公开日志、截图或多人共享终端里暴露状态页输出。
- 请只从可信来源运行脚本，并在执行前自行审阅内容。
- `getout update` 支持 SHA256 完整性校验，但这不是 GPG/minisign 强签名；如果发布源没有提供 `getout.sh.sha256`，脚本会警告并跳过校验。
- `gost` 和 `hev-socks5-tunnel` 会从各自 GitHub Release 下载，并使用脚本内置的固定 SHA256 校验值验证；这仍不是 GPG/minisign 强签名，请只在信任发布源和网络环境时使用。
