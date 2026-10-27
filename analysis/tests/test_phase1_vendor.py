"""`run_phase1.py verify-speech`: read-only identity check of the owned speech-swift copy (no network)."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from test_phase1_campaign import camp

FILES = camp.SPEECH_PATCHED_FILES


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


@pytest.fixture()
def owned_copy(tmp_path: Path) -> tuple[Path, str, Path]:
    """A stand-in checkout: one commit, then the two-file change; the patch is its exact diff."""
    repo = tmp_path / "speech-swift"
    repo.mkdir()
    _git(repo, "init", "-q")
    for name in [*FILES, "LICENSE"]:
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(f"upstream {name}\n")
    _git(repo, "add", ".")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "pin")
    head = _git(repo, "rev-parse", "HEAD").strip()
    for name in FILES:
        (repo / name).write_text(f"upstream {name}\npatched\n")
    patch = tmp_path / "owned.patch"
    patch.write_bytes(subprocess.run(["git", "-C", str(repo), "diff", "--no-color"], capture_output=True,
                                     check=True).stdout)
    (repo / "PHASE1_VENDOR.json").write_text('{"patch_sha256": "obsolete"}\n')
    return repo, head, patch


def _tree(repo: Path) -> dict[str, bytes]:
    return {str(p.relative_to(repo)): p.read_bytes() for p in sorted(repo.rglob("*"))
            if p.is_file() and ".git" not in p.parts}


def test_matching_copy_passes_and_is_not_modified(owned_copy):
    repo, head, patch = owned_copy
    before = _tree(repo)
    report = camp.verify_speech(repo, head, patch)
    assert report["status"] == "pass", report["problems"]
    assert report["diff_sha256"] == report["patch_sha256"] and report["changed_files"] == FILES
    assert report["recorded_vendor_record_matches_patch"] is False, "a stale record is reported, not trusted"
    assert _tree(repo) == before


@pytest.mark.parametrize("mutate, expected", [
    (lambda repo: (repo / FILES[1]).write_text("decoder changed\n"), "differs from the owned patch"),
    (lambda repo: (repo / "Extra.swift").write_text("//\n"), "unexpected untracked"),
    (lambda repo: _git(repo, "checkout", "-q", "--", FILES[1]), "changed files"),
])
def test_drifted_copy_fails(owned_copy, mutate, expected: str):
    repo, head, patch = owned_copy
    mutate(repo)
    report = camp.verify_speech(repo, head, patch)
    assert report["status"] == "fail" and any(expected in p for p in report["problems"]), report["problems"]


def test_wrong_revision_fails(owned_copy):
    repo, _, patch = owned_copy
    report = camp.verify_speech(repo, "0" * 40, patch)
    assert report["status"] == "fail" and any("not the pinned" in p for p in report["problems"])


def test_missing_checkout_fails(tmp_path: Path):
    report = camp.verify_speech(tmp_path / "absent")
    assert report["status"] == "fail"
