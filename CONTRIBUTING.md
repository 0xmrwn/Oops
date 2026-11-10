# Contributing

Oops does not accept external pull requests. Open an issue to report a bug or
suggest a change.

For a bug, include the Oops version, macOS version, affected app and steps to
reproduce it. Say what you expected and what happened. A short example using
made-up text helps, especially when an editor or selection behaves differently.

For an idea, describe the problem and how you run into it. If you've investigated
the code, include the relevant file, diagnosis or a small diff in the issue.

Read what you submit and check that the details are accurate. Remove private
drafts, API keys and sign-in tokens from logs and screenshots.

For local builds and checks, see the [README](README.md#build).

A development build and the released Oops share a bundle identifier but are
signed differently, so System Settings keeps one Accessibility row for both,
tied to whichever was allowed first. When you switch between them, remove Oops
from Privacy & Security → Accessibility with the minus button, then allow the
build you're running. Switching the existing row on is not enough.
Report security vulnerabilities [privately](SECURITY.md).
