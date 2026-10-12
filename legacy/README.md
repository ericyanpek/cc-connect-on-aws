# 历史脚本

这些脚本属于早期部署流程，保留用于追溯，入口已加退出保护，执行不会修改本机或 AWS：

- `setup-feishu.sh`、`setup-agents.sh`：旧单/双机器人初始化。
- `setup-codex.sh`：旧共享 `~/.codex` 和凭证配置。
- `configure-models-and-admin.sh`、`set-model.sh`：旧模型与管理员配置。
- `configure-autorestart.sh`、`fix-claude-bedrock-env.sh`：已由统一 unit 与环境配置替代的补丁。
- `sync-github-config.sh`：旧个人 SSH 私钥复制流程。

旧逻辑包含共享 Codex 状态、过时模型、相同的跨 App open_id 等假设；SSH 同步还可能覆盖已有配置，失败路径的临时 IAM 清理也不完整。不要去掉退出保护并用于当前主机。

新主机使用 [部署说明](../docs/deployment.md)，已有主机使用 [运维说明](../docs/operations.md)。原始可执行版本仍可在 Git 历史中查阅。
