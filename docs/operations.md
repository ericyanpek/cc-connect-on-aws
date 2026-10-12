# 运维

## SSM 与服务

本机 `scripts/ssm-run.py` 使用 AWS CLI 凭证链；`AWS_PROFILE` 可选择 profile。默认解析 `us-east-1` 的 `cc-connect` 栈 `InstanceId`，也可传 `--region`、`--stack` 或 `--instance`。Run Command 在实例上通常以 root 运行，提交前需审阅脚本。

```bash
python3 scripts/ssm-run.py scripts/inspect-host.sh --timeout 120
```

执行器有限时轮询并传播远端失败状态。本地轮询超时或终止不等于取消远端命令，可凭输出的 command ID 在 SSM 中查询或取消。

SSM 会话中管理 `ec2-user` 的服务：

```bash
EC2_UID=$(id -u ec2-user)
sudo -u ec2-user env XDG_RUNTIME_DIR="/run/user/$EC2_UID" \
  systemctl --user show cc-connect \
  -p ActiveState -p SubState -p MainPID -p NRestarts -p DropInPaths
```

服务使用 `/usr/bin/cc-connect`、`/etc/cc-connect.env` 和独立 `CODEX_HOME`，并设置自动重启、重启频率限制、进程组回收和 cc-connect 日志轮转。修改 unit 后执行 `daemon-reload` 再重启。不要反复调用 `cc-connect daemon install` 覆盖这个 unit。

## 升级和恢复

1. 记录当前版本、unit 和 drop-in 路径。备份两套机器人配置、凭证文件、服务定义、项目文件及会话数据；备份含凭证时使用 root 专属目录。需要复制正在使用的 SQLite 数据库时，先停止使用它的客户端，或使用 SQLite backup API，不能只复制主库文件而丢掉 WAL。
2. 保持 cc-connect 为官方 `1.5.0`。查询 Claude Code、Codex 的 npm 发布版本，先选定要测试的明确版本，再安装。不要把 `latest` 长期写入部署模板。
3. 在维护窗口停止 cc-connect，以 `umask 022` 安装三个官方 npm 包。合并配置时保留 App、名单和会话数据，移除确认已失效的自编译入口与 service drop-in。
4. 重启服务，验证进程实际加载的版本、两个飞书 App、模型响应和所用 MCP。npm 升级不会替换已经运行的旧进程。
5. 验证通过后，同步 `versions.json`、CloudFormation 参数默认值和 README，记录验证日期。

恢复时重装上次记录的 npm 版本，恢复对应配置与 unit，再 `daemon-reload`、启动和验证。不要把其他客户端正在使用的 `~/.codex/` 回滚到旧快照。

实例专属的一次性迁移程序不作为公共安装器发布；迁移需要按实际配置制定方案。旧脚本位于 [legacy](../legacy/README.md)，已禁止直接执行。

## 模型与配置归属

- **cc-connect**：project 的 `agent.options.provider` 选择 provider；活跃 provider 的 `model` 和 `models` 是机器人模型来源。不要同时写 `agent.options.model`、全局 `ANTHROPIC_MODEL` 或 Codex 顶层 `model`。
- **Claude**：`CLAUDE_CODE_USE_BEDROCK` 和区域在 Claude provider 的 `env` 中。检查 `~/.claude/settings.json` 的模型限制；过时的 `availableModels` 可能干扰显式模型选择。调整前保留其他有用设置。
- **Codex**：`~/.cc-connect/agents/codex/config.toml` 定义 Mantle endpoint、`wire_api = "responses"` 和 `env_key = "CC_CODEX_BEDROCK_API_KEY"`。与 `~/.codex/` 的其他客户端状态隔离。
- **飞书**：`open_id` 属于具体 App；管理员与访问名单使用该机器人的 `/whoami` ID。

新增模型时，先确认账号、endpoint、区域和 API 支持它，再加入对应 provider 的列表；通过 `/model` 切换并检查实际返回的模型。跨 endpoint 或认证方式的变更还需要更新 Codex 独立 provider，不能只换模型字符串。

## 整机运维权限

公开示例中 Codex 使用 `mode = "auto-edit"` 和 `sandbox_mode = "workspace-write"`。cc-connect 1.5.0 的 app-server 实现对 auto-edit/full-auto 均使用 workspace-write、approval never；它不会对每条 shell 命令逐条询问。

