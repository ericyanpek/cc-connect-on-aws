#!/bin/bash
# Switch Claude Code's Bedrock model used by the cc-connect daemon.
#
# Usage:
#   ./set-model.sh                                              # default: opus-4-7
#   ./set-model.sh us.anthropic.claude-opus-4-6-v1
#   ./set-model.sh us.anthropic.claude-opus-4-5-20251101-v1:0
#   ./set-model.sh us.anthropic.claude-sonnet-4-5-20250929-v1:0
#
# Optional second argument is the small/fast model (haiku tier) used by
# claude-code for cheap helper calls.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
MODEL="${1:-us.anthropic.claude-opus-4-7}"
SMALL_FAST="${2:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name cc-connect --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target: $INSTANCE_ID"
echo "Model:  $MODEL"
echo "Small:  $SMALL_FAST"

REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
sudo sed -i "s|^ANTHROPIC_MODEL=.*|ANTHROPIC_MODEL=${MODEL}|" /etc/cc-connect.env
sudo sed -i "s|^ANTHROPIC_SMALL_FAST_MODEL=.*|ANTHROPIC_SMALL_FAST_MODEL=${SMALL_FAST}|" /etc/cc-connect.env
echo --- /etc/cc-connect.env ---
sudo grep -E "^(ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|CLAUDE_CODE_USE_BEDROCK|AWS_REGION)=" /etc/cc-connect.env
sudo -u ec2-user -H bash -lc "cc-connect daemon restart && sleep 4 && cc-connect daemon status && tail -8 ~/.cc-connect/logs/cc-connect.log"
REMOTE_EOF
)
ENCODED=$(printf '%s' "$REMOTE" | base64)

CMD_ID=$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Switch Claude Code Bedrock model" \
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
[[ "$STATUS" == "Success" ]] || { echo "FAILED" >&2; exit 1; }
