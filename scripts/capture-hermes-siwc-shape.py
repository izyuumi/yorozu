"""Capture pinned public Hermes + SDK request shapes with inert synthetic data only.

Launch with env -i and HOME/HERMES_HOME/CODEX_HOME inside a fresh owned scratch root.
No AIAgent, gateway, login, provider probe, loop, socket or credential store is used.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--scratch", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
source, scratch, output = args.source.resolve(), args.scratch.resolve(), args.output.resolve()
assert output.is_relative_to(scratch)
for key in ("HOME", "HERMES_HOME", "CODEX_HOME"):
    assert Path(os.environ[key]).resolve().is_relative_to(scratch), key
assert not any(key in os.environ for key in ("OPENAI_API_KEY", "OPENAI_BASE_URL", "HERMES_CODEX_BASE_URL", "CHATGPT_ACCESS_TOKEN"))
sys.dont_write_bytecode = True
sys.path.insert(0, str(source))
read_roots = (source, scratch, Path(sys.prefix).resolve(), Path(sys.base_prefix).resolve())
for name in ("purelib", "platlib"):
    import sysconfig
    read_roots += (Path(sysconfig.get_path(name)).resolve(),)

def audit(event, values):
    if event.startswith("socket.") or event in ("subprocess.Popen", "os.system"):
        raise RuntimeError("Capture forbids process or network activity")
    if event == "open" and isinstance(values[0], (str, bytes, os.PathLike)):
        path = Path(os.fsdecode(values[0])).resolve()
        if path.name in (".env", "auth.json", "credentials.json", "token.json"):
            raise RuntimeError("Capture forbids credential files")
        if not any(path.is_relative_to(root) for root in read_roots):
            raise RuntimeError("Capture attempted a read outside public code/dependencies/owned scratch")
        flags = values[2] if len(values) > 2 else 0
        if isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND) and not path.is_relative_to(scratch):
            raise RuntimeError("Capture forbids writes outside owned scratch")

sys.addaudithook(audit)

source_hashes = {
    "agent/transports/codex.py": "02b5cb1ba5603bb86fee315947a364f17678333e8f24b57bf4876aa1adcc292b",
    "agent/codex_responses_adapter.py": "8923e37047274207d8867f5ae92ad308ebaa5ee27f55fb2df5139a2ad8f3115a",
    "run_agent.py": "244da863d3c21591a3b5326dc14c2962d4e31131dda52df628502cd9fcbfea33",
    "tui_gateway/server.py": "164ad8a1b43671c2a47829502f9a40f4355fc8060f2f6c2506b8aec44f1c0a51",
    "agent/chat_completion_helpers.py": "5231a0e674806db6ad7be60e2d40a19a4157f7d2baa238aaa9af66f61e0eea4c",
}
for path, expected in source_hashes.items():
    assert hashlib.sha256((source / path).read_bytes()).hexdigest() == expected, path

# Verify the exact supported gateway call/default from source without importing the gateway.
gateway = ast.parse((source / "tui_gateway/server.py").read_text())
make_agent = next(node for node in gateway.body if isinstance(node, ast.FunctionDef) and node.name == "_make_agent")
agent_call = next(node for node in ast.walk(make_agent) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "AIAgent")
assert "max_tokens" not in {item.arg for item in agent_call.keywords}
constructor = ast.parse((source / "run_agent.py").read_text())
agent_class = next(node for node in constructor.body if isinstance(node, ast.ClassDef) and node.name == "AIAgent")
init = next(node for node in agent_class.body if isinstance(node, ast.FunctionDef) and node.name == "__init__")
defaults = dict(zip([argument.arg for argument in init.args.args][-len(init.args.defaults):], init.args.defaults))
assert isinstance(defaults["max_tokens"], ast.Constant) and defaults["max_tokens"].value is None
assert isinstance(defaults["request_overrides"], ast.Constant) and defaults["request_overrides"].value is None

from agent.transports.codex import ResponsesApiTransport
import httpx
from openai import OpenAI
from importlib.metadata import version
from types import SimpleNamespace

model = "gpt-6.1-sol"
messages = [
    {"role": "system", "content": "Synthetic Hermes shape capture. Act only on current input."},
    {"role": "user", "content": "Read customer CUST-12345."},
]
tools = [{"type": "function", "function": {"name": "get_customer", "description": "Look up a customer by ID.",
    "parameters": {"type": "object", "properties": {"customer_id": {"type": "string"}}, "required": ["customer_id"], "additionalProperties": False}}}]
transport = ResponsesApiTransport()
base = dict(base_url="http://127.0.0.1:54321/v1", provider="custom:yorozu-local-proof", session_id="synthetic-siwc-shape", max_tokens=None, request_overrides={}, reasoning_config=None)
records = {}

def capture(name, payload_messages, payload_tools=None, **changes):
    kwargs = transport.build_kwargs(model=model, messages=payload_messages, tools=payload_tools, **{**base, **changes})
    kwargs = transport.preflight_kwargs(kwargs, allow_stream=False, is_github_responses=False, sanitize_harmony_tokens=False)
    recorded = []
    def fake_http(request):
        assert request.url == "http://127.0.0.1:54321/v1/responses"
        recorded.append(json.loads(request.content))
        # Synthetic terminal fixture only. MockTransport never creates a socket.
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, content='event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_shape","status":"completed","output":[]}}\n\n')
    with httpx.Client(transport=httpx.MockTransport(fake_http), trust_env=False) as http:
        with OpenAI(api_key="synthetic-local-bearer-not-an-account-token", base_url=base["base_url"], http_client=http, max_retries=0) as client:
            stream = client.responses.create(**kwargs, stream=True)
            stream.close()
    assert len(recorded) == 1
    records[name] = {"kwargs": kwargs, "body": recorded[0]}

capture("normal", messages)
capture("function", messages, tools)
native_call = transport.normalize_response(SimpleNamespace(status="completed", output=[SimpleNamespace(type="function_call", id="fc_abc123", call_id="call_abc123", name="get_customer", namespace="get_customer", arguments='{"customer_id":"CUST-12345"}')]))
assert native_call.finish_reason == "tool_calls" and len(native_call.tool_calls) == 1
call = native_call.tool_calls[0]
assert call.name == "get_customer" and call.provider_data["call_id"] == "call_abc123"
history = messages + [
    {"role": "assistant", "content": None, "tool_calls": [{"id": call.id, "type": "function", "function": {"name": call.name, "arguments": call.arguments}, "provider_data": call.provider_data}]},
    {"role": "tool", "tool_call_id": call.id, "content": '{"name":"Synthetic Customer"}'},
]
capture("functionResult", history, tools)
capture("configuredTokenLimit", messages, max_tokens=2048)
capture("configuredCacheRetention", messages, request_overrides={"prompt_cache_retention": "24h"})
capture("sdkTimeout", messages, timeout=30)
assert "max_output_tokens" not in records["normal"]["body"]
assert "prompt_cache_retention" not in records["normal"]["body"]
assert records["configuredTokenLimit"]["body"]["max_output_tokens"] == 2048
assert records["configuredCacheRetention"]["body"]["prompt_cache_retention"] == "24h"
assert records["sdkTimeout"]["kwargs"]["timeout"] == 30 and "timeout" not in records["sdkTimeout"]["body"]
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({"hermesVersion": "0.21.5", "sourceSha": "f97608f178d1ffeca59860195ab7da295f7c8e5f", "openaiSdkVersion": version("openai"),
    "scope": "public request builder + native synthetic response normalization + mock SDK serialization; no agent/gateway/account/inference", "gatewayMaxTokensDefault": None,
    "sourceHashes": source_hashes, "normalizedCall": {"id": call.id, "name": call.name, "arguments": call.arguments, "providerData": call.provider_data}, "records": records}, indent=2) + "\n")
print(json.dumps({"status": "captured", "records": list(records), "openaiSdkVersion": version("openai"), "network": "forbidden"}))
