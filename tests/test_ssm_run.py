"""Exercise SSM state transitions without AWS credentials or remote commands."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "ssm_runner", Path(__file__).resolve().parents[1] / "scripts/ssm-run.py"
)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def reply(payload, returncode=0):
    if returncode:
        return subprocess.CompletedProcess([], returncode, "", payload)
    return subprocess.CompletedProcess([], 0, json.dumps(payload), "")


SENT = {"Command": {"CommandId": "test-command"}}


class SSMTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.script = Path(self.directory.name) / "check.sh"
        self.script.write_text("printf '检查\\n'\n", encoding="utf-8")
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self.enterContext(redirect_stdout(self.stdout))
        self.enterContext(redirect_stderr(self.stderr))
        self.enterContext(patch.object(RUNNER.time, "sleep"))

    def run_main(self, *arguments):
        with patch("sys.argv", ["ssm-run.py", str(self.script), *arguments]):
            return RUNNER.main()

    @patch.object(RUNNER.subprocess, "run")
    def test_delayed_invocation_then_success_and_exact_script(self, aws):
        aws.side_effect = [
            reply({"Stacks": [{"Outputs": [{"OutputKey": "InstanceId", "OutputValue": "i-test"}]}]}),
            reply(SENT),
            reply("InvocationDoesNotExist", 1),
            reply({"Status": "InProgress"}),
            reply({"Status": "Success", "StandardOutputContent": "ok\n"}),
        ]
        self.assertEqual(self.run_main(), 0)
        sent_args = aws.call_args_list[1].args[0]
        parameters = json.loads(sent_args[sent_args.index("--parameters") + 1])
        self.assertEqual(parameters["commands"], [self.script.read_text()])
        self.assertEqual(parameters["executionTimeout"], ["900"])
        self.assertIn("CommandId: test-command", self.stdout.getvalue())
        self.assertIn("ok\n", self.stdout.getvalue())

    @patch.object(RUNNER.subprocess, "run")
    def test_all_remote_failure_states_are_failures(self, aws):
        for status in ("Failed", "Cancelled", "TimedOut"):
            with self.subTest(status=status):
                aws.reset_mock()
                aws.side_effect = [
                    reply(SENT),
                    reply({"Status": status, "StandardErrorContent": "remote failed\n"}),
                ]
                self.assertEqual(self.run_main("--instance", "i-test"), 1)
                self.assertNotIn("describe-stacks", aws.call_args_list[0].args[0])
        self.assertIn("remote failed", self.stderr.getvalue())

    @patch.object(RUNNER.subprocess, "run")
    def test_access_denied_is_not_retried_as_pending(self, aws):
        aws.side_effect = [reply(SENT), reply("AccessDeniedException", 1)]
        with self.assertRaisesRegex(RuntimeError, "AccessDeniedException"):
            self.run_main("--instance", "i-test")
        self.assertEqual(aws.call_count, 2)

    @patch.object(RUNNER.subprocess, "run")
    def test_missing_stack_output_does_not_send_command(self, aws):
        aws.return_value = reply({"Stacks": [{}]})
        with self.assertRaisesRegex(RuntimeError, "no InstanceId output"):
            self.run_main()
        self.assertEqual(aws.call_count, 1)

    @patch.object(RUNNER.time, "monotonic", side_effect=[0, 1000])
    @patch.object(RUNNER.subprocess, "run", return_value=reply(SENT))
    def test_polling_timeout_keeps_command_id_for_followup(self, aws, monotonic):
        self.assertEqual(self.run_main("--instance", "i-test", "--timeout", "1"), 1)
        self.assertIn("inspect SSM command test-command", self.stderr.getvalue())
        self.assertEqual(aws.call_count, 1)

    @patch.object(RUNNER.subprocess, "run")
    def test_invalid_arguments_are_rejected_before_aws(self, aws):
        for arguments in (
            ("--timeout", "0"), ("--timeout", "172801"), ("--comment", "x" * 101),
        ):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit) as error:
                self.run_main(*arguments)
            self.assertEqual(error.exception.code, 2)
        aws.assert_not_called()

    @patch.object(RUNNER.subprocess, "run")
    def test_empty_oversized_or_missing_scripts_do_not_call_aws(self, aws):
        for content in (" \n", "中" * 20001):
            self.script.write_text(content)
            with self.assertRaises(SystemExit) as error:
                self.run_main()
            self.assertEqual(error.exception.code, 2)
        self.script.unlink()
        with self.assertRaises(SystemExit):
            self.run_main()
        aws.assert_not_called()


if __name__ == "__main__":
    unittest.main()
