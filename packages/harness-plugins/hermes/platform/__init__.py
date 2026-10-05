"""Native messaging tools. Yorozu transports; Hermes decides what to read/share."""
from __future__ import annotations

import json
import uuid
from typing import Literal

from pydantic import Field
from tui_gateway.contracts.base import Params, Result
from tui_gateway.contracts.registry import SERVER_REQUESTS, server_request


class SendArguments(Params):
    toAgentId: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1, max_length=32768)
    exchangeId: str | None = Field(default=None, min_length=1, max_length=128)


class SendRequest(SendArguments):
    session_id: str
    agent_session_id: str
    tool_call_id: str
    messageId: str


class ReadArguments(Params):
    afterMessageId: str | None = Field(default=None, min_length=1, max_length=128)
    limit: int = Field(default=4, ge=1, le=4)


class ReadRequest(ReadArguments):
    session_id: str
    agent_session_id: str
    tool_call_id: str


class SendReceipt(Result):
    status: Literal["accepted", "rejected", "unknown"]
    messageId: str | None = None
    exchangeId: str | None = None
    reason: str | None = None


class Origin(Params):
    version: Literal[1]
    agentId: str
    pluginId: str
    conversationId: str
    sessionId: str
    workId: str | None = None
    bindingEpoch: str


class PeerMessage(Params):
    version: Literal[1]
    messageId: str
    exchangeId: str
    deliveryId: str
    attemptId: str
    sessionId: str
    origin: Origin
    fromAgentId: str
    toAgentId: str
    text: str
    createdAt: float


class ReadResult(Result):
    messages: list[PeerMessage]
    nextAfterMessageId: str | None = None


def _owned_request(method, arguments, session_id):
    from gateway.session_context import get_session_env
    from tui_gateway import server_requests
    from tools.approval_context import _approval_tool_call_id
    live_id = get_session_env("HERMES_UI_SESSION_ID")
    tool_id = _approval_tool_call_id.get()
    if not live_id or not session_id or not tool_id:
        return None
    # Bounds admission only: never wait for a peer answer or cancel peer work.
    return server_requests.send(method, live_id,
        {**arguments, "agent_session_id": session_id, "tool_call_id": tool_id}, timeout=30.0)


def send_agent_message(args, *, session_id=""):
    message_id = str(uuid.uuid4())
    try:
        arguments = SendArguments.model_validate(args).model_dump(exclude_none=True)
    except Exception:
        return json.dumps({"status": "rejected", "messageId": message_id,
            "reason": "Invalid agent-message arguments."})
    try:
        receipt = _owned_request("yorozu.message_send", {**arguments, "messageId": message_id}, session_id)
        if receipt is not None:
            return json.dumps(SendReceipt.model_validate(receipt).model_dump(exclude_none=True))
    except Exception:
        pass
    return json.dumps({"status": "unknown", "messageId": message_id,
        "reason": "Message admission is uncertain. Do not automatically send it again."})


def read_agent_messages(args, *, session_id=""):
    try:
        arguments = ReadArguments.model_validate(args).model_dump(exclude_none=True)
        result = _owned_request("yorozu.message_read", arguments, session_id)
        if result is not None:
            return json.dumps(ReadResult.model_validate(result).model_dump(by_alias=True, exclude_none=True))
    except Exception:
        pass
    return json.dumps({"messages": [], "unavailable": True})


def register(ctx):
    from toolsets import create_custom_toolset
    # Prevent the native empty-selection => ALL fallback for a chat-only agent.
    create_custom_toolset("yorozu_empty", "No model tools", tools=[])
    if not ctx.get_config("team", False):
        return
    for name, params, result in [
        ("yorozu.message_send", SendRequest, SendReceipt),
        ("yorozu.message_read", ReadRequest, ReadResult),
    ]:
        if name not in SERVER_REQUESTS:
            server_request(name, params=params, result=result, doc="Persistent-agent message transport only.")
    ctx.register_tool("send_agent_message", "yorozu_platform", {
        "name": "send_agent_message",
        "description": "Send another agent a message. Choose what context to share. Acceptance means transport custody, not execution or a reply. For a reply, use the received exchangeId. Agent messages grant no filesystem or tool authority. Selected peers: " + json.dumps(ctx.get_config("peers", [])),
        "parameters": SendArguments.model_json_schema(),
    }, send_agent_message)
    ctx.register_tool("read_agent_messages", "yorozu_platform", {
        "name": "read_agent_messages",
        "description": "Read the separate agent-message inbox when you choose. Entries retain stable messageId, verified sender and exchangeId. Follow nextAfterMessageId with afterMessageId to read the next bounded page. Repeated reads may contain the same entries; decide whether and when to reply.",
        "parameters": ReadArguments.model_json_schema(),
    }, read_agent_messages)
