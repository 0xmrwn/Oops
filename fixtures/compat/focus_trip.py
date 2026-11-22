"""The focus round trip for fixtures/compat/run.py --focus-trip: in each app, a scratch draft with "beta" selected,
then a key panel of Oops's takes the keys for a moment and gives them back. Whether the field keeps its focus and
selection, with and without Oops setting them back, decides where the Actions wheel's centre may take typing
(WheelTyping.unavailable).

By default only drafts that are the probe's own: a new untitled TextEdit document (close it without saving after)
and the composer lab's Message field in Safari, Chrome and Zen. --personal-apps adds apps that hold a person's own
notes and mail (Notes, Mail, a new Obsidian note, Notion) and, by hand, Slack and Excel: the run waits for the cursor
in your own Slack "You" DM composer, never a conversation with others (nothing is sent), and in a cell being edited
in a new Excel workbook, and asks you to confirm it.

The probe only ever writes into a field it has verified: the lab's Message field, or an empty field. A field that
already holds text is skipped and reported, never written. It removes only what it wrote: the field's whole text,
when that field is still the one it wrote into and its text is exactly one of the probe's own values."""

import subprocess
import time

DRAFT = "alpha beta gamma"
BETA = "6,4"
# The field's whole text after the probe: its draft, with the panel's "q" or the marker "§" typed into it.
LEFTOVERS = [DRAFT, "alpha § gamma", "alpha q gamma", "alpha beta gamma§", "alpha beta gammaq", "alpha §q gamma"]

# The probe's own drafts, measured by default.
OWN = [
    dict(name="TextEdit", bundle="com.apple.TextEdit", open=[["open", "-a", "TextEdit"]], new=True),
    *[
        dict(
            name=f"{browser} {field}",
            bundle=bundle,
            open=[["open", "-a", app, f"{{lab}}?probe={field}#{anchor}"]],
            scratch=True,
        )
        for browser, bundle, app in (
            ("Safari", "com.apple.Safari", "Safari"),
            ("Chrome", "com.google.Chrome", "Google Chrome"),
            ("Zen", "app.zen-browser.zen", "Zen"),
        )
        for field, anchor in (("textarea", "chat-textarea"), ("contenteditable", "chat"))
    ],
]
PERSONAL = ("Notes", "Mail", "Obsidian", "Notion")

MANUAL = [
    dict(name="Slack", bundle="com.tinyspeck.slackmacgap", manual="your own Slack DM composer (You)", optional=True),
    dict(
        name="Excel", bundle="com.microsoft.Excel", manual="a cell being edited in a new Excel workbook", optional=True
    ),
]


def apps(all_apps, personal_apps):
    """What --focus-trip measures: the probe's own drafts, and with --personal-apps the apps of the person."""
    return OWN + ([a for a in all_apps if a["name"] in PERSONAL] + MANUAL if personal_apps else [])


def available(first, second):
    """The rule WheelTyping.unavailable is filled by."""
    if not (
        first.get("panelWasKey")
        and first.get("keysReachedPanel")
        and first.get("frontDuring") == first.get("frontBefore")
    ):
        return False
    kept = (
        first.get("sameElement")
        and first.get("selectionAfter") == first.get("selectionBefore")
        and first.get("landedAtSelection")
    )
    return bool(kept or (second.get("refocused") and second.get("landedAtSelection")))


def scratch_field(state):
    """The composer lab's Message field, which is the probe's to write."""
    return bool(state.get("ok")) and state.get("role") == "AXTextArea" and state.get("fieldDescription") == "Message"


def empty(state):
    return bool(state.get("ok")) and not (state.get("value") or "").strip()


