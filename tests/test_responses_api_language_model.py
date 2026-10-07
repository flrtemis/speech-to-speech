import logging
import os
from queue import Queue
from threading import Event
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import httpx
from openai import Stream
from openai.types.responses import (
    Response,
    ResponseFunctionToolCall,
    ResponseOutputItemDoneEvent,
    ResponseOutputMessage,
    ResponseTextDeltaEvent,
)
from openai.types.responses.response_output_text import ResponseOutputText

from speech_to_speech.api.openai_realtime.runtime_config import RuntimeConfig
from speech_to_speech.LLM.chat import Chat, make_user_message
from speech_to_speech.LLM.responses_api_language_model import ResponsesApiModelHandler
from speech_to_speech.pipeline.cancel_scope import CancelScope
from speech_to_speech.pipeline.messages import EndOfResponse, GenerateResponseRequest, LLMResponseChunk, TokenUsage


def _make_text_delta_event(text):
    evt = MagicMock(spec=ResponseTextDeltaEvent)
    evt.type = "response.output_text.delta"
    evt.delta = text
    return evt


def _make_output_item_done_event(role="assistant", content="Hello.", item_type="message"):
    evt = MagicMock(spec=ResponseOutputItemDoneEvent)
    evt.type = "response.output_item.done"
    if item_type == "function_call":
        evt.item = SimpleNamespace(
            type="function_call",
            model_dump=lambda: {"type": "function_call", "name": "test_fn"},
        )
    else:
        evt.item = SimpleNamespace(
            type="message",
            role=role,
            content=content,
        )
    return evt


def _make_stream(events):
    stream = MagicMock(spec=Stream)
    stream.__iter__.return_value = iter(events)
    return stream


def _make_function_call_done_event(name="camera", arguments="{}"):
    return ResponseOutputItemDoneEvent(
        type="response.output_item.done",
        output_index=1,
        sequence_number=2,
        item=ResponseFunctionToolCall(
            type="function_call",
            call_id="call_original",
            name=name,
            arguments=arguments,
        ),
    )


def _make_response(output, usage=None):
    resp = MagicMock(spec=Response)
    resp.usage = usage
    resp.output = output
    return resp


def _make_runtime_config(chat_size=2, instructions="You are a helpful AI assistant."):
    from openai.types.realtime import RealtimeSessionCreateRequest

    return RuntimeConfig(
        chat=Chat(chat_size),
        session=RealtimeSessionCreateRequest(type="realtime", instructions=instructions),
    )


def _make_request(text="Hi", chat_size=2):
    cfg = _make_runtime_config(chat_size=chat_size)
    cfg.chat.add_item(make_user_message(text))
    return GenerateResponseRequest(runtime_config=cfg)


def _make_handler(*, disable_thinking=False, stream=True, cancel_scope=None):
    handler = object.__new__(ResponsesApiModelHandler)
    handler.model_name = "test-model"
    handler.stream = stream
    handler.stream_batch_sentences = 1
    handler.gen_kwargs = {}
    handler.request_timeout_s = 20.0
    handler.request_timeout = 20.0
    handler.disable_thinking = disable_thinking
    handler.ollama_models = frozenset()
    handler.ollama_enabled = False
    handler.ollama_url = "http://127.0.0.1:11434"
    handler._ollama_models_refresh_at = 0.0
    handler._extra_body = {"chat_template_kwargs": {"enable_thinking": False}} if disable_thinking else None
    handler.user_role = "user"
    handler.cancel_scope = cancel_scope
    handler.speculative_turns = None
    handler.tools = None
    handler.tools_choice = None
    handler.enable_lang_prompt = False
    handler.compactor = None
    return handler


def test_process_streams_text_from_response_events():
    handler = _make_handler()

    streamed_events = [
        _make_text_delta_event("Hello. "),
        _make_text_delta_event("How are you?"),
        _make_output_item_done_event(content="Hello. How are you?"),
    ]

    handler.client = SimpleNamespace(
        responses=SimpleNamespace(
            create=lambda **kwargs: _make_stream(streamed_events),
        )
    )

    outputs = list(handler.process(_make_request("Hi")))

    assert len(outputs) == 3
    assert isinstance(outputs[0], LLMResponseChunk) and outputs[0].text == "Hello."
    assert isinstance(outputs[1], LLMResponseChunk) and outputs[1].text == "How are you?"
    assert isinstance(outputs[2], EndOfResponse)


def test_process_flushes_tool_lead_in_before_function_call_with_sentence_batching():
    handler = _make_handler()
    handler.stream_batch_sentences = 3

    streamed_events = [
        _make_text_delta_event("Let me check with my camera."),
        _make_function_call_done_event(name="camera"),
    ]

    handler.client = SimpleNamespace(
        responses=SimpleNamespace(
            create=lambda **kwargs: _make_stream(streamed_events),
        )
    )

    outputs = list(handler.process(_make_request("What do you see?")))

    assert len(outputs) == 3
    assert isinstance(outputs[0], LLMResponseChunk)
    assert outputs[0].text == "Let me check with my camera."
    assert outputs[0].tools == []
    assert isinstance(outputs[1], LLMResponseChunk)
    assert outputs[1].text == ""
    assert [tool.name for tool in outputs[1].tools] == ["camera"]
    assert isinstance(outputs[2], EndOfResponse)


