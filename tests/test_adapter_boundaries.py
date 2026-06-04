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
        if key.startswith("ZHUDA_") or key.startswith("GEMINI_") or key.startswith("MIMO_") or key.startswith("XIAOMI_MIMO_"):
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


def main() -> None:
    tests = [
        test_mimo_context_budget,
        test_mimo_timeout_visible_message,
        test_mimo_cooldown_visible_message,
        test_text_tool_markup_parsing,
    ]
    for test in tests:
        test()
    print(f"ok - {len(tests)} adapter boundary checks passed")


if __name__ == "__main__":
    main()
