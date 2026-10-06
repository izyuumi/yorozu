"""Native messaging tools. Yorozu transports; Hermes decides what to read/share."""
from __future__ import annotations

import json
import uuid
from typing import Literal, Annotated, Union

from pydantic import Field, ConfigDict, TypeAdapter, model_validator, model_serializer
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
    acknowledgeMessageIds: list[str] | None = Field(default=None, min_length=1, max_length=64)
    afterMessageId: str | None = Field(default=None, min_length=1, max_length=512)
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
    acknowledgedMessageIds: list[str] | None = None
    unavailable: bool | None = None
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


class MemoryBase(Params):
    model_config = ConfigDict(extra="forbid", strict=True)


class MemoryRead(MemoryBase):
    action: Literal["read"]
    ownerId: str = Field(min_length=1, max_length=128)
    key: str = Field(min_length=1, max_length=128)


class MemorySearch(MemoryBase):
    action: Literal["search"]
    ownerId: str = Field(min_length=1, max_length=128)
    query: str = Field(min_length=1, max_length=4096)


class MemoryWrite(MemoryBase):
    action: Literal["write"]
    key: str = Field(min_length=1, max_length=128)
    body: str = Field(min_length=1, max_length=32768)
    operationId: str = Field(min_length=1, max_length=128)


class MemoryGrant(MemoryBase):
    action: Literal["grant", "revoke"]
    toAgentId: str = Field(min_length=1, max_length=128)
    key: str = Field(min_length=1, max_length=128)
    operationId: str = Field(min_length=1, max_length=128)


MemoryArguments = TypeAdapter(Annotated[Union[MemoryRead, MemorySearch, MemoryWrite, MemoryGrant], Field(discriminator="action")])


class MemoryRequest(MemoryBase):
    # Transport contract carries native context plus the validated discriminated
    # args. The before validator enforces the exact action shape, not optional
    # fields that could accidentally widen write/share authority.
    session_id: str
    agent_session_id: str
    tool_call_id: str
    action: Literal["read", "search", "write", "grant", "revoke"]
    ownerId: str | None = None
    key: str | None = None
    query: str | None = None
    body: str | None = None
    operationId: str | None = None
    toAgentId: str | None = None

    @model_validator(mode="before")
    @classmethod
    def validate_action(cls, value):
        if not isinstance(value, dict):
            raise ValueError("Invalid memory request")
        MemoryArguments.validate_python({k: v for k, v in value.items()
            if k not in {"session_id", "agent_session_id", "tool_call_id"}})
        return value

    @model_serializer(mode="plain")
    def exact_arguments(self):
        # Native serializers must not reintroduce other actions' optional fields.
        return {key: getattr(self, key) for key in self.model_fields_set}


class MemoryResult(Result):
    value: str | None = None
    entries: list[dict[str, str]] | None = None
    ok: Literal[True] | None = None

    @model_serializer(mode="plain")
    def exact_result(self):
        return {key: getattr(self, key) for key in self.model_fields_set}


def worker_memory(args, *, session_id=""):
    try:
        arguments = MemoryArguments.validate_python(args).model_dump()
    except Exception:
        return json.dumps({"error": "Invalid memory arguments; not submitted."})
    try:
        result = _owned_request("yorozu.worker_memory", arguments, session_id)
        if result is not None:
            # Adapter validates exact action-specific replies before this point.
            return json.dumps(result)
    except Exception:
        pass
    return json.dumps({"error": "Memory outcome unknown. Do not automatically retry."})


def register(ctx):
    from toolsets import create_custom_toolset
    # Prevent the native empty-selection => ALL fallback for a chat-only agent.
    create_custom_toolset("yorozu_empty", "No model tools", tools=[])
    if ctx.get_config("workerMemory", False):
        if "yorozu.worker_memory" not in SERVER_REQUESTS:
            server_request("yorozu.worker_memory", params=MemoryRequest, result=MemoryResult,
                doc="Owned uniform memory transport only.")
        ctx.register_tool("worker_memory", "yorozu_memory", {
            "name": "worker_memory",
            "description": "Read/search owned or explicitly shared host memory, write your memory, or explicitly grant/revoke a peer's access. Never retry uncertain mutations. Identity comes from the native runtime, not tool arguments.",
            "parameters": MemoryArguments.json_schema(),
        }, worker_memory)
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
        "description": "Read the separate agent-message inbox when you choose. Entries retain stable messageId, verified sender and exchangeId. Follow nextAfterMessageId with afterMessageId to read the next bounded page. Repeated reads may contain the same entries; decide whether and when to reply. To explicitly retire messages you have taken responsibility for, supply acknowledgeMessageIds without a cursor. This returns an acknowledgement, not a page. Unacknowledged messages never expire. Retirement receipt capacity is bounded; unavailable is not an acknowledgement.",
        "parameters": ReadArguments.model_json_schema(),
    }, read_agent_messages)
