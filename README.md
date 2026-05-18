# cc-connect on AWS

> 个人实验项目 / Personal experiment — 不构成生产部署建议，使用前请自己评估。

把 [cc-connect](https://github.com/chenhg5/cc-connect) 部署到 AWS EC2，用飞书机器人远程操作 Claude Code，模型走 Amazon Bedrock。

<!-- 演示 GIF：飞书里跟 bot 对话的实录，建议 10-20s，<5MB -->
<!-- 图位放这里效果最强：访客打开 README 第一眼就看到产品长什么样 -->
![飞书对话演示](docs/images/demo-feishu-chat.gif)

- ☁️ EC2 + 默认 VPC，t3.large
- 🔒 无入站端口（通过 SSM Session Manager 运维）
- 🔑 Bedrock API key 存在 SSM SecureString，机器开机时自动注入
- 🤖 Claude Code 通过 `AWS_BEARER_TOKEN_BEDROCK` 调 Bedrock
- 💬 飞书 WebSocket 长连接，无需公网 IP
- 🔁 EC2 上的 git/SSH 配置和本地保持一致，可 clone 私有仓库

## 架构

<!-- 用 excalidraw 或 draw.io 画一张，导出 SVG 或 PNG 放这里。AWS 图标库可在 draw.io More Shapes 里加载。 -->
![架构图](docs/images/architecture.svg)

<details>
<summary>ASCII 备份（图加载失败时看这个）</summary>

```
你的飞书 ──长连接──► 飞书云 ──长连接──► EC2(cc-connect daemon)
                                          │
                                          ├─► Claude Code (子进程)
                                          │     └─► Amazon Bedrock (Claude Sonnet/Haiku)
                                          │
                                          └─► git clone (走本地同步过去的 SSH key)
```

</details>

## 先决条件

- AWS 账号，配好 AWS CLI（`aws sts get-caller-identity` 能返回身份）
- 在目标区域（默认 `us-east-1`）的 Bedrock 控制台已申请并通过 Claude Sonnet/Haiku 的 model access
- 一个 Bedrock 长期 API key（[官方文档](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)）
- 飞书自建应用：拿到 `app_id` 和 `app_secret`，开启机器人能力，订阅 `im.message.receive_v1` 和 `card.action.trigger`，发布版本（详见 [docs/feishu.md](https://github.com/chenhg5/cc-connect/blob/main/docs/feishu.md)）

<!-- 飞书后台配置截图位 — 这是最容易卡住的环节，强烈建议放图： -->
<!-- ![飞书后台 - 事件订阅](docs/images/feishu-app-events.png) -->
<!-- ![飞书后台 - 权限管理](docs/images/feishu-app-permissions.png) -->
- 本地有 GitHub SSH key（`~/.ssh/id_ed25519`），并已加入 GitHub 账号

## 文件清单

| 文件 | 作用 |
|---|---|
| `cc-connect-stack.yaml` | CloudFormation 模板：EC2 + IAM + SG + SSM Parameter |
| `sync-github-config.sh` | 把本地 GitHub SSH key 与 git 全局配置同步到 EC2 |
| `setup-feishu.sh` | 在 EC2 上写入飞书配置并启动 cc-connect daemon |
| `fix-claude-bedrock-env.sh` | 给 systemd service 注入 Bedrock 环境变量（首次部署用过一次，已固化进 user-data，备用） |
| `configure-models-and-admin.sh` | 配置模型白名单 + 锁定管理员 open_id（让 `/model switch` 可控、避免误切到非法 ID） |
| `set-model.sh` | 命令行一键切换 Bedrock 模型（不进飞书的备用通道） |

## 部署流程

### 1. 部署基础设施

```bash
# 取默认 VPC 和一个默认子网
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --region us-east-1 --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --region us-east-1 --query 'Subnets[0].SubnetId' --output text)

aws cloudformation deploy \
  --template-file cc-connect-stack.yaml \
  --stack-name cc-connect \
  --region us-east-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides VpcId=$VPC_ID SubnetId=$SUBNET_ID
```

栈创建后会输出 `InstanceId`、连接命令、SSM 参数名。

### 2. 写入 Bedrock API key

把 SSM 参数升级成 SecureString 并写入真实 key：

```bash
aws ssm put-parameter \
  --name /cc-connect/bedrock-api-key \
  --value "你的 Bedrock API key" \
  --type SecureString \
  --overwrite \
  --region us-east-1
```

### 3. 同步本地 GitHub 配置到 EC2

```bash
./sync-github-config.sh
```

脚本会：
- 把 `~/.ssh/id_ed25519` 和 `id_ed25519.pub` 经 SSM SecureString 加密上传
- 临时给 EC2 IAM Role 赋读权限
- 通过 SSM Run-Command 在 EC2 上写入 `~ec2-user/.ssh/`、配置 `~/.ssh/config`、固化 `known_hosts`、设置 `git config --global user.name/user.email`
- 撤销临时 IAM 权限并删除 SSM 参数

完成后 EC2 上 `git clone git@github.com:...` 等价于在你本地 clone。

### 4. 配置飞书并启动 daemon

```bash
./setup-feishu.sh <app_id> <app_secret> [project_name]
```

脚本会：
- 把飞书凭证经加密 SSM 参数上传，临时授权 EC2 读取
- 在 EC2 上写 `~/.cc-connect/config.toml`
- `cc-connect daemon install/start` 装成 systemd user service
- 输出运行状态和日志尾部

成功后会看到 `cc-connect is running projects=1` 和 `feishu: bot identified` 的日志。

### 5. 在飞书里测试

在飞书工作台搜机器人 → 单聊发消息：

```
hi
```

第一次对话 Claude Code 会启动一个会话回复你。然后试试代码分析：

```
帮我 clone https://github.com/chenhg5/cc-connect 到当前目录，简要分析整体架构
```

### 6. 配置模型白名单 + 锁管理员（可选但强烈推荐）

默认配置下任何能找到 bot 的飞书用户都能给它发指令；模型用 `claude-opus-4-7` 这种短别名也容易触发 `400 invalid model identifier`。

```bash
./configure-models-and-admin.sh
```

先在飞书里给 bot 发 `/whoami` 拿到自己的 open_id，然后：

```bash
./configure-models-and-admin.sh ou_xxxxxxxxxxxxxxxx
```

执行后效果：
- `[projects.platforms.options].allow_from` 限定为你 → 其他人发消息 bot 不响应
- `[[projects]].admin_from` 限定为你 → 只有你能跑 `/model switch`、`/dir`、`/shell` 这类特权命令
- 加入 6 个**已经在你账号上验证过能调通的** Bedrock 模型，并配上短别名

| 别名 | Bedrock inference profile |
|---|---|
| `opus47` | `us.anthropic.claude-opus-4-7` |
| `opus46` | `us.anthropic.claude-opus-4-6-v1` |
| `opus45` | `us.anthropic.claude-opus-4-5-20251101-v1:0` |
| `opus41` | `us.anthropic.claude-opus-4-1-20250805-v1:0` |
| `sonnet45` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| `haiku45` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

## 运维

### 查看日志

```bash
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

aws ssm start-session --target $INSTANCE_ID --region us-east-1
# 进入会话后:
sudo su - ec2-user
cc-connect daemon logs -f
```

### 重启 daemon

```bash
sudo -u ec2-user -H bash -lc 'cc-connect daemon restart'
```

### 修改飞书配置

直接重跑 `./setup-feishu.sh` 即可（脚本会先停旧 daemon、重写 config、重启）。

### 切换 Claude 模型

**飞书里切（推荐）**

```
/model              # 列出当前的 6 个白名单模型
/model switch opus46
/model switch sonnet45
```

<!-- /model switch 演示 GIF，5-10s 即可 -->
<!-- ![模型切换演示](docs/images/demo-model-switch.gif) -->

切换后对话历史保留，下一轮回复立即用新模型。白名单外的别名 cc-connect 会直接拒绝，**不会发到 Bedrock 触发 400**。

> ⚠️ alias 只是 `/model switch` 的查表 key。`config.toml` 里 `[projects.agent.options].model` 的默认值必须写完整 ID（如 `us.anthropic.claude-opus-4-7`），写 alias 会被原样塞给 Bedrock 触发 `400 invalid model identifier`。`configure-models-and-admin.sh` 已经按这个规则写好了。

**命令行切（不进飞书）**

```bash
./set-model.sh us.anthropic.claude-opus-4-7         # 用 opus 4.7
./set-model.sh us.anthropic.claude-opus-4-6-v1      # 用 opus 4.6
./set-model.sh us.anthropic.claude-sonnet-4-5-20250929-v1:0  # 省钱用 sonnet
```

脚本改 `/etc/cc-connect.env`，自动重启 daemon。注意它跟飞书里的 `/model switch` 不互通：cc-connect 在飞书里切的模型存在 config.toml 里，会覆盖 systemd 注入的环境变量；如果你想完全靠 `set-model.sh` 控制，配合执行：

```bash
# 在 EC2 上把 config.toml 的 model 行清掉，让 cc-connect 落到环境变量
sudo -u ec2-user sed -i '/^model = ".*"/d' /home/ec2-user/.cc-connect/config.toml
```

### 轮换 Bedrock API key

```bash
aws ssm put-parameter --name /cc-connect/bedrock-api-key \
  --value "新的 key" --type SecureString --overwrite --region us-east-1

# 让 EC2 重读：
aws ssm send-command --region us-east-1 --document-name AWS-RunShellScript \
  --instance-ids $INSTANCE_ID \
  --parameters 'commands=["KEY=$(aws ssm get-parameter --name /cc-connect/bedrock-api-key --with-decryption --region us-east-1 --query Parameter.Value --output text); sudo sed -i \"s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=$KEY|\" /etc/cc-connect.env; sudo -u ec2-user -H bash -lc \"cc-connect daemon restart\""]'
```

### 临时停机省钱

```bash
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region us-east-1
# 用的时候再:
aws ec2 start-instances --instance-ids $INSTANCE_ID --region us-east-1
```

停机后只收 EBS 费用（30 GB gp3 ≈ $2.4/月）。

### 清理整套环境

```bash
aws cloudformation delete-stack --stack-name cc-connect --region us-east-1
```

EC2、IAM、SG、SSM Parameter 全部删除。

## 安全说明

- 入站规则为空，公网无端口暴露；运维只走 Session Manager（IAM 控权）
- Bedrock API key 在 SSM 中以 SecureString 加密存储，写入 EC2 的 `/etc/cc-connect.env`（`chmod 600`，仅 root 和 ec2-user 可读）
- 飞书凭证写入 `~/.cc-connect/config.toml`（`chmod 600`，ec2-user 可读）
- GitHub 私钥已在 EC2 上：等于该 EC2 拥有你 GitHub 账号的 push 权限。如需撤销访问，最快办法是去 GitHub Settings → SSH keys 删除对应公钥，本地另一份不受影响
- 同步脚本所用的 SSM 临时参数和 IAM 临时策略在每次执行结束都会自动清理
- 默认 `allow_from` 未设置，任何能找到 bot 的飞书用户都能给它发指令；建议在 `~/.cc-connect/config.toml` 的 `[projects.platforms.options]` 加 `allow_from = "你的飞书 user_id"` 限制访问

## 已知坑（已自动处理）

| 问题 | 解决 |
|---|---|
| systemd user service 在 ec2-user 没活跃登录时被 stop | user-data 里 `loginctl enable-linger ec2-user` |
| Claude Code 启动时报 `Not logged in / Please run /login` | 通过 systemd `EnvironmentFile=/etc/cc-connect.env` 注入 Bedrock 环境变量；`/etc/profile.d/` 不被 service 读取 |
| `AWS::EC2::SecurityGroup` 不写 `VpcId` 会报 `SecurityGroupEgress cannot be specified without VpcId` | 模板里把 `VpcId` 做成必填参数 |
| `400 The provided model identifier is invalid` (例如直接用 `claude-opus-4-7`) | Claude Code CLI 短别名表落后于 Bedrock 实际可用模型；`configure-models-and-admin.sh` 把所有模型用完整 inference profile ID 注册到 `[[providers.models]]`，飞书里只能选白名单内的 alias |
| `400 The provided model identifier is invalid (opus47)` —— alias 被当成模型 ID 发到 Bedrock | `[projects.agent.options].model` 的默认值**必须用完整 inference profile ID**（如 `us.anthropic.claude-opus-4-7`），alias（如 `opus47`）**只能用在 `/model switch <alias>` 命令里**，cc-connect 在那个上下文会做 alias→ID 查表替换 |

## 成本估算（us-east-1，按需）

| 项 | 用量 | 月成本 |
|---|---|---|
| EC2 t3.large 24/7 | 730h × $0.0832 | ≈ $61 |
| EBS gp3 30 GB | 30 GB | ≈ $2.4 |
| Bedrock Claude Sonnet 4.5 | 按 token 计费 | 取决于使用量 |
| 数据传输（出站到飞书） | 极少 | < $1 |

不用时直接 `stop-instances`，只剩 EBS 费用。

## 常用一键命令

```bash
# 进入实例
aws ssm start-session --target $(aws cloudformation describe-stacks \
  --stack-name cc-connect --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text) \
  --region us-east-1
```

```bash
# 看实时日志
aws ssm send-command --region us-east-1 --document-name AWS-RunShellScript \
  --instance-ids $INSTANCE_ID \
  --parameters 'commands=["sudo -u ec2-user tail -50 /home/ec2-user/.cc-connect/logs/cc-connect.log"]' \
  --query 'Command.CommandId' --output text
```

<!--
======================================================================
README 图片资产清单（仅维护者可见，HTML 注释不会渲染）

需要放到 docs/images/ 的图：

  P0（强烈建议补）
  - demo-feishu-chat.gif       飞书里跟 bot 对话实录，10-20s，<5MB
  - feishu-app-events.png      飞书后台「事件订阅」截图（脱敏 app_id 等）
  - feishu-app-permissions.png 飞书后台「权限管理」截图
  - architecture.svg           架构图（excalidraw 或 draw.io 画，替换当前 ASCII）

  P1（锦上添花）
  - demo-model-switch.gif      /model switch 演示，5-10s
  - demo-deploy.gif            部署成功的 cloudformation deploy 输出（asciinema 录最方便）

  P2
  - whoami-screenshot.png      飞书里给 bot 发 /whoami 拿 open_id 的步骤

录制工具建议：
  - GIF：macOS Cmd+Shift+5 录 mp4 → Gifski 转 GIF
  - 终端：asciinema rec → asciinema-gif
  - 架构图：excalidraw.com（手绘风快）/ draw.io（专业 AWS 图标）

记得：所有图都裁掉/打码敏感信息（app_id、open_id、对话内容）
======================================================================
-->

## 参考

- [cc-connect 项目](https://github.com/chenhg5/cc-connect)
- [飞书自建应用接入指南](https://github.com/chenhg5/cc-connect/blob/main/docs/feishu.md)
- [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)
- [Amazon Bedrock API Keys](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-generate.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
