#!/usr/bin/env python3
"""Headless checks that the focus round trip writes only into a field it verified and removes only what it wrote."""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import focus_trip  # noqa: E402

LAB = {"ok": True, "role": "AXTextArea", "fieldDescription": "Message", "value": "sample", "element": 7}


class Probe:
    """Answers each action from `states`, and records the actions."""

    def __init__(self, states):
        self.states, self.calls = states, []
        self.work, self.lab_url = Path("/tmp"), "http://127.0.0.1:1/index.html"

    def trigger(self, action, bundle, text=None):
        self.calls.append((action, text))
        state = self.states.get(action, {"ok": True})
        return state(text) if callable(state) else dict(state)


def session(probe, **kwargs):
    return focus_trip.Session(probe, installed=lambda _: True, **kwargs)


class FocusTripTests(unittest.TestCase):
    def setUp(self):
        for target in (focus_trip.time, focus_trip.subprocess):
            patcher = patch.object(target, "sleep" if target is focus_trip.time else "run")
            patcher.start()
            self.addCleanup(patcher.stop)

    def actions(self, probe):
        return [action for action, _ in probe.calls]

    def test_a_manual_field_with_text_is_skipped_never_written(self):
        probe = Probe({"read": {"ok": True, "value": "an unsent message", "element": 3}})
        trip = session(probe, confirm=lambda _: "yes")
        result = trip.trip(focus_trip.MANUAL[0])
        trip.cleanup()
        self.assertIn("skipped", result["trip"])
        self.assertNotIn("write", self.actions(probe))
        self.assertNotIn("clear", self.actions(probe))

    def test_a_manual_field_must_be_confirmed(self):
        probe = Probe({"read": {"ok": True, "value": "", "element": 3}})
        result = session(probe, confirm=lambda _: "").trip(focus_trip.MANUAL[0])
        self.assertEqual(result["trip"], "skipped: not confirmed")
        self.assertNotIn("write", self.actions(probe))

    def test_a_browser_field_that_isnt_the_labs_is_never_written(self):
        probe = Probe({"focus": {"ok": True, "role": "AXTextField", "fieldDescription": "Search", "value": "q"}})
        result = session(probe).trip(focus_trip.OWN[1])
        self.assertIn("not the lab's Message field", result["trip"])
        self.assertNotIn("write", self.actions(probe))

    def test_cleanup_clears_only_the_field_written_and_only_the_probes_text(self):
        probe = Probe(
            {
                "focus": LAB,
                "write": {"ok": True, "element": 7},
                "select": {"ok": True, "element": 7, "selection": [6, 4]},
                "read": {"ok": True, "element": 7, "value": ""},
                "focus-trip": {"ok": True, "trip": {"panelWasKey": True}},
                "focus-trip-refocus": {"ok": True, "trip": {"refocused": True}},
            }
        )
        trip = session(probe)
        result = trip.trip(focus_trip.OWN[1])
        trip.cleanup()
        clears = [text for action, text in probe.calls if action == "clear"]
        self.assertEqual(len(clears), 2, "after each trip, and nothing more at cleanup")
        self.assertTrue(all(text.split("\t")[0] == "7" and focus_trip.DRAFT in text.split("\t") for text in clears))
        self.assertNotIn("remove", self.actions(probe))
        self.assertIn("first", result)

    def test_the_second_trip_needs_the_same_field_again(self):
        probe = Probe(
            {
                "focus": LAB,
                "write": {"ok": True, "element": 7},
                "select": {"ok": True, "element": 7, "selection": [6, 4]},
                "read": {"ok": True, "element": 9, "value": ""},
            }
        )
        result = session(probe).trip(focus_trip.OWN[1])
        self.assertEqual(self.actions(probe).count("write"), 1)
        self.assertEqual(result["refocus"], {})

    def test_a_note_in_obsidian_is_made_and_deleted(self):
        obsidian = dict(name="Obsidian", bundle="md.obsidian", obsidian=True, focus="largest")
        with tempfile.TemporaryDirectory() as vault:
            probe = Probe({"focus": {"ok": True, "role": "AXTextArea", "value": ""}})
            trip = session(probe, vault=lambda: Path(vault))
            trip.trip(obsidian)
            note = trip.note
            self.assertIsNotNone(note)
            note.write_text("")
            trip.cleanup()
            self.assertFalse(note.exists())

    def test_only_the_probes_own_drafts_by_default(self):
        names = [a["name"] for a in focus_trip.apps([dict(name="Notes"), dict(name="Mail")], False)]
        self.assertEqual(names[0], "TextEdit")
        self.assertNotIn("Notes", names)
        self.assertNotIn("Slack", names)
        self.assertIn("Notes", [a["name"] for a in focus_trip.apps([dict(name="Notes")], True)])


if __name__ == "__main__":
    unittest.main()
