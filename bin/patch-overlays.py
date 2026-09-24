#!/usr/bin/env python3
"""Patch cloned Omarchy popups to route touch to the on-screen keyboard."""

from pathlib import Path
import sys


def main(path: Path) -> None:
    source = path.read_text()
    marker = "// Gimbal SP4 touch keyboard focus adapter"
    if marker in source:
        return

    old = "WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive"
    if source.count(old) != 1:
        raise SystemExit(f"Expected one exclusive focus rule in {path}")

    if "import Quickshell.Io" not in source:
        if "import Quickshell\n" not in source:
            raise SystemExit(f"Cannot add Quickshell.Io import to {path}")
        source = source.replace("import Quickshell\n", "import Quickshell\nimport Quickshell.Io\n", 1)

    replacement = """WlrLayershell.keyboardFocus: gimbalSp4Mode.tablet ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    // Gimbal SP4 touch keyboard focus adapter
    FileView {
        id: gimbalSp4Mode
        property bool tablet: false
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/gimbal-sp4-mode"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: tablet = text().trim() === "tablet"
        onLoadFailed: tablet = false
    }"""
    path.write_text(source.replace(old, replacement, 1))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch-overlays.py <cloned-qml-file>")
    main(Path(sys.argv[1]))
