from __future__ import annotations

import os
from pathlib import Path

from huggingface_hub import snapshot_download


def resolve_hf_model_path(model_name: str) -> tuple[str, bool]:
    """Resolve a cached Hub model ID to its local snapshot when offline.

    Some Transformers tokenizer and processor code paths call the Hub's
    ``model_info`` API even when all model files are cached. Passing the
    snapshot directory avoids that metadata request. The boolean indicates
    whether downstream loaders must use local files only.
    """
    local_path = Path(model_name).expanduser()
    if local_path.is_dir():
        return str(local_path), True

    offline = any(
        os.environ.get(variable, "").strip().lower() in {"1", "true", "yes", "on"}
        for variable in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE")
    )
    if not offline:
        return model_name, False

    try:
        snapshot_path = snapshot_download(repo_id=model_name, local_files_only=True)
    except Exception as error:
        raise RuntimeError(
            f"Offline mode is enabled, but model {model_name!r} could not be resolved from the local Hugging Face cache. "
            "Check HF_HOME/HF_HUB_CACHE, or run once with S2S_ONLINE=1 to download it."
        ) from error
    return str(snapshot_path), True