如果明确要让机器人修改整机和自身配置，在 cc-connect 的 **Codex project** 中设置：

```toml
[projects.agent.options]
# 保留现有其他 options
mode = "yolo"
```

在它的独立 Codex 配置的顶层设置：

```toml
sandbox_mode = "danger-full-access"
approval_policy = "never"
```

同时检查并处理已有 `default_permissions`、`approvals_reviewer` 或 profile 中可能冲突的权限配置，然后重启 app-server。两处设置需保持一致；cc-connect 会在启动会话时传递权限参数。

这会允许机器人以 `ec2-user` 的权限修改本机文件。标准 Amazon Linux 的 `ec2-user` 通常具备免密 sudo，因此整机模式也能管理系统。它不会自动增加 AWS IAM 权限，AWS API 权限仍由实际使用的凭证决定。将飞书 App 的可用范围、`admin_from` 和 `allow_from` 限定为实际运维者。

机器人可在独立 home 下的 `AGENTS.md` 中记录配置位置和操作约定。直接重启 cc-connect 会终止正在执行的机器人会话；先保存并校验变更，再从外部 SSM 会话重启，或在说明完成情况后安排延迟重启：

```bash
# 以 ec2-user 运行
XDG_RUNTIME_DIR="/run/user/$(id -u)" systemd-run --user \
  --unit="cc-connect-restart-$(date +%s)" --on-active=10s \
  /usr/bin/systemctl --user restart cc-connect.service
```

## MCP 和 AWS Agent Toolkit

为机器人安装工具时，显式设置它的 `CODEX_HOME`：

```bash
export CODEX_HOME=/home/ec2-user/.cc-connect/agents/codex
codex mcp --help
codex plugin --help
```

AgentCore Web Search 的 endpoint、代理命令和认证因部署而异。在上述 home 注册自己的 `agentcore-websearch`，复用已验证的连接方式与环境变量引用；不要把凭证复制进仓库示例。

AWS Agent Toolkit 使用 Codex 原生 `aws-core@agent-toolkit-for-aws` 插件。如果 Claude 已安装它，可先确认 marketplace 中存在 `plugins/aws-core/.codex-plugin/plugin.json`，且版本与已安装插件相符，再注册同一来源：

```bash
# 仅适用于已存在且已检查的 Claude marketplace checkout
codex plugin marketplace add \
  /home/ec2-user/.claude/plugins/marketplaces/agent-toolkit-for-aws
codex plugin add aws-core@agent-toolkit-for-aws
```

全新主机应先按 [AWS Agent Toolkit](https://github.com/aws/agent-toolkit-for-aws) 的说明，通过 `codex plugin marketplace add aws/agent-toolkit-for-aws` 注册官方来源。插件提供 AWS MCP 时，移除确认重复的独立 `aws-mcp` 注册，保留其他 MCP。该模板不会自动复制 Claude 的插件或凭证。

重启 app-server 后检查工具发现，分别做一次搜索和只读 AWS 查询。仅看到配置条目不代表 MCP 已连接。

## 项目落盘

示例把两个机器人初始 `work_dir` 设为 `/home/ec2-user/workspaces/projects`，可共同访问项目资料。推荐目录：

```text
/home/ec2-user/workspaces/
├── projects/
│   └── aws-sap-02/
└── research/
    └── YYYY-MM-topic/
```

对机器人明确指定完整路径，例如“在 `/home/ec2-user/workspaces/projects/aws-sap-02` 阅读资料”。需要固定某个项目时，可以把 `work_dir` 设置为该项目目录。cc-connect 不会根据文件夹名自动切换目录；`AGENTS.md` 只是工作约定，实际写入边界由 sandbox、操作系统权限和工作目录共同决定。

两个机器人使用同一项目时，避免同时修改同一文件。Git 仓库、学习资料与 Codex 会话状态应分别备份。

## GitHub 访问

公开仓库 clone 不需要凭证。需要 EC2 推送时，使用实例专用凭证或只授权目标仓库的 deploy key，并通过 GitHub 官方公布的指纹验证主机密钥。早期的本机 SSH 私钥复制脚本已停用；不要覆盖已有 `~/.ssh/config` 或重复分发个人私钥。
