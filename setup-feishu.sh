#!/bin/bash
# Configure cc-connect with Feishu credentials and start it as a daemon.
# Usage: ./setup-feishu.sh <app_id> <app_secret> [project_name]
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="cc-connect"
APP_ID="${1:?usage: setup-feishu.sh <app_id> <app_secret> [project]}"
APP_SECRET="${2:?missing app_secret}"
PROJECT="${3:-my-project}"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target instance: $INSTANCE_ID"

ROLE_NAME="$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --logical-resource-id InstanceRole \
  --query 'StackResources[0].PhysicalResourceId' --output text)"

PARAM_APP="/cc-connect/feishu/app"

cleanup() {
  echo "Cleaning up SSM parameter and temp IAM policy..."
  aws ssm delete-parameter --name "$PARAM_APP" --region "$REGION" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" \
    --policy-name ReadFeishuAppParam 2>/dev/null || true
}
trap cleanup EXIT

echo "Uploading feishu app credentials to SSM (encrypted)..."
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_APP" --type SecureString \
  --value "${APP_ID}:${APP_SECRET}" >/dev/null

echo "Granting role $ROLE_NAME read access to feishu param..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadFeishuAppParam \
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

# Build remote script as a single quoted string (no nested heredoc).
REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
REGION="${REGION}"
PROJECT="${PROJECT}"

# Refresh Bedrock env file in case the API key changed since first boot.
# /etc/cc-connect.env is what systemd reads via EnvironmentFile; /etc/profile.d/cc-connect.sh
# is only for interactive shells. Update both so they stay in sync.
API_KEY=\$(aws ssm get-parameter --name /cc-connect/bedrock-api-key --with-decryption --region "\$REGION" --query Parameter.Value --output text)
sudo sed -i "s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=\$API_KEY|" /etc/cc-connect.env
sudo sed -i "s|^export AWS_BEARER_TOKEN_BEDROCK=.*|export AWS_BEARER_TOKEN_BEDROCK=\"\$API_KEY\"|" /etc/profile.d/cc-connect.sh

APP=\$(aws ssm get-parameter --name /cc-connect/feishu/app --with-decryption --region "\$REGION" --query Parameter.Value --output text)
APP_ID=\${APP%%:*}
APP_SECRET=\${APP#*:}

# Stop any prior daemon before rewriting config.
sudo -u ec2-user -H bash -lc 'cc-connect daemon stop 2>/dev/null || true'
sudo -u ec2-user -H bash -lc 'cc-connect daemon uninstall 2>/dev/null || true'

# Write config.toml directly (no nested heredoc on the orchestrator side).
sudo -u ec2-user mkdir -p /home/ec2-user/.cc-connect
sudo -u ec2-user mkdir -p /home/ec2-user/workspaces/\$PROJECT

CONFIG_PATH=/home/ec2-user/.cc-connect/config.toml
cat > "\$CONFIG_PATH" <<TOML
[log]
level = "info"

[[projects]]
name = "\$PROJECT"

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/home/ec2-user/workspaces/\$PROJECT"
mode = "default"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "\$APP_ID"
app_secret = "\$APP_SECRET"
TOML
chown ec2-user:ec2-user "\$CONFIG_PATH"
chmod 600 "\$CONFIG_PATH"

# Install + start as daemon under ec2-user.
sudo -u ec2-user -H bash -lc "
  set -euo pipefail
  source /etc/profile.d/cc-connect.sh
  unset CLAUDECODE
  cc-connect daemon install --config ~/.cc-connect/config.toml
  cc-connect daemon start
  sleep 4
  echo --- daemon status ---
  cc-connect daemon status || true
  echo --- last 40 log lines ---
  cc-connect daemon logs -n 40 || true
"
REMOTE_EOF
)

ENCODED=$(printf '%s' "$REMOTE" | base64)

echo "Sending bootstrap command via SSM Run-Command..."
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Configure feishu and start cc-connect daemon" \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --query 'Command.CommandId' --output text)"
echo "Command id: $CMD_ID"

while true; do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  echo "  status=$STATUS, waiting..."
  sleep 4
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
echo "cc-connect is configured for Feishu and running as a daemon."
