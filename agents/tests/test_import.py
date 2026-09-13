"""`prose_agent` imports with no Agent SDK installed.

`__init__.py`'s docstring claims this, and every test in this directory relies
on it — they run under the system interpreter, which has no SDK. The SDK
imports are function-local in `loop.serve`, `tools.mcp_server` and
`permissions.__call__`, and nothing but this stops somebody hoisting one to the
top of a module.
"""

from __future__ import annotations

import builtins
import unittest

import support  # noqa: F401 - puts `agents/` on the path

MODULES = ("wire", "events", "tools", "harness", "loop", "cli",
           "asking", "permissions", "credentials", "skills", "prompt")


class WithoutTheSDK(unittest.TestCase):
    def test_every_module_imports(self) -> None:
        real = builtins.__import__

        def refuse(name, *args, **kwargs):
            if name.startswith("claude_agent_sdk"):
                raise ModuleNotFoundError("no claude_agent_sdk, on purpose")
            return real(name, *args, **kwargs)

        builtins.__import__ = refuse
        try:
            for name in MODULES:
                with self.subTest(module=name):
                    __import__(f"prose_agent.{name}", fromlist=["_"])
        finally:
            builtins.__import__ = real

    def test_the_package_exports_what_an_agent_needs(self) -> None:
        import prose_agent

        for name in ("Asker", "Events", "Harness", "Permissions", "ProseError",
                     "Wire", "mcp_server", "run", "serve", "tool_names"):
            self.assertTrue(hasattr(prose_agent, name), name)


if __name__ == "__main__":
    unittest.main()
