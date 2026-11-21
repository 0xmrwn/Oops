"""Measure reviewed English terms in French drafts without inferring them from the text."""

import re


def reviewed_terms(case):
    terms = (case.get("tags") or {}).get("english_terms")
    if terms is None:
        return {}
    if not isinstance(terms, list) or any(
        not isinstance(term, str) or not term or term != term.strip() for term in terms
    ):
        raise ValueError(f"{case['id']}: english_terms must be a list of nonempty strings without edge whitespace.")
    if len(terms) != len(set(terms)) or (terms and case.get("lang") != "fr"):
        raise ValueError(f"{case['id']}: annotate distinct English terms only on French drafts.")
    counts = {}
    for term in terms:
        # Match the original spelling as a term, including after a French elision.
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)")
        count = len(pattern.findall(case["input"]))
        if not count or any(
            len(pattern.findall(reference)) < count
            for reference in [case["expected"], *(case.get("alternatives") or [])]
        ):
            raise ValueError(
                f"{case['id']}: each annotated English term must appear in the draft and survive in its references."
            )
        counts[pattern] = count
    return counts


def preservation(terms, text):
    total = sum(terms.values())
    if text is None:
        return {"preserved": 0, "changed": 0, "unavailable": total}
    preserved = sum(min(count, len(pattern.findall(text))) for pattern, count in terms.items())
    return {"preserved": preserved, "changed": total - preserved, "unavailable": 0}
