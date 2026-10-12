#!/usr/bin/env python3
"""Run a reviewed host-maintenance script through the local AWS CLI credentials."""
import argparse
import json
import pathlib
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("script", type=pathlib.Path)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--stack", default="cc-connect")
    parser.add_argument("--instance")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--comment", default="cc-connect host maintenance")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 172800:
        parser.error("--timeout must be between 1 and 172800 seconds.")
    if len(args.comment) > 100:
        parser.error("--comment must be at most 100 characters.")
    try:
        script = args.script.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        parser.error(f"Cannot read script: {error}")
    if not script.strip():
        parser.error("Script is empty.")
    if len(script.encode("utf-8")) > 60_000:
        parser.error("Script exceeds the SSM command payload budget.")

    def aws(*command):
        result = subprocess.run(
            ["aws", *command, "--region", args.region, "--output", "json",
             "--no-cli-pager", "--cli-connect-timeout", "10", "--cli-read-timeout", "30"],
            capture_output=True, text=True, check=False, timeout=60,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)

    instance = args.instance
    if not instance:
        stacks = aws("cloudformation", "describe-stacks", "--stack-name", args.stack)
        instance = next((
            output["OutputValue"]
            for stack in stacks.get("Stacks", [])
            for output in stack.get("Outputs", [])
            if output["OutputKey"] == "InstanceId"
        ), None)
        if not instance:
            raise RuntimeError(f"Stack {args.stack!r} has no InstanceId output; use --instance.")
    sent = aws(
        "ssm", "send-command", "--document-name", "AWS-RunShellScript",
        "--instance-ids", instance, "--comment", args.comment,
        "--parameters", json.dumps({
            "commands": [script], "executionTimeout": [str(args.timeout)],
        }),
    )
    command_id = sent["Command"]["CommandId"]
    print(f"Instance: {instance}\nCommandId: {command_id}", flush=True)
    deadline = time.monotonic() + args.timeout + 90
    last_status = None
    while time.monotonic() < deadline:
        time.sleep(4)
        try:
            result = aws(
                "ssm", "get-command-invocation", "--command-id", command_id,
                "--instance-id", instance,
            )
        except RuntimeError as error:
            if "InvocationDoesNotExist" in str(error):
                continue
            raise
        status = result["Status"]
        if status != last_status:
            print(f"Status: {status}", flush=True)
            last_status = status
        if status in ("Pending", "InProgress", "Delayed", "Cancelling"):
            continue
        print(result.get("StandardOutputContent", ""), end="")
        print(result.get("StandardErrorContent", ""), end="", file=sys.stderr)
        return 0 if status == "Success" else 1
    print(f"Polling expired; inspect SSM command {command_id}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
