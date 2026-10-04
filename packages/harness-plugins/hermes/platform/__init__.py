"""First-party native tool bridge. The host owns delegated authority and execution."""
from __future__ import annotations

import json
from typing import Literal

from pydantic import Field
from tui_gateway.contracts.base import Params, Result
from tui_gateway.contracts.registry import SERVER_REQUESTS, server_request


class Directory(Params):
    path: str = Field(min_length=1, max_length=4096)
    access: Literal["read", "write"]


class DelegatedScope(Params):
    allowedTools: list[str] = Field(max_length=8)
    directories: list[Directory] = Field(max_length=64)
    sharedResourceIds: list[str] | None = Field(default=None, max_length=32)


class TeamArguments(Params):
    teammateId: str = Field(min_length=1, max_length=128)
    context: str = Field(min_length=1, max_length=32768)
    expectedResult: str = Field(min_length=1, max_length=8192)
    scope: DelegatedScope


class TeamRequest(TeamArguments):
    session_id: str
    agent_session_id: str
    tool_call_id: str


class TeamResult(Result):
    status: Literal["completed", "failed", "unknown", "rejected"]
    taskId: str | None = Field(default=None, max_length=128)
    text: str | None = Field(default=None, max_length=32768)


def delegate_to_agent(args, *, session_id=""):
    from gateway.session_context import get_session_env
    from tui_gateway import server_requests
    from tools.approval_context import _approval_tool_call_id
    try:
        validated = TeamArguments.model_validate(args).model_dump(exclude_none=True)
    except Exception:
        return json.dumps({"status": "rejected", "text": "Invalid scoped teammate request."})
    live_session_id = get_session_env("HERMES_UI_SESSION_ID")
    tool_call_id = _approval_tool_call_id.get()
    if not live_session_id or not session_id or not tool_call_id:
        return json.dumps({"status": "rejected", "text": "No owned live secretary session."})
    # The adapter verifies the durable caller equals the owning secretary. Native
    # ephemeral children have different durable identities and cannot borrow it.
    try:
        result = server_requests.send("yorozu.team_delegate", live_session_id,
            {**validated, "agent_session_id": session_id, "tool_call_id": tool_call_id}, timeout=120.0)
        if result is not None:
            return json.dumps(TeamResult.model_validate(result).model_dump(exclude_none=True))
    except Exception:
        pass
    return json.dumps({"status": "unknown", "text": "Teammate handoff outcome is uncertain; do not retry automatically."})


def register(ctx):
    # A nonempty explicit selection of this genuinely empty toolset prevents
    # native empty-config => ALL fallback for chat-only agents.
    from toolsets import create_custom_toolset
    create_custom_toolset("yorozu_empty", "No model tools", tools=[])
    if not ctx.get_config("team", False):
        return
    if "yorozu.team_delegate" not in SERVER_REQUESTS:
        server_request("yorozu.team_delegate", params=TeamRequest, result=TeamResult,
            doc="One scoped persistent-agent handoff, owned and settled by Yorozu.")
    schema = TeamArguments.model_json_schema()
    ctx.register_tool("delegate_to_agent", "yorozu_platform", {
        "name": "delegate_to_agent",
        "description": "Ask an authorized teammate for a scoped result. Supply only necessary context. Scope is a proposal; the host narrows authority. The origin owns the final reply. Unknown means no automatic retry.",
        "parameters": schema,
    }, delegate_to_agent)
