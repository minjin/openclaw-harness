#!/usr/bin/env python3
"""Generate INSTALL.md (a single self-contained installer) from the template and skill files.

Usage:
  python3 tools/build_install.py            # write INSTALL.md
  python3 tools/build_install.py --check    # fail if INSTALL.md is out of date (CI)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.environ.get("CONDUCTOR_REPO", "minjin/openclaw-harness")
FILES = [
    "SKILL.md",
    "pipelines.json",
    "scripts/conductor.py",
    "templates/AGENTS.md",
    "templates/brain-index.md",
    "templates/lessons.md",
    "references/knowledge-import.md",
]
FENCE = "~~~~~"


def build():
    version = re.search(r'^VERSION = "([^"]+)"', open(os.path.join(ROOT, "scripts/conductor.py")).read(), re.M).group(1)
    parts = []
    for rel in FILES:
        text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
        if FENCE in text:
            raise SystemExit("%s contains %s; pick another fence" % (rel, FENCE))
        lang = {".md": "markdown", ".json": "json", ".py": "python"}[os.path.splitext(rel)[1]]
        parts.append("### `%s`\n\n%s%s\n%s\n%s\n" % (rel, FENCE, lang, text.rstrip("\n"), FENCE))
    tpl = open(os.path.join(ROOT, "tools/INSTALL.template.md"), encoding="utf-8").read()
    return (tpl.replace("{{VERSION}}", version).replace("{{REPO}}", REPO)
            .replace("{{FILES}}", "\n".join(parts)))


def main():
    out = build()
    path = os.path.join(ROOT, "INSTALL.md")
    if "--check" in sys.argv:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != out:
            raise SystemExit("INSTALL.md is out of date: run python3 tools/build_install.py")
        print("INSTALL.md is up to date")
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    print("wrote %s (%d bytes)" % (path, len(out)))


if __name__ == "__main__":
    main()
