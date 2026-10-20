"""Text normalization policy ``nfc_casefold_punct_space_cp_v1`` (plan E1).

1. NFC, ``str.casefold()``, NFC again.
2. Every Unicode general-category ``P*`` character becomes a space (Hindi danda
   included); Unicode whitespace collapses to one ASCII space; ends are
   stripped. Symbols (``S*``) are kept, so apostrophes split words.
3. Nothing else changes: Devanagari vowel signs, virama, nukta, combining
   marks, ZWJ/ZWNJ, scripts and digit systems are preserved. No
   transliteration, translation, accent removal or digit folding.

WER units are the resulting space-delimited tokens. CER units are the Unicode
code points of the normalized text with whitespace removed (not grapheme
clusters). Any edit to this module requires a new policy ID.
"""

from __future__ import annotations

import hashlib
import inspect
import sys
import unicodedata

POLICY_ID = "nfc_casefold_punct_space_cp_v1"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", unicodedata.normalize("NFC", text).casefold())
    spaced = "".join(" " if unicodedata.category(ch).startswith("P") else ch for ch in text)
    return " ".join(spaced.split())  # str.split() splits on Unicode whitespace


def words(text: str) -> list[str]:
    normalized = normalize(text)
    return normalized.split(" ") if normalized else []


def code_points(text: str) -> list[str]:
    return [ch for ch in normalize(text) if not ch.isspace()]


def policy_fingerprint() -> dict[str, str]:
    """Identity of the policy implementation and the Unicode tables it depends on."""
    source = inspect.getsource(sys.modules[__name__])
    return {"policy_id": POLICY_ID, "unicode_version": unicodedata.unidata_version,
            "implementation_sha256": hashlib.sha256(source.encode()).hexdigest()}
