#!/bin/bash
# Inject Bedrock env vars into the cc-connect systemd user service so Claude
# Code (a subprocess) sees AWS_BEARER_TOKEN_BEDROCK and friends.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target: $INSTANCE_ID"

REMOTE=$(cat <<'REMOTE_EOF'
set -euo pipefail
REGION="__REGION__"

API_KEY=$(aws ssm get-parameter --name /cc-connect/bedrock-api-key --with-decryption --region "$REGION" --query Parameter.Value --output text)

# systemd EnvironmentFile expects KEY=VALUE without "export" and without quotes.
sudo tee /etc/cc-connect.env >/dev/null <<EOF
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=__REGION__
AWS_BEARER_TOKEN_BEDROCK=$API_KEY
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0
ANTHROPIC_SMALL_FAST_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
EOF
sudo chmod 600 /etc/cc-connect.env
sudo chown root:root /etc/cc-connect.env

# Drop-in to extend cc-connect.service. Located in user scope.
DROPIN_DIR=/home/ec2-user/.config/systemd/user/cc-connect.service.d
sudo -u ec2-user mkdir -p "$DROPIN_DIR"
sudo -u ec2-user tee "$DROPIN_DIR/env.conf" >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/cc-connect.env
EOF

# Allow ec2-user to read /etc/cc-connect.env (systemd reads as the service user).
sudo setfacl -m u:ec2-user:r /etc/cc-connect.env

sudo -u ec2-user -H bash -lc '
  set -euo pipefail
  systemctl --user daemon-reload
  systemctl --user restart cc-connect.service
  sleep 4
  cc-connect daemon status
  echo --- env on running PID ---
  PID=$(pgrep -f /usr/lib/node_modules/cc-connect/bin/cc-connect | head -1)
  if [ -n "$PID" ]; then
    sudo cat /proc/$PID/environ | tr "\0" "\n" | grep -E "BEDROCK|ANTHROPIC|AWS_REGION|CLAUDE" | sed "s/AWS_BEARER_TOKEN_BEDROCK=.*/AWS_BEARER_TOKEN_BEDROCK=<set, len=${#API_KEY}>/"
  fi
  echo --- last 6 log lines ---
  tail -6 ~/.cc-connect/logs/cc-connect.log
'
REMOTE_EOF
)

REMOTE="${REMOTE//__REGION__/$REGION}"
ENCODED=$(printf '%s' "$REMOTE" | base64)
CMD_ID=$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Inject Bedrock env into cc-connect.service" \
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
