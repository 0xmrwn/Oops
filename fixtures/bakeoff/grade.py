"""One case, driven and graded stage by stage.

A first pass asks Oops to correct with a stub that answers garbage: the attempt fails at the provider,
touches nothing, and logs exactly what Oops captured. The stub's real answer is that capture with the
draft's typos fixed, so whatever an editor exposes (a chip as U+FFFC, a doubled line break), the model's
answer matches it, as a real model's would. The second pass is the real correction.
"""

import re
import time

from drafts import at
from oops import ANCHORED

INVISIBLE = re.compile("[\ufffc\ufeff\u200b\u2060]")
CHROMIUM = {"chrome", "electron"}


def normalized(text, case):
    """Text compared loosely: atoms, invisible characters and spacing don't count."""
    for segment in (s for p in case["draft"]["paragraphs"] for s in p):
        if "mention" in segment:
            text = text.replace("@" + segment["mention"], "")
        if "emoji" in segment:
            text = text.replace(segment["emoji"], "")
    return " ".join(INVISIBLE.sub("", text).split())


def known_unrunnable(case):
    """Why a case can't be set up, when that's a known limit rather than a fixture bug: the WebKit
    shell's setMarkedText starts no composition inside a cross-origin frame (notes/behaviours.md)."""
    if case.get("reaction") == "ime" and case.get("embedding") == "xframe":
        return "known unrunnable: the WebKit shell can't start an IME composition inside a cross-origin frame"
    return None


def visible(case, where="inText"):
    """The draft with the composition at the caret where it shows: in the editor's text as graded
    (`inText`), or in what Accessibility hands Oops to capture (`inCapture`)."""
    composed, text = case.get("composed"), case["text"]
    if not composed or not composed.get(where):
        return text
    caret = at(text, case["caret"])
    return text[:caret] + composed["text"] + text[caret:]


def fix(text, typos):
    for wrong, right in typos.items():
        text = text.replace(wrong, right)
    return text


