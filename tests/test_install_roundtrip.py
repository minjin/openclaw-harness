"""INSTALL.md must embed every skill file byte-for-byte, so an agent writing them out gets the real code."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build_install  # noqa: E402

doc = open(os.path.join(ROOT, "INSTALL.md"), encoding="utf-8").read()
blocks = dict(re.findall(r"### `([^`]+)`\n\n~~~~~\w+\n(.*?)\n~~~~~\n", doc, re.S))
assert sorted(blocks) == sorted(build_install.FILES), sorted(blocks)
for rel, body in blocks.items():
    src = open(os.path.join(ROOT, rel), encoding="utf-8").read().rstrip("\n")
    assert body == src, "embedded %s differs from source" % rel
print("ok - INSTALL.md embeds %d files verbatim" % len(blocks))
