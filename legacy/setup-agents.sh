#!/bin/bash
echo "Archived script: see docs/deployment.md and docs/operations.md." >&2
exit 1
# Historical only: rewrites configuration. Do not run on the normalized host.
# Configure cc-connect with BOTH agents (Claude Code + Codex), each driven by its
# own Feishu app, and start it as a daemon. This is the dual-project successor to
# the older single-project setup-feishu.sh + configure-models-and-admin.sh pair.
#
# Usage:
#   ./setup-agents.sh <admin_open_id> \
#       <claude_app_id> <claude_app_secret> \
#       <codex_app_id>  <codex_app_secret>
#
# Get <admin_open_id> by sending /whoami to either bot in Feishu.
#
# What it writes (config.toml, two [[projects]]):
#   - my-project : claudecode, provider=bedrock,        default model opus-4-8, 8-model whitelist
#   - codex      : codex,      provider=bedrock-mantle, default model gpt-5.5,  5-model whitelist
#
# Secrets handling: both app_id:app_secret pairs are pushed to SSM SecureString
# and pulled on the instance. They never appear in this script's process args on
# the box, and the SSM params + temp IAM policy are cleaned up on exit.
#
# Model selection lives ONLY here (config.toml). /etc/cc-connect.env carries
# provider *access* (CLAUDE_CODE_USE_BEDROCK / AWS_REGION / AWS_BEARER_TOKEN_BEDROCK)
# but never a model id — cc-connect rebuilds the agent model env from this file.
# Codex reads the same AWS_BEARER_TOKEN_BEDROCK (its ~/.codex/config.toml provider
# sets env_key = "AWS_BEARER_TOKEN_BEDROCK"); run ./setup-codex.sh first so that
# ~/.codex/config.toml + the tavily MCP wrapper exist before the daemon starts.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="cc-connect"
ADMIN_OPEN_ID="${1:?usage: setup-agents.sh <admin_open_id> <claude_app_id> <claude_app_secret> <codex_app_id> <codex_app_secret>}"
CLAUDE_APP_ID="${2:?missing claude_app_id}"
CLAUDE_APP_SECRET="${3:?missing claude_app_secret}"
CODEX_APP_ID="${4:?missing codex_app_id}"
CODEX_APP_SECRET="${5:?missing codex_app_secret}"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target instance: $INSTANCE_ID"
echo "Admin/allow open_id: $ADMIN_OPEN_ID"

ROLE_NAME="$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --logical-resource-id InstanceRole \
  --query 'StackResources[0].PhysicalResourceId' --output text)"

PARAM_CLAUDE="/cc-connect/feishu/claude-app"
PARAM_CODEX="/cc-connect/feishu/codex-app"

cleanup() {
  echo "Cleaning up SSM parameters and temp IAM policy..."
  aws ssm delete-parameter --name "$PARAM_CLAUDE" --region "$REGION" 2>/dev/null || true
  aws ssm delete-parameter --name "$PARAM_CODEX" --region "$REGION" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" \
    --policy-name ReadFeishuAppParams 2>/dev/null || true
}
trap cleanup EXIT

echo "Uploading both Feishu app credentials to SSM (encrypted)..."
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_CLAUDE" --type SecureString \
  --value "${CLAUDE_APP_ID}:${CLAUDE_APP_SECRET}" >/dev/null
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_CODEX" --type SecureString \
  --value "${CODEX_APP_ID}:${CODEX_APP_SECRET}" >/dev/null

echo "Granting role $ROLE_NAME read access to feishu params..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadFeishuAppParams \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"ssm:GetParameter\"],
      \"Resource\": [
        \"arn:aws:ssm:${REGION}:*:parameter/cc-connect/feishu/*\"
      ]
    }]
  }"
sleep 5

# Remote script: pull creds, write dual-project config.toml, (re)start daemon.
REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
REGION="${REGION}"
ADMIN="${ADMIN_OPEN_ID}"

# Refresh Bedrock env file in case the API key changed since first boot.
API_KEY=\$(aws ssm get-parameter --name /cc-connect/bedrock-api-key --with-decryption --region "\$REGION" --query Parameter.Value --output text)
sudo sed -i "s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=\$API_KEY|" /etc/cc-connect.env
sudo sed -i "s|^export AWS_BEARER_TOKEN_BEDROCK=.*|export AWS_BEARER_TOKEN_BEDROCK=\"\$API_KEY\"|" /etc/profile.d/cc-connect.sh