def test_process_preserves_streamed_text_after_function_call_order():
    handler = _make_handler()
    handler.stream_batch_sentences = 3

    streamed_events = [
        _make_text_delta_event("Let me check."),
        _make_function_call_done_event(name="camera"),
        _make_text_delta_event("This may take a second."),
    ]

    handler.client = SimpleNamespace(
        responses=SimpleNamespace(
            create=lambda **kwargs: _make_stream(streamed_events),
        )
    )

    outputs = list(handler.process(_make_request("What do you see?")))

    assert len(outputs) == 4
    assert isinstance(outputs[0], LLMResponseChunk)
    assert outputs[0].text == "Let me check."
    assert outputs[0].tools == []
    assert isinstance(outputs[1], LLMResponseChunk)
    assert outputs[1].text == ""
    assert [tool.name for tool in outputs[1].tools] == ["camera"]
    assert isinstance(outputs[2], LLMResponseChunk)
    assert outputs[2].text == "This may take a second."
    assert outputs[2].tools == []
    assert isinstance(outputs[3], EndOfResponse)


def test_process_preserves_nonstreaming_text_tool_text_order():
    handler = _make_handler(stream=False)

    api_response = _make_response(
        output=[
            ResponseOutputMessage(
                id="msg_1",
                type="message",
                role="assistant",
                status="completed",
                content=[ResponseOutputText(type="output_text", text="Let me check.", annotations=[])],
            ),
            ResponseFunctionToolCall(
                type="function_call",
                call_id="call_original",
                name="camera",
                arguments="{}",
            ),
            ResponseOutputMessage(
                id="msg_2",
                type="message",
                role="assistant",
                status="completed",
                content=[ResponseOutputText(type="output_text", text="This may take a second.", annotations=[])],
            ),
        ],
    )

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=lambda **kwargs: api_response))

    outputs = list(handler.process(_make_request("What do you see?")))

    assert len(outputs) == 4
    assert isinstance(outputs[0], LLMResponseChunk)
    assert outputs[0].text == "Let me check."
    assert outputs[0].tools == []
    assert isinstance(outputs[1], LLMResponseChunk)
    assert outputs[1].text == ""
    assert [tool.name for tool in outputs[1].tools] == ["camera"]
    assert isinstance(outputs[2], LLMResponseChunk)
    assert outputs[2].text == "This may take a second."
    assert outputs[2].tools == []
    assert isinstance(outputs[3], EndOfResponse)


def test_process_handles_cancellation():
    scope = CancelScope()
    handler = _make_handler(cancel_scope=scope)

    def fake_create(**kwargs):
        scope.cancel()
        return _make_stream([_make_text_delta_event("Hello")])

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=fake_create))

    outputs = list(handler.process(_make_request("Hi")))

    assert len(outputs) == 1
    assert isinstance(outputs[0], EndOfResponse)


def test_responses_api_timing_logs_only_text_chunks():
    handler = object.__new__(ResponsesApiModelHandler)
    handler._times = [0.01]

    assert handler.timing_log_level == logging.INFO
    assert handler.should_log_timing(LLMResponseChunk(text="Hello."))
    assert not handler.should_log_timing(TokenUsage(input_tokens=1, output_tokens=1))
    assert not handler.should_log_timing(EndOfResponse())


def test_process_read_timeout_ends_response_cleanly():
    handler = _make_handler()

    def make_timeout_stream():
        stream = MagicMock(spec=Stream)
        stream.__iter__.side_effect = httpx.ReadTimeout("timed out")
        return stream

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=lambda **kwargs: make_timeout_stream()))

    outputs = list(handler.process(_make_request("Hi")))

    assert len(outputs) == 2
    assert (
        isinstance(outputs[0], LLMResponseChunk)
        and outputs[0].text == "Wow I'm a bit slow today, could you repeat that?"
    )
    assert isinstance(outputs[1], EndOfResponse)


def test_disable_thinking_passes_extra_body():
    handler = _make_handler(disable_thinking=True)
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _make_stream(
            [
                _make_text_delta_event("Ok"),
                _make_output_item_done_event(content="Ok"),
            ]
        )

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=fake_create))

    list(handler.process(_make_request("Hi")))

    assert captured["extra_body"] == {"chat_template_kwargs": {"enable_thinking": False}}


