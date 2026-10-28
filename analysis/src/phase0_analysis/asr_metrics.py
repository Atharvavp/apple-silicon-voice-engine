"""WER and CER over normalized text (plan E1).

jiwer 4.0.0 supplies only the Levenshtein edit counts. Its transforms are
replaced by one that splits already-normalized, space-joined units, so its
default text policy never changes the definition. jiwer's own empty-reference
ratios (verified on the installed 4.0.0: ``"" vs "a b"`` gives 2, ``"" vs ""``
gives 0) are not used: a zero reference denominator is always
``not_computable`` while the insertion count is kept for auditing.
"""

from __future__ import annotations

import hashlib
from typing import Any

import jiwer

from . import normalization

_SPLIT = jiwer.Compose([jiwer.ReduceToListOfListOfWords()])


def _counts(reference: list[str], hypothesis: list[str]) -> dict[str, int]:
    if not reference and not hypothesis:
        return {"substitutions": 0, "deletions": 0, "insertions": 0, "hits": 0}
    if not reference:
        return {"substitutions": 0, "deletions": 0, "insertions": len(hypothesis), "hits": 0}
    if not hypothesis:
        return {"substitutions": 0, "deletions": len(reference), "insertions": 0, "hits": 0}
    out = jiwer.process_words(" ".join(reference), " ".join(hypothesis), reference_transform=_SPLIT,
                              hypothesis_transform=_SPLIT)
    return {"substitutions": out.substitutions, "deletions": out.deletions, "insertions": out.insertions,
            "hits": out.hits}


def _record(definition: str, units_ref: list[str], units_hyp: list[str], zero_reason: str) -> dict[str, Any]:
    counts = _counts(units_ref, units_hyp)
    components = {**counts, "reference_units": len(units_ref), "hypothesis_units": len(units_hyp),
                  "reference_sha256": hashlib.sha256("\n".join(units_ref).encode()).hexdigest(),
                  "hypothesis_sha256": hashlib.sha256("\n".join(units_hyp).encode()).hexdigest()}
    if not units_ref:
        return {"status": "not_computable", "value": None, "unit": "ratio", "definition_id": definition,
                "sample_count": 0, "clock_domain": "none", "reason": zero_reason, "components": components}
    errors = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    return {"status": "ok", "value": errors / len(units_ref), "unit": "ratio", "definition_id": definition,
            "sample_count": len(units_ref), "clock_domain": "none", "reason": None, "components": components}


def wer(reference: str, hypothesis: str) -> dict[str, Any]:
    return _record("wer_v1", normalization.words(reference), normalization.words(hypothesis), "zero_reference_tokens")


def cer(reference: str, hypothesis: str) -> dict[str, Any]:
    return _record("cer_codepoint_v1", normalization.code_points(reference), normalization.code_points(hypothesis),
                   "zero_reference_characters")
