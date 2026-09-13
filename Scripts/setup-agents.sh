#!/usr/bin/env bash
#
# Build the virtual environment the pane agent runs in.
#
# `AgentProcess` looks for `agents/.venv/bin/python3` and falls back to a bare
# `python3`, which has no SDK — so without this script every pane opens on
# `agent exited (code 1)`. Run it once after a clone, and again when
# `agents/pyproject.toml` changes.
#
# 3.13 is preferred over 3.14 deliberately. `claude-agent-sdk` requires >= 3.10
# and its wheel is tagged `py3-none`, so 3.14 is nominally fine — but its
# dependencies (`mcp`, `anyio`) are the kind of thing that has no wheel for a
# just-released Python, and that failure arrives at the worst moment. Override
# with PROSE_PYTHON if you want a particular interpreter.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$ROOT/agents/.venv"

PY="${PROSE_PYTHON:-}"
if [ -z "$PY" ]; then
    PY="$(command -v python3.13 || command -v python3)"
fi

echo "building $VENV with $PY ($("$PY" --version))"
rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -e "$ROOT/agents"

# The whole acceptance test for this script: the SDK imports, and says which
# version it is. Anything short of this and the agent cannot start.
"$VENV/bin/python" - <<'PROBE'
import claude_agent_sdk as sdk
print("claude-agent-sdk", getattr(sdk, "__version__", "(no __version__)"))
PROBE
