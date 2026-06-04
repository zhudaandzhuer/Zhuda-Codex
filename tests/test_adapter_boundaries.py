#!/usr/bin/env python3
"""Lightweight adapter boundary checks without network calls."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path

from fastapi import HTTPException


ROOT = Path(__file__).resolve().parents[1]
ADAPTER_PATH = ROOT / "mac" / "zhuda_gemini_pool_adapter.py"


def load_adapter():
    spec = importlib.util.spec_from_file_location("zhuda_adapter_under_test", ADAPTER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to import adapter from {ADAPTER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load_adapter()


def reset_env(provider: str = "mimo") -> None:
    for key in list(os.environ):
        if (
            key.startswith("ZHUDA_")
            or key.startswith("GEMINI_")
            or key.startswith("MIMO_")
            or key.startswith("XIAOMI_MIMO_")
            or key.startswith("DEEPSEEK_")
        ):
            os.environ.pop(key, None)
    os.environ["ZHUDA_DOTENV_PATH"] = "/tmp/zhuda-codex-test-env-does-not-exist"
    os.environ["ZHUDA_PROVIDER"] = provider


def test_mimo_context_budget() -> None:
    reset_env("mimo")
    payload = {
        "input": [
            {"type": "message", "role": "system", "content": "system guidance " * 2500},
            {"type": "message", "role": "user", "content": "recent request " * 1000},
            {"type": "function_call_output", "call_id": "call_1", "output": "A" * 60000},
            {"type": "message", "role": "assistant", "content": "assistant reply " * 3000},
            {"type": "message", "role": "user", "content": "final user instruction " * 1400},
        ],
    }
    text = adapter.extract_input_text(payload)
    tokens = adapter.estimate_tokens(text)
    assert tokens <= 12350, f"MiMo context was not trimmed enough: {tokens}"
    assert "older context and long tool outputs were trimmed" in text


def test_mimo_timeout_visible_message() -> None:
    reset_env("mimo")
    error = HTTPException(
        status_code=502,
        detail={"error": "mimo_pool_failed", "details": ["mimo-v2.5-pro:key_1:timeout_after_90s:"]},
    )
    text = adapter.visible_error_text("gpt-5.5", "mimo-v2.5-pro", error, 13000, 0)
    assert "upstream timeout" in text
    assert "Upstream status: timeout" in text
    assert "通常不是餘額不足" in text


def test_mimo_cooldown_visible_message() -> None:
    reset_env("mimo")
    error = HTTPException(status_code=503, detail={"error": "mimo_cooling_down", "cooldownSeconds": 88, "details": []})
    text = adapter.visible_error_text("gpt-5.5", "mimo-v2.5-pro", error, 0, 0)
    assert "adapter cooldown" in text
    assert "Upstream status: cooldown" in text
    assert "沒有再燒請求" in text


def test_gemini_tpm_429_is_short_wait_not_daily() -> None:
    reset_env("gemini")
    raw = """
    {
      "error": {
        "code": 429,
        "message": "Quota exceeded for quota metric 'Generate Content Input Tokens Per Model Per Minute'",
        "details": [
          {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "3.700s"},
          {"quotaId": "GenerateContentInputTokensPerModelPerMinute-FreeTier"}
        ]
      }
    }
    """
    assert adapter.is_short_rate_limit_error(raw)
    assert not adapter.is_daily_quota_error(raw)
    assert adapter.retry_delay_seconds_from_error(raw, 45) == 4


def test_gemini_daily_429_is_visible_daily_quota() -> None:
    reset_env("gemini")
    raw = """
    {
      "error": {
        "code": 429,
        "message": "Quota exceeded for quota metric 'Generate Requests Per Day'",
        "details": [{"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]
      }
    }
    """
    assert adapter.is_daily_quota_error(raw)
    error = HTTPException(status_code=429, detail={"error": "gemini_daily_quota_exhausted", "details": [f"gemini-3.5-flash:key_1:429:daily_quota_exhausted:{raw}"]})
    text = adapter.visible_error_text("gpt-5.4", "gemini-3.5-flash", error, 0, 0)
    assert "daily quota exhausted" in text
    assert "日額度用完" in text


def test_text_tool_markup_parsing() -> None:
    reset_env("mimo")
    markup = (
        "<tool_call><function=shell>"
        "<parameter=command>rg \"c_gateChu\" /tmp/project</parameter>"
        "<parameter=description>Explore project</parameter>"
        "</function></tool_call>"
    )
    call = adapter.function_call_from_text_tool_markup(markup, [{"name": "exec_command"}])
    assert call == {"name": "exec_command", "arguments": {"cmd": 'rg "c_gateChu" /tmp/project'}}


def test_visible_models_are_direct_identity_aliases() -> None:
    reset_env("mimo")
    os.environ["ZHUDA_VISIBLE_MODELS"] = "mimo-v2.5-pro,mimo-v2.5"
    aliases = adapter.model_aliases()
    assert adapter.visible_model_ids() == ["mimo-v2.5-pro", "mimo-v2.5"]
    assert aliases["mimo-v2.5-pro"] == "mimo-v2.5-pro"
    assert aliases["mimo-v2.5"] == "mimo-v2.5"


def test_deepseek_visible_models_are_direct_identity_aliases() -> None:
    reset_env("deepseek")
    os.environ["ZHUDA_VISIBLE_MODELS"] = "deepseek-v4-pro,deepseek-v4-flash"
    aliases = adapter.model_aliases()
    assert adapter.visible_model_ids() == ["deepseek-v4-pro", "deepseek-v4-flash"]
    assert adapter.resolve_model("gpt-5.5") == "deepseek-v4-pro"
    assert adapter.resolve_model("gpt-5.4-mini") == "deepseek-v4-flash"
    assert adapter.resolve_model("gemini-3.5-flash") == "deepseek-v4-pro"
    assert aliases["deepseek-v4-pro"] == "deepseek-v4-pro"
    assert aliases["deepseek-v4-flash"] == "deepseek-v4-flash"


def test_openai_chat_parser_does_not_surface_reasoning_content() -> None:
    payload = {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": "",
                    "reasoning_content": "hidden analysis draft",
                }
            }
        ]
    }
    assert adapter.output_text_from_openai_chat(payload) == ""


def main() -> None:
    tests = [
        test_mimo_context_budget,
        test_mimo_timeout_visible_message,
        test_mimo_cooldown_visible_message,
        test_gemini_tpm_429_is_short_wait_not_daily,
        test_gemini_daily_429_is_visible_daily_quota,
        test_text_tool_markup_parsing,
        test_visible_models_are_direct_identity_aliases,
        test_deepseek_visible_models_are_direct_identity_aliases,
        test_openai_chat_parser_does_not_surface_reasoning_content,
    ]
    for test in tests:
        test()
    print(f"ok - {len(tests)} adapter boundary checks passed")


if __name__ == "__main__":
    main()
