import io
import json
from types import SimpleNamespace
from unittest.mock import patch

from scripts.ollama_model_list import ordered_model_names


def test_ollama_default_ranks_small_non_embedding_models_first():
    payload = {
        "models": [
            {"name": "gemma4:31b", "size": 19_000_000_000},
            {"name": "gemma4:latest", "size": 9_600_000_000},
            {"name": "qwen3-embedding:0.6b", "size": 639_000_000},
            {"name": "gpt-oss:20b", "size": 13_000_000_000},
        ]
    }
    opener = SimpleNamespace(open=lambda *_args, **_kwargs: io.BytesIO(json.dumps(payload).encode()))

    with patch("scripts.ollama_model_list.urllib.request.build_opener", return_value=opener):
        models = ordered_model_names("http://127.0.0.1:11434/api/tags")

    assert models[0] == "gemma4:latest"
    assert set(models) == {item["name"] for item in payload["models"]}
