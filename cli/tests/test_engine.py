"""Tests for Engine.oneshot() and supporting functions."""

import json
import os
import sys
import subprocess
from unittest.mock import patch, MagicMock, call

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from hivemoot_agent.engine import Engine, _extract_response, _load_file_secrets
from hivemoot_agent.plugins import registry
from hivemoot_agent.plugins.interfaces import PluginConfig


# ── _extract_response tests ───────────────────────────────────────


def test_extract_claude_result():
    output = '{"type":"system","subtype":"init","session_id":"abc"}\n'
    output += '{"type":"result","result":"Hello from Claude"}\n'
    assert _extract_response(output) == "Hello from Claude"


def test_extract_codex_result():
    output = '{"type":"item.completed","item":{"type":"agent_message","text":"Hello from Codex"}}\n'
    assert _extract_response(output) == "Hello from Codex"


def test_extract_fallback():
    output = '{"type":"system"}\nHello plain text\n'
    assert _extract_response(output) == "Hello plain text"


def test_extract_empty():
    assert _extract_response("") == ""


def test_extract_last_result_wins():
    output = '{"type":"result","result":"first"}\n'
    output += '{"type":"result","result":"second"}\n'
    assert _extract_response(output) == "second"


# ── _load_file_secrets tests ──────────────────────────────────────


def test_load_file_secret(tmp_path):
    secret_file = tmp_path / "token"
    secret_file.write_text("my-secret-token\n")

    env = {"TELEGRAM_BOT_TOKEN_FILE": str(secret_file)}
    with patch.dict(os.environ, env, clear=True):
        _load_file_secrets()
        assert os.environ.get("TELEGRAM_BOT_TOKEN") == "my-secret-token"

    # Cleanup.
    os.environ.pop("TELEGRAM_BOT_TOKEN", None)
    os.environ.pop("TELEGRAM_BOT_TOKEN_FILE", None)


def test_load_file_secret_missing_file():
    env = {"OPENAI_API_KEY_FILE": "/nonexistent/path"}
    with patch.dict(os.environ, env, clear=True):
        try:
            _load_file_secrets()
            assert False, "Should have raised SystemExit"
        except SystemExit as e:
            assert e.code == 1


def test_load_file_secret_conflict():
    env = {
        "OPENAI_API_KEY": "inline",
        "OPENAI_API_KEY_FILE": "/some/path",
    }
    with patch.dict(os.environ, env, clear=True):
        try:
            _load_file_secrets()
            assert False, "Should have raised SystemExit"
        except SystemExit as e:
            assert e.code == 1


# ── Engine.oneshot tests ──────────────────────────────────────────


def test_oneshot_happy_path():
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = '{"type":"result","result":"Agent says hello"}\n'
    mock_result.stderr = ""

    with patch("subprocess.run", return_value=mock_result):
        with patch.dict(os.environ, {"AGENT_PROVIDER": "claude"}, clear=False):
            engine = Engine()
            code = engine.oneshot(prompt="Say hello")
            assert code == 0


def test_oneshot_timeout():
    with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("cmd", 30)):
        with patch.dict(os.environ, {"AGENT_PROVIDER": "claude"}, clear=False):
            engine = Engine()
            code = engine.oneshot(prompt="Slow task")
            assert code == 124


def test_oneshot_failure():
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stdout = ""
    mock_result.stderr = "error"

    with patch("subprocess.run", return_value=mock_result):
        with patch.dict(os.environ, {"AGENT_PROVIDER": "claude"}, clear=False):
            engine = Engine()
            code = engine.oneshot(prompt="Bad task")
            assert code == 1


# ── Plugin lifecycle tests ────────────────────────────────────────


class _SpyPlugin:
    """Plugin that records lifecycle call order."""

    def __init__(self) -> None:
        self.name = "spy"
        self.version = "0.0.1"
        self.description = "lifecycle spy"
        self.calls: list[str] = []

    def validate(self, config: PluginConfig) -> list[str]:
        return []

    def setup(self, config: PluginConfig) -> None:
        self.calls.append("setup")

    def triggers(self) -> list:
        return []

    def system_prompt(self, config: PluginConfig) -> str:
        return "spy prompt"

    def on_job_started(self, job, config: PluginConfig) -> None:
        self.calls.append("on_job_started")

    def on_job_finished(self, job, result, config: PluginConfig) -> None:
        self.calls.append("on_job_finished")


def test_oneshot_calls_on_job_started_before_subprocess():
    """on_job_started() must fire before the subprocess in oneshot mode."""
    spy = _SpyPlugin()
    registry._plugins.clear()
    registry._configs.clear()
    registry.register(spy)

    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = '{"type":"result","result":"done"}\n'
    mock_result.stderr = ""

    subprocess_calls: list[str] = []

    def fake_run(cmd, **kwargs):
        subprocess_calls.append("subprocess.run")
        return mock_result

    env = {"AGENT_PROVIDER": "claude", "AGENT_PLUGINS": "spy"}
    with patch("subprocess.run", side_effect=fake_run):
        with patch.dict(os.environ, env, clear=False):
            engine = Engine()
            code = engine.oneshot(prompt="test")

    assert code == 0
    # setup → on_job_started → subprocess → on_job_finished
    assert spy.calls == ["setup", "on_job_started", "on_job_finished"]
    assert subprocess_calls == ["subprocess.run"]
    # subprocess must have run between on_job_started and on_job_finished
    started_idx = spy.calls.index("on_job_started")
    finished_idx = spy.calls.index("on_job_finished")
    assert started_idx < finished_idx


def test_oneshot_without_plugins_skips_lifecycle_hooks():
    """Without AGENT_PLUGINS, lifecycle hooks must not fire."""
    spy = _SpyPlugin()
    registry._plugins.clear()
    registry._configs.clear()
    registry.register(spy)

    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = ""
    mock_result.stderr = ""

    env = {"AGENT_PROVIDER": "claude"}
    # Remove AGENT_PLUGINS so plugins are not loaded.
    filtered = {k: v for k, v in os.environ.items() if k != "AGENT_PLUGINS"}
    filtered.update(env)

    with patch("subprocess.run", return_value=mock_result):
        with patch.dict(os.environ, filtered, clear=True):
            engine = Engine()
            code = engine.oneshot(prompt="test")

    assert code == 0
    # No plugin lifecycle calls when AGENT_PLUGINS is unset.
    assert spy.calls == []


if __name__ == "__main__":
    import inspect
    import tempfile

    passed = 0
    failed = 0
    for name, func in sorted(inspect.getmembers(sys.modules[__name__], inspect.isfunction)):
        if not name.startswith("test_"):
            continue
        try:
            # Provide tmp_path for tests that need it.
            params = inspect.signature(func).parameters
            if "tmp_path" in params:
                with tempfile.TemporaryDirectory() as td:
                    from pathlib import Path
                    func(Path(td))
            else:
                func()
            print(f"  \u2713 {name}")
            passed += 1
        except Exception as e:
            print(f"  \u2717 {name}: {e}")
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
