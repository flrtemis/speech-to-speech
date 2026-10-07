from __future__ import annotations

from pathlib import Path

import pytest

from speech_to_speech.utils import hf_cache


def _clear_offline_flags(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    monkeypatch.delenv("TRANSFORMERS_OFFLINE", raising=False)


def test_offline_model_id_resolves_to_cached_snapshot(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _clear_offline_flags(monkeypatch)
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    snapshot = tmp_path / "snapshots" / "abcdef"
    snapshot.mkdir(parents=True)
    calls: list[tuple[str, bool]] = []

    def fake_snapshot_download(repo_id: str, *, local_files_only: bool) -> str:
        calls.append((repo_id, local_files_only))
        return str(snapshot)

    monkeypatch.setattr(hf_cache, "snapshot_download", fake_snapshot_download)

    resolved, local_only = hf_cache.resolve_hf_model_path("Qwen/example")

    assert resolved == str(snapshot)
    assert local_only is True
    assert calls == [("Qwen/example", True)]


def test_online_model_id_remains_a_hub_id(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_offline_flags(monkeypatch)

    def unexpected_snapshot_download(*_args: object, **_kwargs: object) -> str:
        pytest.fail("online model ids should not be resolved as offline snapshots")

    monkeypatch.setattr(hf_cache, "snapshot_download", unexpected_snapshot_download)

    resolved, local_only = hf_cache.resolve_hf_model_path("Qwen/example")

    assert resolved == "Qwen/example"
    assert local_only is False


def test_local_model_directory_is_always_loaded_locally(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()

    resolved, local_only = hf_cache.resolve_hf_model_path(str(model_dir))

    assert resolved == str(model_dir)
    assert local_only is True


def test_offline_cache_miss_has_actionable_error(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear_offline_flags(monkeypatch)
    monkeypatch.setenv("TRANSFORMERS_OFFLINE", "1")

    def missing_snapshot(*_args: object, **_kwargs: object) -> str:
        raise OSError("no cached snapshot")

    monkeypatch.setattr(hf_cache, "snapshot_download", missing_snapshot)

    with pytest.raises(RuntimeError, match="could not be resolved from the local Hugging Face cache"):
        hf_cache.resolve_hf_model_path("Qwen/not-cached")
