"""Collect shortcut latency around an isolated lab's key-down and editor observer."""

import time


def measure(press, wait_for_editor, state, peak_rss_bytes, download_bytes):
    """press returns key-down monotonic_ns; observer returns True on applied/clear, False on terminal failure."""
    start = press()
    success = wait_for_editor()
    end = time.monotonic_ns()
    return {
        "shortcut_ns": start,
        "editor_terminal_ns": end,
        "successful": success,
        "state": state,
        "peak_rss_bytes": peak_rss_bytes(),
        "download_bytes": download_bytes,
    }
