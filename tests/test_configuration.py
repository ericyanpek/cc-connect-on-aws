"""Guard the relationships that previously caused deployment/config drift."""
import json
from pathlib import Path
import subprocess
import tomllib
import unittest

from cfnlint.decode import decode

ROOT = Path(__file__).resolve().parents[1]


class ConfigurationTests(unittest.TestCase):
    def test_version_manifest_matches_bootstrap_and_readme(self):
        versions = json.loads((ROOT / "versions.json").read_text())
        template, errors = decode(str(ROOT / "cc-connect-stack.yaml"))
        self.assertFalse(errors)
        readme = (ROOT / "README.md").read_text()
        userdata = template["Resources"]["Instance"]["Properties"]["UserData"]["Fn::Base64"]["Fn::Sub"]
        for package, parameter in {
            "cc-connect": "CcConnectVersion",
            "@anthropic-ai/claude-code": "ClaudeCodeVersion",
            "@openai/codex": "CodexVersion",
        }.items():
            self.assertEqual(template["Parameters"][parameter]["Default"], versions[package])
            self.assertIn(f"{package}@${{{parameter}}}", userdata)
            self.assertIn(f"`{versions[package]}`", readme)
        self.assertEqual(versions["cc-connect"], "1.5.0")
        self.assertIn(f"setup_{versions['node_major']}.x", userdata)
        self.assertIn(versions["checked_on"], readme)
        self.assertIn(versions["integration_tested_on"], readme)

    def test_model_authority_and_codex_isolation(self):
        cc = tomllib.loads((ROOT / "examples/cc-connect.example.toml").read_text())
        codex = tomllib.loads((ROOT / "examples/codex.example.toml").read_text())
        template, _ = decode(str(ROOT / "cc-connect-stack.yaml"))
        userdata = template["Resources"]["Instance"]["Properties"]["UserData"]["Fn::Base64"]["Fn::Sub"]
        admins = []
        for project in cc["projects"]:
            agent = project["agent"]
            options = agent["options"]
            self.assertNotIn("model", options, "Provider must own the default model")
            active = [p for p in agent["providers"] if p["name"] == options["provider"]]
            self.assertEqual(len(active), 1)
            self.assertIn(active[0]["model"], [m["model"] for m in active[0]["models"]])
            for provider in agent["providers"]:
                for field in ("api_key", "base_url"):
                    self.assertNotIn(field, provider)
            admins.append(project["admin_from"])
            for platform in project["platforms"]:
                self.assertEqual(platform["options"]["allow_from"], project["admin_from"])
                self.assertNotEqual(platform["options"]["allow_from"], "*")
            if agent["type"] == "codex":
                self.assertEqual(options["provider"], codex["model_provider"])
                self.assertEqual(options["backend"], "app_server")
                self.assertEqual(options["app_server_url"], "stdio")
                self.assertEqual(options["mode"], "auto-edit")
                self.assertIn(f'Environment="CODEX_HOME={options["codex_home"]}"', userdata)
                self.assertNotEqual(options["codex_home"], "/home/ec2-user/.codex")
        self.assertEqual(len(set(admins)), 2, "App-scoped IDs need separate placeholders")
        self.assertNotIn("model", codex)
        self.assertEqual(codex["sandbox_mode"], "workspace-write")
        provider = codex["model_providers"][codex["model_provider"]]
        self.assertEqual(provider["env_key"], "CC_CODEX_BEDROCK_API_KEY")
        env = (ROOT / "examples/cc-connect.env.example").read_text()
        self.assertIn(f'{provider["env_key"]}=', env)
        self.assertIn("AWS_BEARER_TOKEN_BEDROCK=", env)

    def test_legacy_scripts_exit_before_side_effects(self):
        scripts = list((ROOT / "legacy").glob("*.sh"))
        self.assertEqual(len(scripts), 8)
        for script in scripts:
            with self.subTest(script=script.name):
                result = subprocess.run(
                    ["/bin/bash", str(script)], capture_output=True, text=True,
                    env={"PATH": "/nonexistent"}, timeout=5,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "Archived script: see docs/deployment.md and docs/operations.md.\n",
                )


if __name__ == "__main__":
    unittest.main()
