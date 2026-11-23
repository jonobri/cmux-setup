#!/usr/bin/env python3
"""Tests for enrich-notification.py. Run: python3 hooks/test_enrich_notification.py"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "enrich-notification.py")

spec = importlib.util.spec_from_file_location("enrich", SCRIPT)
enrich = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enrich)


def run_hook(payload, home):
    """Run the hook the way cmux does: JSON on stdin, JSON on stdout."""
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    result = subprocess.run(
        [sys.executable, SCRIPT], input=raw, capture_output=True, text=True,
        env={**os.environ, "HOME": home}, timeout=10,
    )
    return result.returncode, result.stdout


class Classify(unittest.TestCase):
    def test_cmux_category_wins_over_text(self):
        # A finished turn that happens to say "permission" is not a permission prompt.
        agent = {"category": "turn-complete", "pending": False}
        self.assertEqual(enrich.classify("Claude Code", "", "I fixed the permission bug", agent), "turn complete")

    def test_needs_permission_category(self):
        self.assertEqual(enrich.classify("x", "", "y", {"category": "needs-permission"}), "permission needed")

    def test_idle_reminder_category(self):
        self.assertEqual(enrich.classify("x", "", "y", {"category": "idle-reminder"}), "waiting for you")

    def test_pending_background_work(self):
        agent = {"category": "turn-complete", "pending": True}
        self.assertEqual(enrich.classify("x", "", "all done", agent), "done, background tasks running")

    def test_question_in_a_finished_turn_is_a_decision(self):
        agent = {"category": "turn-complete", "pending": False}
        self.assertEqual(enrich.classify("x", "", "Should I delete the old branch?", agent), "needs a decision")

    def test_text_fallback_without_agent_block(self):
        self.assertEqual(enrich.classify("Claude permission", "", "Bash needs approval"), "permission needed")
        self.assertEqual(enrich.classify("x", "", "API Error: 500"), "error")
        self.assertIsNone(enrich.classify("x", "", "hello there"))


class Markdown(unittest.TestCase):
    def test_strips_syntax_keeps_words(self):
        self.assertEqual(enrich.strip_markdown("**Delete 12**, keep `6`"), "Delete 12, keep 6")

    def test_keeps_filenames_and_issue_numbers(self):
        self.assertEqual(enrich.strip_markdown("edit __init__.py for PR #138"), "edit __init__.py for PR #138")

    def test_keeps_shell_globs(self):
        self.assertEqual(enrich.strip_markdown("run rm -rf build/*"), "run rm -rf build/*")


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def test_rewrites_title_with_workspace_and_action(self):
        payload = {
            "notification": {"title": "Claude Code", "body": "All **done**", "surfaceId": "s1"},
            "agent": {"category": "turn-complete", "pending": False},
            "context": {"cwd": "/work/my-project"},
        }
        code, out = run_hook(payload, self.home)
        self.assertEqual(code, 0)
        note = json.loads(out)["notification"]
        self.assertEqual(note["title"], "my-project — turn complete")
        self.assertEqual(note["body"], "All done")

    def test_invalid_json_passes_through_untouched(self):
        code, out = run_hook("this is not json", self.home)
        self.assertEqual(code, 0)
        self.assertEqual(out, "this is not json")

    def test_empty_notification_passes_through_untouched(self):
        raw = json.dumps({"notification": {}})
        code, out = run_hook(raw, self.home)
        self.assertEqual((code, out), (0, raw))

    def test_idle_reminder_gets_the_earlier_detail_back(self):
        first = {"notification": {"title": "Claude Code", "body": "Delete 12, keep 6?", "surfaceId": "s2"},
                 "agent": {"category": "turn-complete"}, "context": {"cwd": "/w/p"}}
        reminder = {"notification": {"title": "Claude Code", "body": "Claude is waiting for your input", "surfaceId": "s2"},
                    "agent": {"category": "idle-reminder"}, "context": {"cwd": "/w/p"}}
        run_hook(first, self.home)
        _, out = run_hook(reminder, self.home)
        self.assertEqual(json.loads(out)["notification"]["body"], "Delete 12, keep 6?")


if __name__ == "__main__":
    unittest.main()