CLAUDE_APP=\$(aws ssm get-parameter --name /cc-connect/feishu/claude-app --with-decryption --region "\$REGION" --query Parameter.Value --output text)
CODEX_APP=\$(aws ssm get-parameter --name /cc-connect/feishu/codex-app --with-decryption --region "\$REGION" --query Parameter.Value --output text)
CLAUDE_APP_ID=\${CLAUDE_APP%%:*}
CLAUDE_APP_SECRET=\${CLAUDE_APP#*:}
CODEX_APP_ID=\${CODEX_APP%%:*}
CODEX_APP_SECRET=\${CODEX_APP#*:}

sudo -u ec2-user mkdir -p /home/ec2-user/.cc-connect
sudo -u ec2-user mkdir -p /home/ec2-user/workspaces/my-project

CONFIG_PATH=/home/ec2-user/.cc-connect/config.toml
[ -f "\$CONFIG_PATH" ] && sudo -u ec2-user cp "\$CONFIG_PATH" "\$CONFIG_PATH.bak.\$(date +%s)"

# Write the full dual-project config. Both projects share work_dir
# (intentional: lets Claude and Codex collaborate on the same project knowledge,
# they don't write concurrently). Sessions are still keyed per project name.
cat > "\$CONFIG_PATH" <<TOML
language = "en"

[log]
level = "info"

# ============================================================================
# Project: my-project — Claude Code on Bedrock (Feishu app: claude bot)
# ============================================================================
[[projects]]
name = "my-project"
admin_from = "\$ADMIN"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/home/ec2-user/workspaces/my-project"
mode = "default"
provider = "bedrock"
model = "us.anthropic.claude-opus-4-8"

# Bedrock provider. AWS_BEARER_TOKEN_BEDROCK is NOT listed here — the daemon
# loads it from /etc/cc-connect.env (EnvironmentFile) and the Claude Code
# subprocess inherits it. Keeping the token out of config.toml limits its blast radius.
[[projects.agent.providers]]
name = "bedrock"
env = { CLAUDE_CODE_USE_BEDROCK = "1", AWS_REGION = "\$REGION" }
model = "us.anthropic.claude-opus-4-8"

[[projects.agent.providers.models]]
model = "global.anthropic.claude-fable-5"
alias = "fable5"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-opus-4-8"
alias = "opus48"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-opus-4-7"
alias = "opus47"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-opus-4-6-v1"
alias = "opus46"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-opus-4-5-20251101-v1:0"
alias = "opus45"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-opus-4-1-20250805-v1:0"
alias = "opus41"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
alias = "sonnet45"
[[projects.agent.providers.models]]
model = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
alias = "haiku45"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "\$CLAUDE_APP_ID"
app_secret = "\$CLAUDE_APP_SECRET"
allow_from = "\$ADMIN"
thread_isolation = true
group_reply_all = true

# ============================================================================
# Project: codex — Codex CLI on Bedrock Mantle (Feishu app: codex bot)
# Provider/wire_api/base_url live in ~/.codex/config.toml (see setup-codex.sh);
# the whitelist below only changes the model name within bedrock-mantle.
# ============================================================================
[[projects]]
name = "codex"
admin_from = "\$ADMIN"

[projects.agent]
type = "codex"

[projects.agent.options]
work_dir = "/home/ec2-user/workspaces/my-project"
mode = "auto-edit"
backend = "app_server"
app_server_url = "stdio"
reasoning_effort = "medium"
model = "openai.gpt-5.5"
provider = "bedrock-mantle"

[[projects.agent.providers]]
name = "bedrock-mantle"

[[projects.agent.providers.models]]
model = "openai.gpt-5.5"
alias = "gpt55"
[[projects.agent.providers.models]]
model = "openai.gpt-5.4"
alias = "gpt54"
[[projects.agent.providers.models]]
model = "google.gemma-4-31b"
alias = "gemma31b"
[[projects.agent.providers.models]]
model = "google.gemma-4-26b-a4b"
alias = "gemma26b"
[[projects.agent.providers.models]]
model = "google.gemma-4-e2b"
alias = "gemmae2b"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "\$CODEX_APP_ID"
app_secret = "\$CODEX_APP_SECRET"
allow_from = "\$ADMIN"
thread_isolation = true
group_reply_all = true
TOML
chown ec2-user:ec2-user "\$CONFIG_PATH"
chmod 600 "\$CONFIG_PATH"

# Install + (re)start daemon under ec2-user.
sudo -u ec2-user -H bash -lc "
  set -euo pipefail
  source /etc/profile.d/cc-connect.sh
  unset CLAUDECODE
  cc-connect daemon install --config ~/.cc-connect/config.toml 2>/dev/null || true
  cc-connect daemon restart || cc-connect daemon start
  sleep 5
  echo --- daemon status ---
  cc-connect daemon status || true
  echo --- provider activation (want BOTH lines) ---
  tail -30 ~/.cc-connect/logs/cc-connect.log | grep -iE 'provider switched|engine started' || true
"
REMOTE_EOF
)

ENCODED=$(printf '%s' "$REMOTE" | base64)

echo "Sending dual-agent setup via SSM Run-Command..."
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Configure dual-agent (claudecode+codex) config and start daemon" \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --query 'Command.CommandId' --output text)"
echo "Command id: $CMD_ID"

while true; do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success|Failed|Cancelled|TimedOut) break ;; esac
  echo "  status=$STATUS, waiting..."; sleep 4
done

echo
echo "=== Remote stdout ==="
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardOutputContent' --output text
echo "=== Remote stderr ==="
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardErrorContent' --output text

if [[ "$STATUS" != "Success" ]]; then
  echo "Setup ended with status: $STATUS" >&2
  exit 1
fi
echo "cc-connect configured with both agents and running as a daemon."
echo "Verify in Feishu: each bot's /model list, default model, and that both"
echo "  'provider switched' lines appear above (bedrock + bedrock-mantle)."
