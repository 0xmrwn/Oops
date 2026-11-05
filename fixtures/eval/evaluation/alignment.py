"""Language-neutral word alignment, not an English grammatical parser."""

import difflib
import re
import unicodedata

VERSION = "words-v1"
TOKEN = re.compile(r"\s+|\w+|[^\w\s]", re.UNICODE)


def edits(before, after, prefix="e"):
    a, b = list(TOKEN.finditer(before)), list(TOKEN.finditer(after))
    matcher = difflib.SequenceMatcher(None, [x.group() for x in a], [x.group() for x in b], autojunk=False)
    result = []
    for tag, i, j, k, m in matcher.get_opcodes():
        if tag == "equal":
            continue
        start = a[i].start() if i < len(a) else len(before)
        end = a[j - 1].end() if j > i else start
        replacement = "".join(x.group() for x in b[k:m])
        if result and before[result[-1]["end"] : start] in {" ", "\t"}:
            old = result[-1]
            old["after"] += before[old["end"] : start] + replacement
            old["end"] = end
            old["before"] = before[old["start"] : end]
        else:
            result.append(
                {
                    "id": f"{prefix}{len(result)}",
                    "start": start,
                    "end": end,
                    "before": before[start:end],
                    "after": replacement,
                }
            )
    return result


def signature(edit):
    return edit["start"], edit["end"], edit["after"]


def optional_capital_accent(edit, language):
    if language not in {"fr", "mixed"}:
        return False
    before, after = edit["before"], edit["after"]

    def strip(s):
        return "".join(c for c in unicodedata.normalize("NFD", s) if not unicodedata.combining(c))

    return (
        before != after
        and strip(before) == strip(after)
        and len(before) == len(after)
        and all(
            a == b or (a.isupper() and b.isupper() and strip(a) == a and strip(b) == a) for a, b in zip(before, after)
        )
    )
