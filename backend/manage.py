#!/usr/bin/env python3
"""Django manage — must run under the Nix-provided interpreter only."""
import os
import sys
from pathlib import Path


def _require_nix_python() -> None:
    exe = Path(sys.executable).resolve()
    if not str(exe).startswith("/nix/store/"):
        raise SystemExit(
            "Refusing to run with a non-Nix Python interpreter:\n"
            f"  {exe}\n\n"
            "Use the Nix environment instead:\n"
            "  ./run.sh\n"
            "  # or: nix develop devops && neo4j-movies-web\n"
        )
    expected = os.environ.get("NEO4J_MOVIES_PYTHON")
    if not expected:
        return
    expected_path = Path(expected).resolve()
    # `python` from python3.withPackages is a wrapper that execs python3.13.
    same_env = exe.parent == expected_path.parent and exe.name.startswith("python")
    if exe != expected_path and not same_env:
        raise SystemExit(
            "Python interpreter does not match NEO4J_MOVIES_PYTHON from the Nix shell:\n"
            f"  running: {exe}\n"
            f"  expected: {expected_path}\n"
        )


def main() -> None:
    _require_nix_python()
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "movies_web.settings")
    os.environ.setdefault("PYTHONNOUSERSITE", "1")
    from django.core.management import execute_from_command_line

    execute_from_command_line(sys.argv)


if __name__ == "__main__":
    main()
