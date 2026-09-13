"""The client for an agent running in a prose pane.

    from prose_agent import run
    from claude_agent_sdk import ClaudeAgentOptions

    run(ClaudeAgentOptions(system_prompt="You supervise subagents in prose."))

Those three lines connect to `PROSE_SOCKET`, say hello, install the Band A
harness on the SDK's stream, register Band B as an in-process MCP server, and
pump prose's notifications into the agent loop. See
`reference/agent-guide.md` §12.

**The layering is load-bearing.** `wire`, `events`, `tools`, `harness`,
`asking`, `permissions`, `credentials`, `prompt` and `skills` import nothing
but the standard library, so the whole of the mapping and the decision tables
can be tested with no SDK installed — which is what `agents/tests` does. The
three SDK imports that exist are function-local, in `loop.serve`,
`tools.mcp_server` and `permissions.__call__`, and `test_import.py` is what
keeps them there.
"""

from .asking import Asker
from .events import Events
from .harness import Harness
from .loop import run, serve
from .permissions import Permissions
from .tools import definitions, mcp_server, tool_names
from .wire import ProseError, Wire

__all__ = [
    "Asker", "Events", "Harness", "Permissions", "ProseError", "Wire",
    "definitions", "mcp_server", "run", "serve", "tool_names",
]
