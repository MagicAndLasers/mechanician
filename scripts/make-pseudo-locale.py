#!/usr/bin/env python3
"""Generate an `en-XA` pseudo-locale into a String Catalog.

Localization readiness is a claim that cannot be checked by reading code: the only way to see whether
a string on screen came from the catalogue is to make the catalogue's answer visibly different. So
every entry gets an accented, bracketed, padded variant.

Three properties, each doing a job:

* **accented** — proves the string was resolved through the catalogue. An unaccented string on screen
  is an unlocalized one, which makes this the detector, not only a layout test.
* **bracketed** — shows where a string starts and ends, so a truncated one is obvious and a
  concatenation of two strings is visible as `[…][…]`.
* **padded ~35%** — European translations of English run longer. Padding finds the views that clip
  before a real translation would.

Format specifiers (`%@`, `%lld`, `%1$@`) and interpolation markers are passed through untouched: a
mangled specifier crashes at runtime rather than looking wrong, which would make this instrument
worse than useless.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PSEUDO_LANGUAGE = "en-XA"
ACCENTS = str.maketrans({
    "a": "á", "b": "ƀ", "c": "ç", "d": "ð", "e": "é", "f": "ƒ", "g": "ĝ", "h": "ĥ",
    "i": "í", "j": "ĵ", "k": "ķ", "l": "ł", "m": "ṁ", "n": "ñ", "o": "ö", "p": "þ",
    "q": "ɋ", "r": "ř", "s": "š", "t": "ţ", "u": "ú", "v": "ṽ", "w": "ŵ", "x": "ẋ",
    "y": "ý", "z": "ž",
    "A": "Á", "B": "Ɓ", "C": "Ç", "D": "Ð", "E": "É", "F": "Ƒ", "G": "Ĝ", "H": "Ĥ",
    "I": "Í", "J": "Ĵ", "K": "Ķ", "L": "Ł", "M": "Ṁ", "N": "Ñ", "O": "Ö", "P": "Þ",
    "Q": "Ɋ", "R": "Ř", "S": "Š", "T": "Ţ", "U": "Ú", "V": "Ṽ", "W": "Ŵ", "X": "Ẋ",
    "Y": "Ý", "Z": "Ž",
})
# Anything a formatter or SwiftUI will consume must survive untouched.
# A printf specifier is not one letter: `%lld` is `%` + the `ll` length modifier + `d`. Matching
# only the final letter left `ld` to be accented into `%lłð`, which crashes a formatter rather than
# merely looking wrong — the exact failure this instrument must not introduce.
PRESERVED = re.compile(
    r"("
    r"%%"                                     # a literal percent
    r"|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?"     # index, flags, width, precision
    r"(?:hh|h|ll|l|q|L|z|j|t)?[@a-zA-Z]"      # length modifier, then the conversion
    r"|\{[^}]*\}"                            # a brace placeholder
    r"|<[^>]+>"                               # inline markup
    r"|\\\(.*?\)"                            # a Swift interpolation that reached the catalogue
    r")"
)


def pseudo(value: str) -> str:
    if not value:
        return value
    parts = PRESERVED.split(value)
    accented = "".join(
        part if PRESERVED.fullmatch(part or "") else (part or "").translate(ACCENTS)
        for part in parts
    )
    padding = "·" * max(1, round(len(value) * 0.35))
    return f"[{accented}{padding}]"


def source_value(key: str, entry: dict, language: str) -> str | None:
    """The English text an entry actually renders, which for most entries is the key itself."""
    unit = (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("value")
    )
    return unit if unit is not None else key


def add_pseudo(entry: dict, key: str, source_language: str) -> None:
    localizations = entry.setdefault("localizations", {})
    existing = localizations.get(source_language, {})

    variations = existing.get("variations")
    if variations:
        # A plural entry pseudo-localizes every variant, so a wrong plural form is visible too.
        rebuilt = {
            kind: {
                category: {
                    "stringUnit": {
                        "state": "translated",
                        "value": pseudo(case["stringUnit"]["value"]),
                    }
                }
                for category, case in cases.items()
            }
            for kind, cases in variations.items()
        }
        localizations[PSEUDO_LANGUAGE] = {"variations": rebuilt}
        return

    value = source_value(key, entry, source_language)
    localizations[PSEUDO_LANGUAGE] = {
        "stringUnit": {"state": "translated", "value": pseudo(value or key)}
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make-pseudo-locale.py <input.xcstrings> <output.xcstrings>", file=sys.stderr)
        return 2
    source, destination = Path(sys.argv[1]), Path(sys.argv[2])
    catalog = json.loads(source.read_text())
    language = catalog.get("sourceLanguage", "en")
    for key, entry in catalog.get("strings", {}).items():
        add_pseudo(entry, key, language)
    destination.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"    pseudo-locale {PSEUDO_LANGUAGE}: {len(catalog.get('strings', {}))} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
