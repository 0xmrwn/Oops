import copy
import unittest

from presentation import review


class SettingsPresentationTests(unittest.TestCase):
    def setUp(self):
        self.capture = {
            "pid": 234,
            "windowID": 567,
            "timebaseNumerator": 125,
            "timebaseDenominator": 3,
            "before": {"before": 1_000_000_000, "after": 1_000_000_024, "epochSeconds": 100},
            "after": {"before": 1_024_000_000, "after": 1_024_000_024, "epochSeconds": 101},
            "statusCounts": {"0": 4, "1": 12},
            "frames": [
                {"displayTicks": 1_000_240_012, "meanDifference": 0},
                {"displayTicks": 1_002_400_012, "meanDifference": 0.02},
                {"displayTicks": 1_002_880_012, "meanDifference": 0.003},
                {"displayTicks": 1_003_840_012, "meanDifference": 0.20},
                {"displayTicks": 1_006_000_012, "meanDifference": 0.22},
            ],
        }
        self.action = {
            "pid": 234,
            "request_epoch_ms": 100_080,
            "click_return_epoch_ms": 100_140,
            "about_ax_observed_epoch_ms": 100_240,
        }

    def test_rejects_transient_change_and_uses_display_ticks(self):
        result = review(self.capture, self.action)
        self.assertAlmostEqual(result["request_to_update_ms"], 80)
        self.assertEqual(result["changed_frames"], 2)
        self.assertEqual(result["evidence_kind"], "single-window proxy")

    def test_refuses_suspended_noisy_and_unaligned_evidence(self):
        for mutation, reason in (
            (lambda x: x["statusCounts"].update({"3": 1}), "suspended"),
            (lambda x: x["frames"][0].update(meanDifference=0.08), "baseline"),
            (lambda x: x["after"].update(epochSeconds=101.1), "clock shifted"),
            (lambda x: x["frames"][-1].update(meanDifference=0.001), "no sustained change"),
        ):
            capture = copy.deepcopy(self.capture)
            mutation(capture)
            with self.assertRaisesRegex(ValueError, reason):
                review(capture, self.action)

    def test_click_uses_quartz_event_timestamp_and_checks_window_and_clock(self):
        click = {
            "pid": 234,
            "windowID": 567,
            "timestampNs": 41_766_667_167,
            "callbackMachTicks": 1_002_448_012,
            "callbackUptimeNs": 41_768_667_167,
            "timebaseNumerator": 125,
            "timebaseDenominator": 3,
        }
        result = review(self.capture, self.action, click)
        self.assertAlmostEqual(result["mouse_down_to_update_ms"], 60, places=5)
        self.assertAlmostEqual(result["mouse_down_to_observer_callback_ms"], 2)
        with self.assertRaisesRegex(ValueError, "match the capture"):
            review(self.capture, self.action, {**click, "windowID": 568})
        with self.assertRaisesRegex(ValueError, "shared clock"):
            review(self.capture, self.action, {**click, "callbackMachTicks": 1_000_448_012})
        with self.assertRaisesRegex(ValueError, "action bracket"):
            review(self.capture, self.action, {**click, "timestampNs": 41_700_667_167})


if __name__ == "__main__":
    unittest.main()
