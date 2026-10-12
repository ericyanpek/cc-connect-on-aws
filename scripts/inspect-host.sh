#!/usr/bin/env bash
# Read-only status for SSM Run Command. Never dump credentials or chat logs.
set -euo pipefail

for binary in cc-connect claude codex node; do
    "/usr/bin/$binary" --version
done

EC2_UID=$(id -u ec2-user)
sudo -u ec2-user env XDG_RUNTIME_DIR="/run/user/$EC2_UID" \
    systemctl --user show cc-connect \
    -p ActiveState -p SubState -p MainPID -p NRestarts -p DropInPaths

python3.12 - <<'PY'
from pathlib import Path
import json
import tomllib

home = Path("/home/ec2-user")
paths = (
    home / ".cc-connect/config.toml",
    home / ".cc-connect/agents/codex/config.toml",
)
for path in paths:
    data = tomllib.loads(path.read_text())
    summary = {"file": str(path), "toml_valid": True}
    if path == paths[0]:
        summary["projects"] = []
        for project in data.get("projects", []):
            agent = project["agent"]
            options = agent.get("options", {})
            active = next((p for p in agent.get("providers", [])
                           if p["name"] == options.get("provider")), {})
            summary["projects"].append({
                "name": project["name"], "agent": agent["type"],
                "work_dir": options.get("work_dir"), "mode": options.get("mode"),
                "provider": options.get("provider"), "model": active.get("model"),
                "codex_home": options.get("codex_home"),
            })
    else:
        summary.update({
            "provider": data.get("model_provider"),
            "sandbox": data.get("sandbox_mode"),
            "approval": data.get("approval_policy"),
            "mcp_servers": sorted(data.get("mcp_servers", {})),
            "plugins": sorted(data.get("plugins", {})),
        })
    print(json.dumps(summary, ensure_ascii=False))
PY
