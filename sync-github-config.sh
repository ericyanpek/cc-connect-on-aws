#!/bin/bash
# Sync local GitHub SSH key + git config to the cc-connect EC2 via SSM.
#
# Steps:
#   1. Stash private key, public key, ssh config snippet, and git user info into
#      SSM SecureString parameters (encrypted at rest with the AWS-managed key).
#   2. Run-Command on the EC2 to pull those parameters into ec2-user's ~/.ssh
#      and ~/.gitconfig, with correct file modes.
#   3. Delete the SSM parameters so the secret doesn't linger after rollout.
#
# Usage: ./sync-github-config.sh
set -euo pipefail

REGION="us-east-1"
STACK_NAME="cc-connect"

INSTANCE_ID="$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)"

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "Could not resolve instance id from stack $STACK_NAME" >&2
  exit 1
fi
echo "Target instance: $INSTANCE_ID"

GIT_NAME="$(git config --global user.name)"
GIT_EMAIL="$(git config --global user.email)"
PRIV_KEY_PATH="$HOME/.ssh/id_ed25519"
PUB_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

if [[ ! -f "$PRIV_KEY_PATH" ]]; then
  echo "Local SSH private key not found at $PRIV_KEY_PATH" >&2
  exit 1
fi

PARAM_PRIV="/cc-connect/github/ssh-private-key"
PARAM_PUB="/cc-connect/github/ssh-public-key"
PARAM_NAME="/cc-connect/github/git-user-name"
PARAM_EMAIL="/cc-connect/github/git-user-email"

cleanup() {
  echo "Cleaning up SSM parameters..."
  for p in "$PARAM_PRIV" "$PARAM_PUB" "$PARAM_NAME" "$PARAM_EMAIL"; do
    aws ssm delete-parameter --name "$p" --region "$REGION" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "Uploading SSH key + git identity to SSM (encrypted)..."
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_PRIV" --type SecureString \
  --value "$(cat "$PRIV_KEY_PATH")" >/dev/null
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_PUB" --type SecureString \
  --value "$(cat "$PUB_KEY_PATH")" >/dev/null
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_NAME" --type String \
  --value "$GIT_NAME" >/dev/null
aws ssm put-parameter --region "$REGION" --overwrite \
  --name "$PARAM_EMAIL" --type String \
  --value "$GIT_EMAIL" >/dev/null

# Grant the EC2 instance role temporary read on these new params.
ROLE_NAME="$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --logical-resource-id InstanceRole \
  --query 'StackResources[0].PhysicalResourceId' --output text)"
echo "Granting role $ROLE_NAME read access to GitHub config params..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadGitHubConfigParams \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"ssm:GetParameter\"],
      \"Resource\": [
        \"arn:aws:ssm:${REGION}:*:parameter/cc-connect/github/*\"
      ]
    }]
  }"

# Wait briefly for IAM to propagate.
sleep 5

REMOTE_SCRIPT='set -euo pipefail
REGION="us-east-1"
USER_HOME=/home/ec2-user

PRIV=$(aws ssm get-parameter --name /cc-connect/github/ssh-private-key --with-decryption --region "$REGION" --query Parameter.Value --output text)
PUB=$(aws ssm get-parameter --name /cc-connect/github/ssh-public-key --with-decryption --region "$REGION" --query Parameter.Value --output text)
GIT_NAME=$(aws ssm get-parameter --name /cc-connect/github/git-user-name --region "$REGION" --query Parameter.Value --output text)
GIT_EMAIL=$(aws ssm get-parameter --name /cc-connect/github/git-user-email --region "$REGION" --query Parameter.Value --output text)

install -d -m 700 -o ec2-user -g ec2-user "$USER_HOME/.ssh"

umask 077
printf "%s\n" "$PRIV" > "$USER_HOME/.ssh/id_ed25519"
printf "%s\n" "$PUB"  > "$USER_HOME/.ssh/id_ed25519.pub"
chmod 600 "$USER_HOME/.ssh/id_ed25519"
chmod 644 "$USER_HOME/.ssh/id_ed25519.pub"
chown ec2-user:ec2-user "$USER_HOME/.ssh/id_ed25519" "$USER_HOME/.ssh/id_ed25519.pub"

# ssh config for github.com
cat > "$USER_HOME/.ssh/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 "$USER_HOME/.ssh/config"
chown ec2-user:ec2-user "$USER_HOME/.ssh/config"

# known_hosts: pin GitHub fingerprints
ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$USER_HOME/.ssh/known_hosts"
sort -u "$USER_HOME/.ssh/known_hosts" -o "$USER_HOME/.ssh/known_hosts"
chmod 644 "$USER_HOME/.ssh/known_hosts"
chown ec2-user:ec2-user "$USER_HOME/.ssh/known_hosts"

# Global git identity
sudo -u ec2-user git config --global user.name  "$GIT_NAME"
sudo -u ec2-user git config --global user.email "$GIT_EMAIL"
sudo -u ec2-user git config --global init.defaultBranch main

# Verify
sudo -u ec2-user ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true'

# Encode script to avoid quoting hell.
ENCODED="$(printf '%s' "$REMOTE_SCRIPT" | base64)"

echo "Sending remote bootstrap to instance via SSM Run-Command..."
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$INSTANCE_ID" \
  --comment "Sync GitHub config from local laptop" \
  --parameters "commands=[\"echo $ENCODED | base64 -d | bash\"]" \
  --query 'Command.CommandId' --output text)"
echo "Command id: $CMD_ID"

# Poll until done.
while true; do
  STATUS="$(aws ssm get-command-invocation --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  echo "  status=$STATUS, waiting..."
  sleep 3
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

# Revoke the temporary IAM policy so the instance loses read access to those params.
echo "Revoking temporary IAM policy..."
aws iam delete-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadGitHubConfigParams || true

if [[ "$STATUS" == "Success" ]]; then
  echo "GitHub config sync OK."
else
  echo "Remote command ended with status: $STATUS" >&2
  exit 1
fi
