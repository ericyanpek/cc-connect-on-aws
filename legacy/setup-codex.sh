#!/bin/bash
echo "Archived script: see docs/deployment.md and docs/operations.md." >&2
exit 1
# Historical only: rewrites shared Codex configuration. See ../README.md.
# Provision the Codex agent's own config + MCP servers on the cc-connect host.
# Run this BEFORE setup-agents.sh so ~/.codex/config.toml and the tavily wrapper
# exist when the daemon starts the codex project.
#
# Usage:
#   ./setup-codex.sh
#
# Prereq: the Tavily API key must be in SSM SecureString:
#   aws ssm put-parameter --name /cc-connect/tavily-api-key \
#     --value "<your tavily key>" --type SecureString --region us-east-1
#
# What it writes on the instance (as ec2-user):
#   ~/.codex/config.toml         provider=bedrock-mantle (Bedrock Mantle, OpenAI
#                                responses wire API), reads AWS_BEARER_TOKEN_BEDROCK
#                                from the daemon env (env_key), + tavily MCP server
#   ~/.tavily-key                0600, holds the Tavily key (pulled from SSM)
#   ~/.local/bin/tavily-mcp.sh   wrapper that exports the key and execs tavily-mcp
#
# Codex shares the same Bedrock bearer token as Claude Code — no separate secret.
# Tavily + DuckDuckGo MCP are also registered for Claude Code via ~/.claude.json
# (user scope); this script only handles the Codex side + the shared tavily wrapper.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="cc-connect"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"
echo "Target instance: $INSTANCE_ID"

ROLE_NAME="$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --logical-resource-id InstanceRole \
  --query 'StackResources[0].PhysicalResourceId' --output text)"

cleanup() {
  echo "Cleaning up temp IAM policy..."
  aws iam delete-role-policy --role-name "$ROLE_NAME" \
    --policy-name ReadTavilyKeyParam 2>/dev/null || true
}
trap cleanup EXIT

echo "Granting role $ROLE_NAME read access to tavily key param..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadTavilyKeyParam \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"ssm:GetParameter\"],
      \"Resource\": [
        \"arn:aws:ssm:${REGION}:*:parameter/cc-connect/tavily-api-key\"
      ]
    }]
  }"
sleep 5

REMOTE=$(cat <<'REMOTE_EOF'
set -euo pipefail
REGION="__REGION__"

# 1. Pull Tavily key from SSM into a 0600 key file (kept separate from the
#    wrapper so the key isn't embedded in an executable script on disk).
TAVILY_KEY=$(aws ssm get-parameter --name /cc-connect/tavily-api-key --with-decryption --region "$REGION" --query Parameter.Value --output text)
sudo -u ec2-user bash -c "umask 077; printf '%s' '$TAVILY_KEY' > /home/ec2-user/.tavily-key"
sudo -u ec2-user chmod 600 /home/ec2-user/.tavily-key

# 2. tavily MCP wrapper: reads the key file, execs the published MCP server.
sudo -u ec2-user mkdir -p /home/ec2-user/.local/bin
sudo -u ec2-user tee /home/ec2-user/.local/bin/tavily-mcp.sh >/dev/null <<'WRAP'
#!/bin/bash
set -euo pipefail
KEY_FILE="${TAVILY_KEY_FILE:-$HOME/.tavily-key}"
if [[ ! -r "$KEY_FILE" ]]; then
  echo "tavily-mcp wrapper: key file $KEY_FILE not readable" >&2
  exit 1
fi
export TAVILY_API_KEY
TAVILY_API_KEY="$(cat "$KEY_FILE")"
exec /usr/bin/npx -y tavily-mcp@latest
WRAP
sudo -u ec2-user chmod 755 /home/ec2-user/.local/bin/tavily-mcp.sh

# 3. ~/.codex/config.toml — provider on Bedrock Mantle, reads the shared
#    AWS_BEARER_TOKEN_BEDROCK from the daemon env via env_key.
sudo -u ec2-user mkdir -p /home/ec2-user/.codex
CODEX_CFG=/home/ec2-user/.codex/config.toml
[ -f "$CODEX_CFG" ] && sudo -u ec2-user cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%s)"
sudo -u ec2-user tee "$CODEX_CFG" >/dev/null <<'TOML'
# Default provider = bedrock-mantle (us-east-1, OpenAI responses wire API).
# /model only changes the model name within this provider (whitelist is in
# cc-connect's config.toml). codex 0.136 needs wire_api = "responses".
model = "openai.gpt-5.5"
model_provider = "bedrock-mantle"
model_reasoning_effort = "medium"
personality = "pragmatic"

[model_providers.bedrock-mantle]
name = "Amazon Bedrock Mantle (us-east-1)"
base_url = "https://bedrock-mantle.us-east-1.api.aws/openai/v1"
wire_api = "responses"
env_key = "AWS_BEARER_TOKEN_BEDROCK"

[projects."/home/ec2-user/workspaces/my-project"]
trust_level = "trusted"

[mcp_servers.tavily]
command = "/home/ec2-user/.local/bin/tavily-mcp.sh"
args = []
TOML
sudo -u ec2-user chmod 600 "$CODEX_CFG"

echo "--- codex config written ---"
sudo -u ec2-user grep -E '^model|model_provider|base_url|env_key|wire_api|command' "$CODEX_CFG"
echo "--- tavily key file perms ---"
sudo -u ec2-user ls -la /home/ec2-user/.tavily-key /home/ec2-user/.local/bin/tavily-mcp.sh
REMOTE_EOF
)
# Inject region into the single-quoted heredoc.
REMOTE="${REMOTE//__REGION__/$REGION}"

ENCODED=$(printf '%s' "$REMOTE" | base64)

echo "Sending codex/MCP provisioning via SSM Run-Command..."
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Provision codex config + tavily MCP" \
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
  echo "Codex provisioning ended with status: $STATUS" >&2
  exit 1
fi
echo "Codex config + tavily MCP provisioned. Now run ./setup-agents.sh to write"
echo "  the dual-project config.toml and (re)start the daemon."
