# 部署

## 准备

- 本机安装 AWS CLI v2、Session Manager plugin 和 Python 3.11+，用现有 profile 认证。设置 `AWS_PROFILE` 可以选择非默认 profile，不要把 AK/SK 写入仓库。
- 选择同一个 VPC 中有出站网络的子网。默认模板面向可访问互联网的子网；需要能访问 SSM、npm、NodeSource、飞书、GitHub 和模型 API。无入站规则不代表无需出站网络。
- 确认实例类型在目标可用区可用。默认 `m8i.2xlarge`，可通过参数选择其他 **x86_64** 类型；模板使用 Amazon Linux 2023 x86_64 AMI。
- 准备两个飞书企业自建应用，一个对应 Claude Code，一个对应 Codex。启用机器人、长连接事件订阅、消息接收与发送权限，发布应用并限制可用范围。具体飞书步骤参考 [cc-connect 1.5.0 文档](https://github.com/chenhg5/cc-connect/tree/v1.5.0)。
- 准备目标区域可用的模型和 Bedrock API key。示例使用 Claude `us-east-1`、Codex Mantle `us-west-2`，凭证独立配置。示例模型不是所有账号都能调用，需检查自己的模型访问权限。

示例模型 ID 参考 2026-10-12 的运行配置：Claude Opus 5.5、GPT-6.1 Sol。当日只复核配置与服务状态，未重新执行模型推理测试。

## 1. 创建主机

在部署区域的 Parameter Store 中，手动创建 **SecureString** `/cc-connect/bedrock-api-key`，存入 Claude 使用的 Bedrock API key。模板授予实例读取这个参数的权限；使用自定义 KMS key 时，还需单独授予 `kms:Decrypt`。

```bash
aws sts get-caller-identity
aws cloudformation validate-template \
  --template-body file://cc-connect-stack.yaml --region us-east-1

# 替换 VPC 和子网 ID。实例、EBS 和网络资源按实际使用计费。
aws cloudformation deploy \
  --template-file cc-connect-stack.yaml \
  --stack-name cc-connect \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides VpcId=vpc-REPLACE SubnetId=subnet-REPLACE \
  --region us-east-1

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
aws ssm start-session --target "$INSTANCE_ID" --region us-east-1
```

模板安装 [版本基线](../versions.json) 中的三个官方 npm 包、Node 22、Git 和 Python 3.12，创建 systemd user service，并启用 `ec2-user` lingering。初始化日志在 `/var/log/cc-connect-userdata.log`。

CloudFormation 栈创建成功不保证 UserData 已成功执行。进入 SSM 后，先运行 `sudo cloud-init status --wait` 并确认 `/usr/bin/cc-connect --version` 等版本输出。此时服务尚未启用，下一步配置完成后再启动。

## 2. 配置两个机器人

在 SSM 会话中切换到实例用户，获取此仓库：

```bash
sudo -iu ec2-user
git clone https://github.com/ericyanpek/cc-connect-on-aws.git ~/cc-connect-on-aws
cd ~/cc-connect-on-aws

install -d -m 700 ~/.cc-connect ~/.cc-connect/agents/codex
mkdir -p ~/workspaces/projects ~/workspaces/research
install -m 600 examples/cc-connect.example.toml ~/.cc-connect/config.toml
install -m 600 examples/codex.example.toml ~/.cc-connect/agents/codex/config.toml
```

这些安装命令用于新主机，已有配置应先备份再编辑。

用编辑器填写 `~/.cc-connect/config.toml` 中的 `REPLACE_*`：

- 两个 App 各自的 `app_id`、`app_secret`。
- 每个 App 对应的用户 `open_id`，同时写入该 project 的 `admin_from` 和 `allow_from`。通过该 App 的用户查询接口获取；已有机器人可以分别发送 `/whoami` 获取。不要用另一个 App 的 ID，也不要把名单设为 `*` 来排查身份问题。
- 各自活跃 provider 的默认 `model` 和 `models` 列表，保持默认模型在列表中。不要另外设置 `agent.options.model`。

通过 `sudoedit /etc/cc-connect.env` 增加 `CC_CODEX_BEDROCK_API_KEY`。保留模板已写入的 Claude 凭证；变量名称可参考 [环境示例](../examples/cc-connect.env.example)。这里使用简单的 `NAME=value` 格式，不写 `export`、命令或多行值。不要把实际密钥粘贴到 Run Command 脚本。

```bash
sudo chown root:ec2-user /etc/cc-connect.env
sudo chmod 640 /etc/cc-connect.env
```

Codex 的 endpoint 和 `env_key` 放在它的独立配置中。不要为机器人运行 `codex login` 来改写 `~/.codex/auth.json`，也不要把 Mantle key 写入 cc-connect provider 的 `api_key` 字段。

## 3. 启用与验证

先确认 TOML 能解析、占位符已替换：

```bash
python3.12 - <<'PY'
from pathlib import Path
import tomllib
for path in (
    Path.home() / ".cc-connect/config.toml",
    Path.home() / ".cc-connect/agents/codex/config.toml",
):
    text = path.read_text()
    tomllib.loads(text)
    if "REPLACE_" in text:
        raise SystemExit(f"尚未填写完成：{path}")
print("TOML 配置检查通过")
PY

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload
systemctl --user enable --now cc-connect.service
systemctl --user show cc-connect -p ActiveState -p SubState -p NRestarts
```

在本机也可以执行：

```bash
python3 scripts/ssm-run.py scripts/inspect-host.sh --region us-east-1
```

在两个飞书机器人分别检查 `/whoami`、`/model` 并发起一次模型请求。模型列表正确或服务 active 只说明部分配置通过，实际响应和调用记录才说明认证、区域和模型选择可用。

需要排查时，在实例上查看 `journalctl --user -u cc-connect` 和 `~/.cc-connect/logs/cc-connect.log`。日志可能包含消息内容，不要原样提交到公开 issue。

## 已有主机

这份模板用于新实例初始化。已有主机按 [运维说明](operations.md) 备份、更新 npm 包、合并配置并重启验证，不要直接重跑旧初始化脚本或 `cc-connect daemon install`。

现有栈更新需先查看 CloudFormation change set；UserData 修改不会替你完成运行中配置迁移，某些实例属性变更还可能触发替换。根卷配置为随实例删除，项目与会话备份应存放在实例之外。
