#!/bin/bash
# Add a verified Bedrock model whitelist + restrict bot access to admin user(s).
#
# After this:
#   - /model           -> shows the alias list
#   - /model switch X  -> only changes among the whitelisted models, so a typo
#                         can't reach Bedrock and produce 400 invalid model id
#   - allow_from set   -> only the listed Feishu open_ids can talk to the bot
#   - admin_from set   -> only those users can run /model, /provider, etc.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ADMIN_OPEN_ID="${1:?usage: configure-models-and-admin.sh <feishu_open_id>  (in Feishu, send /whoami to your bot to get it)}"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target: $INSTANCE_ID"
echo "Admin/allow open_id: $ADMIN_OPEN_ID"

REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
ADMIN="$ADMIN_OPEN_ID"
CONFIG=/home/ec2-user/.cc-connect/config.toml

if [[ ! -f "\$CONFIG" ]]; then
  echo "ERROR: \$CONFIG not found. Run setup-feishu.sh first." >&2
  exit 1
fi

# Fetch app credentials from current config so we can rewrite cleanly.
# This grep|cut is intentionally fragile — it only handles the simple form
# 'app_id = "..."' that setup-feishu.sh writes. If the parse returns empty,
# we hard-fail rather than overwrite config with empty Feishu creds.
APP_ID=\$(sudo -u ec2-user grep '^app_id' "\$CONFIG" | head -1 | cut -d'"' -f2)
APP_SECRET=\$(sudo -u ec2-user grep '^app_secret' "\$CONFIG" | head -1 | cut -d'"' -f2)
if [[ -z "\$APP_ID" || -z "\$APP_SECRET" ]]; then
  echo "ERROR: failed to parse app_id/app_secret from \$CONFIG. Refusing to rewrite config with empty Feishu credentials." >&2
  echo "Hint: re-run ./setup-feishu.sh <app_id> <app_secret> to restore a known-good config." >&2
  exit 1
fi

sudo -u ec2-user cp "\$CONFIG" "\$CONFIG.bak.\$(date +%s)"

sudo -u ec2-user tee "\$CONFIG" >/dev/null <<TOML
language = "en"

[log]
level = "info"

[[projects]]
name = "my-project"
admin_from = "\$ADMIN"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/home/ec2-user/workspaces/my-project"
mode = "default"
provider = "bedrock"
model = "us.anthropic.claude-opus-4-7"

# Bedrock provider. AWS_BEARER_TOKEN_BEDROCK is intentionally NOT listed here —
# cc-connect's systemd unit (cc-connect.service) loads /etc/cc-connect.env via
# EnvironmentFile=, which puts the token in the daemon's process env. The Claude
# Code subprocess inherits it from there. Putting the token in this file would
# leak a long-term credential into config.toml (mode 0600 ec2-user, but still
# more places than necessary). Don't add it here.
[[projects.agent.providers]]
name = "bedrock"
env = { CLAUDE_CODE_USE_BEDROCK = "1", AWS_REGION = "${REGION}" }

# Verified-on-this-account model whitelist. Aliases used in /model switch.
# Keep this list in sync with set-model.sh's ALLOWED_MODELS array.
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
app_id = "\$APP_ID"
app_secret = "\$APP_SECRET"
allow_from = "\$ADMIN"
TOML
chmod 600 "\$CONFIG"
chown ec2-user:ec2-user "\$CONFIG"

sudo -u ec2-user -H bash -lc '
  cc-connect daemon restart
  sleep 4
  cc-connect daemon status
  echo --- log tail ---
  tail -12 ~/.cc-connect/logs/cc-connect.log
'
REMOTE_EOF
)
ENCODED=$(printf '%s' "$REMOTE" | base64)

CMD_ID=$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Configure model whitelist + admin_from" \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --query 'Command.CommandId' --output text)
echo "Command id: $CMD_ID"

while true; do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success|Failed|Cancelled|TimedOut) break ;; esac
  echo "  status=$STATUS"; sleep 3
done

echo "=== stdout ==="
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardOutputContent' --output text
echo "=== stderr ==="
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardErrorContent' --output text

[[ "$STATUS" == "Success" ]] || exit 1