def test_ollama_setup_uses_native_think_flag_for_warmup():
    client = SimpleNamespace(responses=SimpleNamespace(create=MagicMock()))
    setup_kwargs = {
        "model_name": "gemma4:latest",
        "base_url": "http://127.0.0.1:11434/v1",
        "api_key": "ollama",
        "disable_thinking": True,
        "compact_history": False,
    }

    with (
        patch.dict(
            os.environ,
            {
                "S2S_OLLAMA_ENABLED": "1",
                "S2S_OLLAMA_MODELS": "gemma4:latest",
                "S2S_OLLAMA_URL": "http://127.0.0.1:11434",
            },
        ),
        patch("speech_to_speech.LLM.responses_api_language_model.OpenAI", return_value=client),
    ):
        ResponsesApiModelHandler(Event(), Queue(), Queue(), setup_kwargs=setup_kwargs)

    assert client.responses.create.call_args.kwargs["extra_body"] == {"think": False}


def test_no_disable_thinking_omits_extra_body():
    handler = _make_handler(disable_thinking=False)
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _make_stream(
            [
                _make_text_delta_event("Ok"),
                _make_output_item_done_event(content="Ok"),
            ]
        )

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=fake_create))

    list(handler.process(_make_request("Hi")))

    assert captured.get("extra_body") is None


def test_generate_uses_allowlisted_model_from_live_session_config():
    handler = _make_handler()
    handler.ollama_enabled = True
    handler._extra_body = {"think": False}
    handler.ollama_models = frozenset({"default-ollama", "chosen-ollama"})
    runtime_config = _make_runtime_config()
    runtime_config.session.model = "chosen-ollama"
    chat = runtime_config.chat
    chat.add_item(make_user_message("Hi"))
    captured = {}

    def fake_create(**kwargs):
        captured.update(kwargs)
        return _make_stream([_make_text_delta_event("Hello.")])

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=fake_create))
    list(
        handler._generate(
            active_chat=chat.copy(),
            original_chat=chat,
            language_code=None,
            gen=None,
            runtime_config=runtime_config,
            response=None,
            optional_kwargs={},
            turn_id=None,
            turn_revision=None,
            speech_stopped_at_s=None,
        )
    )

    assert captured["model"] == "chosen-ollama"
    assert captured["extra_body"] == {"think": False}
    assert captured["max_output_tokens"] == 128


def test_generate_accepts_a_newly_installed_ollama_model_after_refresh():
    handler = _make_handler()
    handler.ollama_enabled = True
    handler.ollama_models = frozenset({"default-ollama"})
    runtime_config = SimpleNamespace(session=SimpleNamespace(model="newly-installed"))
    tags_response = SimpleNamespace(
        raise_for_status=lambda: None,
        json=lambda: {"models": [{"name": "default-ollama"}, {"name": "newly-installed"}]},
    )

    with patch(
        "speech_to_speech.LLM.responses_api_language_model.httpx.get",
        return_value=tags_response,
    ):
        assert handler._model_for_runtime_config(runtime_config) == "newly-installed"


def test_generate_ignores_uninstalled_session_model():
    handler = _make_handler()
    handler.ollama_enabled = True
    handler.ollama_models = frozenset({"chosen-ollama"})
    runtime_config = SimpleNamespace(session=SimpleNamespace(model="arbitrary-model"))
    tags_response = SimpleNamespace(
        raise_for_status=lambda: None,
        json=lambda: {"models": [{"name": "chosen-ollama"}]},
    )

    with patch(
        "speech_to_speech.LLM.responses_api_language_model.httpx.get",
        return_value=tags_response,
    ):
        assert handler._model_for_runtime_config(runtime_config) == "test-model"


def test_second_turn_flattens_assistant_history_for_responses():
    handler = _make_handler(stream=False)
    captured = {}
    cfg = _make_runtime_config(chat_size=2)

    first_response = _make_response(
        output=[
            ResponseOutputMessage(
                id="msg_1",
                type="message",
                role="assistant",
                status="completed",
                content=[ResponseOutputText(type="output_text", text="Hello.", annotations=[])],
            )
        ],
    )
    second_response = _make_response(output=[])
    call_count = 0

    def fake_create(**kwargs):
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            return first_response
        captured.update(kwargs)
        return second_response

    handler.client = SimpleNamespace(responses=SimpleNamespace(create=fake_create))

    cfg.chat.add_item(make_user_message("Hi"))
    list(handler.process(GenerateResponseRequest(runtime_config=cfg)))
    cfg.chat.add_item(make_user_message("Again"))
    list(handler.process(GenerateResponseRequest(runtime_config=cfg)))

    assistant_items = [item for item in captured["input"] if item.get("role") == "assistant"]
    assert len(assistant_items) == 1
    ai = assistant_items[0]
    assert ai["role"] == "assistant"
    assert ai["type"] == "message"
    assert ai["status"] == "completed"
    assert len(ai["content"]) == 1
    assert ai["content"][0]["type"] == "output_text"
    assert ai["content"][0]["text"] == "Hello."
