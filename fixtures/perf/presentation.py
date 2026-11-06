#!/usr/bin/env python3
"""Review a window-only Settings capture against one General → About CUA action."""

import argparse
import json
import math
from pathlib import Path

from evidence import digest, read_json

ACTION_FIELDS = {"pid", "request_epoch_ms", "click_return_epoch_ms", "about_ax_observed_epoch_ms"}
SCORE_FLOOR = 0.015
BASELINE_MARGIN = 0.005


def number(value):
    if type(value) not in (float, int) or not math.isfinite(value) or value < 0:
        raise ValueError("expected finite, nonnegative numeric evidence")
    return value


def review(capture, action, click=None):
    if set(action) != ACTION_FIELDS or capture["pid"] != action["pid"]:
        raise ValueError("action must identify the capture PID and its three timestamp boundaries")
    request, returned, observed = [
        number(action[field]) for field in ("request_epoch_ms", "click_return_epoch_ms", "about_ax_observed_epoch_ms")
    ]
    numerator, denominator = number(capture["timebaseNumerator"]), number(capture["timebaseDenominator"])
    if numerator <= 0 or denominator <= 0:
        raise ValueError("invalid Mach timebase")
    ms_per_tick = numerator / denominator / 1e6

    def anchor(field):
        item = capture[field]
        a, b = number(item["before"]), number(item["after"])
        if not 0 <= (b - a) * ms_per_tick <= 1:
            raise ValueError("clock anchor was interrupted")
        return a + (b - a) / 2, number(item["epochSeconds"]) * 1000

    start_tick, start_epoch = anchor("before")
    end_tick, end_epoch = anchor("after")
    drift_ms = abs((end_tick - start_tick) * ms_per_tick - (end_epoch - start_epoch))
    if drift_ms > 5 or not start_epoch <= request <= returned <= observed <= end_epoch:
        raise ValueError("clock shifted or action falls outside the capture")

    if any(number(capture["statusCounts"].get(str(key), 0)) for key in (2, 3)):
        raise ValueError("capture includes blank or suspended frames")
    frames = capture["frames"]
    if not 2 <= len(frames) < 2048:
        raise ValueError("capture requires at least two frames and must stay below the capture cap")
    timed = []
    previous = 0
    for frame in frames:
        tick, score = number(frame["displayTicks"]), number(frame["meanDifference"])
        if tick <= previous or score > 1:
            raise ValueError("frame timestamps must increase and scores must be normalized")
        previous = tick
        timed.append((tick, start_epoch + (tick - start_tick) * ms_per_tick, score))

    baseline = [score for _, stamp, score in timed if stamp < request]
    if not baseline or baseline[0] != 0:
        raise ValueError("capture has no pre-action baseline frame")
    threshold = max(SCORE_FLOOR, max(baseline) + BASELINE_MARGIN)
    candidates = []
    for tick, stamp, score in reversed(timed):
        if stamp < request or score < threshold:
            break
        candidates.append((tick, stamp))
    if not candidates or candidates[-1][1] > observed:
        raise ValueError("no sustained change above the pre-action scores before About was confirmed")
    first_tick, first = candidates[-1]
    result = {
        "boundary": "cua-click-request-to-first-detected-sck-window-content-change",
        "request_to_update_ms": first - request,
        "request_to_click_return_ms": returned - request,
        "request_to_about_ax_ms": observed - request,
        "capture_pid": capture["pid"],
        "window_id": capture["windowID"],
        "change_threshold": threshold,
        "largest_baseline_score": max(baseline),
        "final_score": timed[-1][2],
        "pre_request_frames": len(baseline),
        "changed_frames": len(candidates),
        "received_frames": len(timed),
        "wall_clock_offset_drift_ms": drift_ms,
        "evidence_kind": "single-window proxy",
    }
    if click is not None:
        if (click["pid"], click["windowID"], click["timebaseNumerator"], click["timebaseDenominator"]) != (
            capture["pid"],
            capture["windowID"],
            numerator,
            denominator,
        ):
            raise ValueError("click observation does not match the capture PID, window and timebase")
        event_ms = number(click["timestampNs"]) / 1e6
        callback_ms = number(click["callbackUptimeNs"]) / 1e6
        callback_ticks_ms = number(click["callbackMachTicks"]) * ms_per_tick
        if not 0 <= callback_ms - event_ms <= 250 or abs(callback_ticks_ms - callback_ms) > 1:
            raise ValueError("click observer could not establish a shared clock")
        event_epoch = start_epoch + event_ms - start_tick * ms_per_tick
        latency = first_tick * ms_per_tick - event_ms
        if not request - 2 <= event_epoch <= returned + 2 or latency < 0:
            raise ValueError("mouse-down is outside the action bracket or after the first changed frame")
        result.update(
            mouse_down_to_update_ms=latency,
            mouse_down_to_observer_callback_ms=callback_ms - event_ms,
            mouse_down_boundary="pid-scoped-quartz-left-mouse-down-to-detected-sck-window-content-change",
        )
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path, help="watch-settings JSON")
    parser.add_argument("--action", required=True, type=Path, help="CUA action timestamps JSON")
    parser.add_argument("--click", type=Path, help="Optional PID-scoped watch-click JSON")
    args = parser.parse_args(argv)
    try:
        result = review(read_json(args.capture), read_json(args.action), read_json(args.click) if args.click else None)
        result.update(capture_sha256=digest(args.capture), action_sha256=digest(args.action))
        if args.click:
            result["click_sha256"] = digest(args.click)
        print(json.dumps({"ok": True, "data": result}, allow_nan=False))
        return 0
    except (KeyError, ValueError, TypeError, OverflowError, OSError) as error:
        message = str(error) if type(error) is ValueError else "invalid capture or action evidence"
        print(json.dumps({"ok": False, "error": {"code": "INVALID_PRESENTATION_EVIDENCE", "message": message}}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
