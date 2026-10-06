"""Verify the pinned native tool selection before starting the unchanged gateway."""
import contextlib
import json
import os
import sys


def verify():
    # Adapter fixes cwd to its verified sourcePath, with isolated environment.
    package_root = os.path.dirname(os.path.realpath(__file__))
    # The sibling platform/ package is plugin data, not Python's stdlib platform.
    sys.path[:] = [os.getcwd(), *(path for path in sys.path if os.path.realpath(path) != package_root)]
    with contextlib.redirect_stdout(sys.stderr):
        from hermes_cli.plugins import discover_plugins
        from toolsets import resolve_toolset, validate_toolset
        discover_plugins()
        requested = os.environ.get("HERMES_TUI_TOOLSETS", "").split(",")
        supported = {"file", "terminal", "delegation", "memory", "web", "browser", "yorozu_platform", "yorozu_empty", "yorozu_memory"}
        if not requested or any(name not in supported or not validate_toolset(name) for name in requested):
            raise RuntimeError("Unverified scoped native toolset; refusing fallback.")
        if resolve_toolset("yorozu_empty"):
            raise RuntimeError("Chat-only native toolset is not empty.")
        if "yorozu_platform" in requested and set(resolve_toolset("yorozu_platform")) != {"send_agent_message", "read_agent_messages"}:
            raise RuntimeError("Platform messaging registration is unavailable.")
        if "yorozu_memory" in requested:
            if "memory" in requested or set(resolve_toolset("yorozu_memory")) != {"worker_memory"}:
                raise RuntimeError("Uniform memory selection is unavailable or has dual sources.")
        from model_tools import get_tool_definitions
        # The profile is already an isolated host resource. Native memory and
        # delegation settings are owned by Hermes, not Yorozu feature flags.
        from tui_gateway.server import _load_enabled_toolsets
        selected = _load_enabled_toolsets("yorozu")
        if selected is None or set(selected) != set(requested):
            raise RuntimeError("Gateway widened the scoped tool selection.")
        definitions = get_tool_definitions(selected, quiet_mode=True, skip_tool_search_assembly=True)
        names = {entry["function"]["name"] for entry in definitions}
        expected = {name for toolset in requested for name in resolve_toolset(toolset)}
        if not names.issubset(expected):
            raise RuntimeError("Native model catalog exceeds agent tool scope.")
        if "yorozu_memory" in requested and "worker_memory" not in names:
            raise RuntimeError("Uniform memory is not exposed.")
        if "yorozu_memory" not in requested and "worker_memory" in names:
            raise RuntimeError("Uniform memory was exposed without authorization.")
        if "yorozu_platform" in requested and not {"send_agent_message", "read_agent_messages"}.issubset(names):
            raise RuntimeError("Scoped platform messaging is not exposed.")
    return {"toolsets": selected, "tools": sorted(names)}


if __name__ == "__main__":
    verified = verify()
    if sys.argv[1:] == ["--verify"]:
        print(json.dumps(verified))
    elif sys.argv[1:]:
        raise RuntimeError("Unsupported bootstrap arguments.")
    else:
        from tui_gateway.entry import main
        main()
