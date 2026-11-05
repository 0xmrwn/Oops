#!/usr/bin/env python3
"""Headless checks that a wrong browser field cannot masquerade as compatibility acceptance."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("compat_run", Path(__file__).with_name("run.py"))
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)


class ProbeTests(unittest.TestCase):
    def test_wrong_field_is_rejected_before_typing(self):
        with tempfile.TemporaryDirectory() as work:
            probe = compat.Probe(Path(work), "http://127.0.0.1:1234/index.html")
            probe.trigger = Mock(return_value={"ok": True, "role": "AXTextField", "fieldDescription": "Search"})
            with (
                patch.object(compat, "installed", return_value=True),
                patch.object(compat.subprocess, "run"),
                patch.object(compat.time, "sleep"),
            ):
                result = probe.app(dict(name="Safari textarea", bundle="com.apple.Safari", open=[], scratch=True))
            self.assertTrue(compat.failed_result(result))
            self.assertTrue(all(call.args[0] == "focus" for call in probe.trigger.call_args_list))

    def test_page_wide_read_cannot_supply_stub_answer(self):
        with tempfile.TemporaryDirectory() as work:
            probe = compat.Probe(Path(work), "http://127.0.0.1:1234/index.html")
            field = {"ok": True, "role": "AXTextArea", "fieldDescription": "Message"}
            probe.trigger = Mock(
                side_effect=[field, {**field, "value": "Page labels and another draft " + compat.DRAFT}]
            )
            with (
                patch.object(compat, "installed", return_value=True),
                patch.object(compat.subprocess, "run"),
                patch.object(compat.time, "sleep"),
            ):
                result = probe.app(dict(name="Zen textarea", bundle="app.zen-browser.zen", open=[], scratch=True))
            self.assertTrue(compat.failed_result(result))
            self.assertFalse(probe.stub.exists())
            self.assertNotIn("correct", [call.args[0] for call in probe.trigger.call_args_list])

    def run_main(self, result):
        with tempfile.TemporaryDirectory() as work, contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(compat.sys, "argv", ["run.py", "--no-build", "TextEdit"]))
            stack.enter_context(patch.object(compat.tempfile, "mkdtemp", return_value=work))
            stack.enter_context(patch.object(compat.e2e, "build"))
            stack.enter_context(patch.object(compat.e2e, "quit_oops"))
            stack.enter_context(patch.object(compat.subprocess, "run"))
            stack.enter_context(patch.object(compat.time, "sleep"))
            stack.enter_context(patch.object(compat.threading, "Thread"))
            server = stack.enter_context(patch.object(compat.http.server, "ThreadingHTTPServer")).return_value
            server.server_port = 1234
            probe = stack.enter_context(patch.object(compat, "Probe")).return_value
            probe.app.return_value = result
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            return compat.main()

    def test_failed_real_probe_cannot_exit_successfully(self):
        good = dict(app="TextEdit", capture="ok", apply="ok", revert="ok", highlight="2 rects")
        self.assertEqual(self.run_main(good), 0)
        self.assertEqual(self.run_main({**good, "apply": "failed: Nothing replaced."}), 1)
        self.assertEqual(self.run_main({**good, "highlight": "none placed"}), 1)
        self.assertEqual(self.run_main(dict(app="TextEdit", capture="fixture error: wrong field")), 1)

    def test_optional_editor_absence_is_explicitly_unverified(self):
        absent = dict(app="Notion", capture="no editor: none found")
        self.assertTrue(compat.failed_result(absent))
        self.assertFalse(compat.failed_result({**absent, "optional": True}))


if __name__ == "__main__":
    unittest.main()