class CaseRun:
    def __init__(self, oops, server, host, case, nonce):
        self.oops, self.server, self.host, self.case, self.nonce = oops, server, host, case, nonce
        self.stages = {name: None for name in case["expect"]["stages"]}
        self.notes = []
        self.mutated = False  # the garbage-answer probe changed the draft: a failure whatever follows
        self.result = {
            "id": case["id"],
            "family": case["family"],
            "host": host.name,
            "expect": case["expect"]["result"],
        }

    def state(self):
        state = self.server.state(self.host.name)
        return state if state.get("nonce") == str(self.nonce) else {}

    def show(self, seconds):
        self.server.show(self.host.name, self.nonce, self.case)
        deadline = time.time() + seconds
        while time.time() < deadline:
            state = self.state()
            if state.get("error"):
                return f"page: {state['error']}"
            if state.get("ready"):
                time.sleep(0.4)  # Let the engine settle its selection and the app its accessibility tree.
                return None
            time.sleep(0.1)
        return "the shell never showed the case"

    def attempt(self, script):
        """Triggers a correction with this stub script; returns the attempt Oops logged, or None."""
        self.oops.answer(script)
        count = len(self.oops.entries("attempt"))
        self.oops.trigger("correct-lab", self.host.activation())
        return self.oops.wait("attempt", count, 30)

    def run(self, first):
        self.oops.forget()
        problem = self.show(self.host.first_load if first else 12)
        if problem:
            return self.finish(fixture=problem)
        initial = self.state()
        composing = self.case.get("reaction") == "ime"
        # Contenteditables may keep a space next to an atom as U+00A0, as browsers do.
        if (initial.get("text") or "").replace("\xa0", " ") != self.case["text"] and not composing:
            return self.finish(fixture=f"the editor holds {initial.get('text')!r}, not the case's draft")
        wanted = self.case.get("selection") or [self.case["caret"]] * 2
        if initial.get("placed") is not None and initial["placed"] != wanted:
            return self.finish(fixture=f"the selection landed at {initial['placed']}, not {wanted}")
        # The browser's own selection must match the engine's (Monaco's textarea mirrors only part of it).
        shown = initial.get("selected")
        # WebKit doesn't report a selection inside a shadow root through the document: unknown, not wrong.
        unknown = shown == "" and self.case.get("embedding") == "shadow"
        if "selection" in self.case and shown is not None and not unknown and self.case.get("engine") != "monaco":
            text = self.case["text"]
            expected = text[at(text, wanted[0]) : at(text, wanted[1])]
            if normalized(shown, self.case) != normalized(expected, self.case):
                return self.finish(fixture=f"the browser selected {shown!r}, not {expected!r}")
        if composing and not initial.get("composing"):
            return self.finish(fixture="no composition is in progress")
        probe = self.attempt({"raw": "not json"})
        time.sleep(0.5)
        after = self.state()
        untouched = after.get("text") == initial["text"] and after.get("counts") == initial.get("counts")
        if not probe:
            self.notes.append("no attempt was logged")
            return self.finish()
        self.result["capture"] = (probe.get("editor") or {}).get("capture")
        self.result["captured"] = probe.get("source")
        captured = probe.get("failedStage") != "capture" and probe.get("outcome") != "skipped"
        if self.case["expect"]["result"] == "refuses":
            return self.refusal(probe, captured, untouched)
        if not untouched:
            self.mutated = True
            self.notes.append("a failed correction changed the draft")
        if not captured:
            self.stages["capture"] = False
            self.notes.append(f"capture: {probe.get('error') or probe.get('reason') or probe.get('outcome')}")
            return self.finish()
        return self.correct(probe["source"], initial)

    def refusal(self, probe, captured, untouched):
        self.stages["refused"] = not captured
        self.stages["untouched"] = untouched
        message = probe.get("error") or probe.get("reason") or ""
        self.result["message"] = message
        self.stages["message"] = not captured and bool(re.search(self.case["expect"]["message"], message))
        if captured:
            self.notes.append("Oops read the field and asked the model")
        return self.finish()

    def correct(self, source, initial):
        case = self.case
        text = visible(case, "inCapture")
        span = case.get("selection") or case.get("span")
        start, end = (at(text, o) for o in span) if span else (0, len(text))
        expected_source = text[start:end]
        if normalized(source, case) != normalized(expected_source, case):
            self.stages["capture"] = False
            self.notes.append(f"captured {source!r}, expected {expected_source!r}")
            return self.finish()
        self.stages["capture"] = True
        since = time.time()
        delay = 2500 if self.host.name in CHROMIUM else 800
        watcher = self.oops.watch_flashes(delay / 1000 + 12)
        attempt = self.attempt({"answer": fix(source, case["typos"]), "delayMs": delay})
        time.sleep(0.8)
        final = self.state()
        # A composition Accessibility can't see is graded as committed text, as the person sees it.
        base = visible(case) if "composed" in case else initial["text"]
        low, high = (at(base, o) for o in span) if span else (0, len(base))  # base may lack the captured composition
        wanted = base[:low] + fix(base[low:high], case["typos"]) + base[high:]
        self.result["final"] = final.get("text")
        if not attempt:
            watcher.kill()
            self.notes.append("no attempt was logged for the correction")
            return self.finish()
        if attempt.get("outcome") != "fixed":
            self.notes.append(f"apply: {attempt.get('outcome')}: {attempt.get('error') or attempt.get('reason')}")
        self.stages["apply"] = (
            attempt.get("outcome") == "fixed"
            and final.get("text") == wanted
            and final.get("counts") == initial.get("counts")
        )
        if final.get("text") != wanted:
            self.notes.append(f"text after: {final.get('text')!r}")
        elif final.get("counts") != initial.get("counts"):
            self.notes.append(f"atoms after: {final.get('counts')}, before: {initial.get('counts')}")
        placement = self.oops.placement(self.host.bundle_id)
        self.result["placement"] = placement
        self.stages["placement"] = placement in ANCHORED
        frame = self.oops.field_frame(self.host.bundle_id)
        flashes = self.oops.flash_frames(watcher)
        if "highlight" in self.stages:
            rects = self.oops.flashed(since)
            covering = self.oops.field_sized(since)
            self.stages["highlight"] = bool(rects) and self.flash_inside(flashes, frame) and not covering
            if not rects:
                self.notes.append("highlight: no rects" if rects == 0 else "highlight: none asked")
            if covering:
                w, h, field = covering[0]
                self.notes.append(
                    f"highlight: {len(covering)} word pill(s) cover the field ({w}x{h} in {field[0]}x{field[1]})"
                )
        if "revert" in self.stages and attempt.get("outcome") == "fixed":
            reverts = len(self.oops.entries("revert"))
            self.oops.trigger("restore-lab", self.host.activation())
            reverted = self.oops.wait("revert", reverts, 10)
            time.sleep(0.6)
            back = self.state()
            self.stages["revert"] = (
                bool(reverted) and back.get("text") == base and back.get("counts") == initial.get("counts")
            )
            if not self.stages["revert"]:
                self.notes.append(f"revert: {'no revert logged' if not reverted else repr(back.get('text'))}")
        return self.finish()

    def flash_inside(self, flashes, frame):
        """Whether the flashed words lie on the field: the flash panel is their union grown by 8 points,
        and it must sit inside the field's own frame, give or take 6. A field drawn elsewhere and fed
        through a tiny proxy (Monaco's textarea) can't be judged this way, and neither can a missing frame."""
        if not flashes or not frame or frame[2] * frame[3] < 2000:
            self.notes.append("highlight: position not judged (no flash frame or field frame)")
            return True
        p = flashes[0]
        union = [p["x"] + 8, p["y"] + 8, p["w"] - 16, p["h"] - 16]
        self.result["flash"], self.result["field"] = union, frame
        tolerance = 6
        inside = (
            union[0] >= frame[0] - tolerance
            and union[1] >= frame[1] - tolerance
            and union[0] + union[2] <= frame[0] + frame[2] + tolerance
            and union[1] + union[3] <= frame[1] + frame[3] + tolerance
        )
        if not inside:
            self.notes.append(
                f"highlight: flashed at {[round(v) for v in union]}, outside the field at {[round(v) for v in frame]}"
            )
        return inside

    def finish(self, fixture=None):
        if fixture:
            known = known_unrunnable(self.case)
            self.result.update(
                verdict="unrunnable" if known else "fixture-error", notes=[known, fixture] if known else [fixture]
            )
            return self.result
        required = self.case["expect"]["stages"]
        self.result["stages"] = self.stages
        self.result["verdict"] = "pass" if all(self.stages[s] for s in required) and not self.mutated else "fail"
        if self.case["expect"]["result"] == "unsupported":
            self.result["verdict"] = "unsupported"  # run and recorded (its final text too), never pass or fail
        self.result["notes"] = self.notes
        return self.result
