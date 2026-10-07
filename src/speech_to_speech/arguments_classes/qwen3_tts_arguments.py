from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Qwen3TTSHandlerArguments:
    qwen3_tts_model_name: str = field(
        default="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
        metadata={
            "help": "The Qwen3-TTS model to use (HuggingFace Hub ID or local path). Default is 'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice'. On Apple Silicon, Qwen/* model IDs are auto-mapped to the corresponding mlx-community/* model when possible, defaulting to the 6bit MLX variant unless the model name already pins a specific suffix."
        },
    )
    qwen3_tts_backend: str = field(
        default="torch",
        metadata={
            "help": "Qwen3-TTS runtime backend on CUDA. 'torch' (default) uses faster-qwen3-tts with CUDA "
            "graphs. 'ggml' uses the bundled qwentts.cpp runtime with GGUF weights — much lower VRAM, "
            "optional flash attention. Requires --qwen3_tts_gguf_talker_path and "
            "--qwen3_tts_gguf_codec_path, plus the qwentts_cpp library (pip install qwentts-cpp)."
        },
    )
    qwen3_tts_gguf_talker_path: Optional[str] = field(
        default=None,
        metadata={"help": "Path to the talker GGUF (e.g. qwen-talker-1.7b-customvoice-BF16.gguf). Required for --qwen3_tts_backend ggml."},
    )
    qwen3_tts_gguf_codec_path: Optional[str] = field(
        default=None,
        metadata={"help": "Path to the codec/tokenizer GGUF (e.g. qwen-tokenizer-12hz-BF16.gguf). Required for --qwen3_tts_backend ggml."},
    )
    qwen3_tts_qwentts_library_path: Optional[str] = field(
        default=None,
        metadata={"help": "Optional explicit path to the libqwen shared library used by the ggml backend."},
    )
    qwen3_tts_use_fa: bool = field(
        default=True,
        metadata={"help": "Use flash-attention kernels in the ggml backend. Default is True."},
    )
    qwen3_tts_ref_cache_dir: Optional[str] = field(
        default=None,
        metadata={"help": "Cache directory for ggml voice-clone references (.spk/.rvq) extracted from reference audio."},
    )
    qwen3_tts_device: str = field(
        default="cuda",
        metadata={
            "help": "Preferred device for Qwen3-TTS. Options: 'cuda', 'cpu', 'mps', 'auto'. Default is 'cuda'. On Apple Silicon the mlx-audio backend is selected automatically."
        },
    )
    qwen3_tts_dtype: str = field(
        default="auto",
        metadata={
            "help": "Data type for inference. Options: 'auto', 'float16', 'bfloat16', 'float32'. Default is 'auto'."
        },
    )
    qwen3_tts_attn_implementation: str = field(
        default="eager",
        metadata={
            "help": "Attention implementation. Options: 'eager', 'flash_attention_2', 'sdpa'. Use 'eager' on Jetson. Default is 'eager'."
        },
    )
    qwen3_tts_ref_audio: Optional[str] = field(
        default=None,
        metadata={
            "help": "Optional path to reference audio file for voice cloning. Leave unset when using a CustomVoice model."
        },
    )
    qwen3_tts_ref_text: str = field(
        default="I'm confused why some people have super short timelines, yet at the same time are bullish on scaling up reinforcement learning atop LLMs. If we're actually close to a human-like learner, then this whole approach of training on verifiable outcomes.",
        metadata={"help": "Transcription of the reference audio for voice cloning."},
    )
    qwen3_tts_speaker: Optional[str] = field(
        default="Aiden",
        metadata={
            "help": "Speaker name for CustomVoice models. Default is 'Aiden'. If not provided, the first supported speaker is used when available."
        },
    )
    qwen3_tts_instruct: Optional[str] = field(
        default=None,
        metadata={"help": "Instruction text for VoiceDesign models (optional, required for voice design)."},
    )
    qwen3_tts_xvec_only: bool = field(
        default=False,
        metadata={
            "help": "Use x-vector only voice cloning mode (recommended for cleaner starts and language switching). Default is False."
        },
    )
    qwen3_tts_parity_mode: bool = field(
        default=False,
        metadata={"help": "Disable CUDA-graph streaming path and use parity mode for stability. Default is False."},
    )
    qwen3_tts_non_streaming_mode: Optional[bool] = field(
        default=True,
        metadata={
            "help": "Optional override for Qwen3-TTS text prefill behavior. Default is true, which pre-fills the full target text before decode on faster-qwen3-tts. Currently ignored on Apple Silicon because mlx-audio does not expose this yet."
        },
    )
    qwen3_tts_mlx_quantization: Optional[str] = field(
        default="6bit",
        metadata={
            "help": "Optional MLX quantization override on Apple Silicon. Supported values: 'bf16', '4bit', '6bit', '8bit'. Default is '6bit'."
        },
    )
    qwen3_tts_language: str = field(
        default="auto",
        metadata={"help": "Target language for synthesis. Default is 'auto'."},
    )
    qwen3_tts_streaming_chunk_size: Optional[int] = field(
        default=None,
        metadata={
            "help": "Codec steps per streaming chunk. If unset, the handler uses a backend-specific default: 8 on faster-qwen3-tts and 4 on mlx-audio."
        },
    )
    qwen3_tts_max_new_tokens: int = field(
        default=1536,
        metadata={
            "help": "Upper cap for Qwen3-TTS codec tokens. The handler estimates a per-utterance budget from the text and clamps it to this ceiling (~12 tokens per second of audio). Raise this above 1536 if you want to allow longer utterances."
        },
    )
    qwen3_tts_blocksize: int = field(
        default=512,
        metadata={
            "help": "Audio chunk size in samples for streaming output. Must match LocalAudioStreamer blocksize. Default is 512."
        },
    )