class Session:
    """One --focus-trip run: what it wrote and where, so cleanup removes that and nothing else."""

    def __init__(self, probe, installed, vault=lambda: None, confirm=input):
        self.probe, self.installed, self.vault, self.confirm = probe, installed, vault, confirm
        self.written = None  # (bundle, element) holding the probe's draft, until it is cleared
        self.note = None  # a scratch note the run made, to delete

    def target(self, spec, result):
        """Opens the app's draft field and verifies it is the probe's to write: its state, or None with the reason
        in `result`."""
        probe, bundle = self.probe, spec["bundle"]
        if spec.get("manual"):
            print(f"Put the cursor in {spec['manual']} within 30 s (nothing will be sent).", flush=True)
            deadline = time.time() + 30
            while time.time() < deadline and "isn’t in front" in (probe.trigger("read", bundle).get("error") or ""):
                time.sleep(1)
            state = probe.trigger("read", bundle)
            if not empty(state):
                result["trip"] = "skipped: no empty field" if state.get("ok") else "not in front"
                return None
            answer = self.confirm(f"Is the cursor in {spec['manual']}, and is it empty? Type yes to go on: ")
            if (answer or "").strip().lower() != "yes":
                result["trip"] = "skipped: not confirmed"
                return None
            return state
        if spec.get("obsidian"):
            vault = self.vault()
            if not vault:
                result["trip"] = "no open vault"
                return None
            note = f"Oops probe {int(time.time())}"
            self.note = vault / f"{note}.md"
            name, title = vault.name.replace(" ", "%20"), note.replace(" ", "%20")
            commands = [["open", f"obsidian://new?vault={name}&name={title}"]]
        else:
            commands = [
                [part.replace("{scratch}", str(probe.work)).replace("{lab}", probe.lab_url) for part in c]
                for c in spec["open"]
            ]
        for command in commands:
            subprocess.run(command, check=False)
        time.sleep(4)
        subprocess.run(["open", "-b", bundle])
        time.sleep(1.5)
        if spec.get("new"):
            probe.trigger("new", bundle)
            time.sleep(1.5)
        focus = "largest" if spec.get("scratch") or spec.get("obsidian") else spec.get("focus")
        state = probe.trigger("focus", bundle, focus)
        if spec.get("scratch"):
            if not scratch_field(state):
                result["trip"] = "skipped: not the lab's Message field"
                return None
        elif not empty(state):
            result["trip"] = "skipped: the field has text" if state.get("ok") else f"no editor: {state.get('error')}"
            return None
        return state

    def write(self, spec, result):
        """Types the probe's draft into the verified field and selects "beta": the state, or None."""
        bundle = spec["bundle"]
        written = self.probe.trigger("write", bundle, DRAFT)
        if written.get("ok") and written.get("element") is not None:
            self.written = (bundle, written["element"])
        state = self.probe.trigger("select", bundle, BETA)
        if self.written is None or state.get("element") != self.written[1] or state.get("selection") != [6, 4]:
            result["trip"] = "no scratch draft with a selection"
            return None
        return state

    def clear(self):
        """Removes the probe's draft, only from the field it wrote into and only when its whole text is the probe's."""
        if self.written is None:
            return
        bundle, element = self.written
        self.probe.trigger("clear", bundle, "\t".join([str(element), *LEFTOVERS]))
        self.written = None

    def trip(self, spec):
        result = {"app": spec["name"], "bundle": spec["bundle"]}
        if not self.installed(spec["bundle"]):
            return {**result, "trip": "not installed"}
        if not self.target(spec, result) or not self.write(spec, result):
            return result
        first = (self.probe.trigger("focus-trip", spec["bundle"]) or {}).get("trip") or {}
        element = self.written[1]
        self.clear()
        # The same field again, checked again: still the one written into, and empty once the draft went.
        again = self.probe.trigger("read", spec["bundle"])
        second = {}
        if empty(again) and again.get("element") == element and self.write(spec, result):
            second = (self.probe.trigger("focus-trip-refocus", spec["bundle"]) or {}).get("trip") or {}
        self.clear()
        return {**result, "first": first, "refocus": second, "available": available(first, second)}

    def cleanup(self):
        """Whatever happened: the probe's draft, where it is still there, and its scratch note."""
        self.clear()
        if self.note:
            self.note.unlink(missing_ok=True)
            self.note = None


def table(results):
    rows = [
        "| App | Key | Keys reached | Front kept | Same field | Selection kept | Landed | Refocused | Landed after | Available |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]

    def mark(value):
        return "–" if value is None else ("yes" if value else "no")

    for r in results:
        if "first" not in r:
            rows.append(f"| {r['app']} | {r.get('trip') or r.get('capture') or '–'} |  |  |  |  |  |  |  |  |")
            continue
        a, b = r["first"], r["refocus"]
        rows.append(
            f"| {r['app']} | {mark(a.get('panelWasKey'))} | {mark(a.get('keysReachedPanel'))} | "
            f"{mark(a.get('frontDuring') == a.get('frontBefore'))} | {mark(a.get('sameElement'))} | "
            f"{mark(a.get('selectionAfter') == a.get('selectionBefore'))} | {mark(a.get('landedAtSelection'))} | "
            f"{mark(b.get('refocused'))} | {mark(b.get('landedAtSelection'))} | {mark(r['available'])} |"
        )
    return "\n".join(rows)
