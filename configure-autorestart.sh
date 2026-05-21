#!/bin/bash
# Make cc-connect.service auto-restart on any exit (not just failure),
# with a sane crash-loop guard.
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target: $INSTANCE_ID"

REMOTE='set -euo pipefail
DROPIN_DIR=/home/ec2-user/.config/systemd/user/cc-connect.service.d
sudo -u ec2-user mkdir -p "$DROPIN_DIR"

# Drop-in that overrides Restart policy. Lives next to env.conf.
sudo -u ec2-user tee "$DROPIN_DIR/restart.conf" >/dev/null <<EOF
[Unit]
# Allow up to 10 restarts in 5 minutes; if more, systemd gives up.
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
# Always restart, regardless of how the process exited.
Restart=always
RestartSec=5
EOF

sudo -u ec2-user -H bash -lc "
  set -euo pipefail
  systemctl --user daemon-reload
  systemctl --user enable cc-connect.service >/dev/null
  systemctl --user restart cc-connect.service
  sleep 4
  cc-connect daemon status
  echo --- effective service settings ---
  systemctl --user show cc-connect.service -p Restart,RestartUSec,StartLimitBurst,StartLimitIntervalUSec,UnitFileState
  echo --- last 6 log lines ---
  tail -6 ~/.cc-connect/logs/cc-connect.log
"
'
ENCODED=$(printf '%s' "$REMOTE" | base64)

CMD_ID=$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Enable Restart=always for cc-connect" \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --query 'Command.CommandId' --output text)
echo "Command id: $CMD_ID"

while true; do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success|Failed|Cancelled|TimedOut) break ;; esac
  sleep 3
done

echo "=== stdout ==="
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --region "$REGION" \
  --query 'StandardOutputContent' --output text
[[ "$STATUS" == "Success" ]] || { echo FAIL >&2; exit 1; }
