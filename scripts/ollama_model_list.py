"""List locally installed Ollama models, best generation candidate first.

The launcher still exposes every installed model in the browser. Sorting here
only picks a lighter, non-embedding model as the startup/warmup default.
"""

from __future__ import annotations

import json
import sys
import urllib.request
from typing import Any


def ordered_model_names(tags_url: str) -> list[str]:
    """Read the local Ollama tags endpoint and rank likely chat models first."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(tags_url, timeout=3) as response:
        payload: Any = json.load(response)

    models = payload.get("models", []) if isinstance(payload, dict) else []
    if not isinstance(models, list):
        return []
    installed = [
        model
        for model in models
        if isinstance(model, dict) and isinstance(model.get("name"), str) and model["name"]
    ]

    def rank(model: dict[str, Any]) -> tuple[bool, int, str]:
        name = model["name"]
        name_lower = name.lower()
        embedding_only = "embed" in name_lower or "rerank" in name_lower
        size = model.get("size")
        usable_size = size if isinstance(size, int) and not isinstance(size, bool) and size > 0 else sys.maxsize
        return embedding_only, usable_size, name

    installed.sort(key=rank)
    return [model["name"] for model in installed]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ollama_model_list.py <tags-url>", file=sys.stderr)
        return 2
    try:
        names = ordered_model_names(sys.argv[1])
    except Exception as exc:
        print(f"Ollama model discovery failed: {exc}", file=sys.stderr)
        return 1
    print(",".join(names))
    return 0 if names else 1


if __name__ == "__main__":
    raise SystemExit(main())
