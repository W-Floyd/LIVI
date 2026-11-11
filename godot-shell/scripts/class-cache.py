#!/usr/bin/env python3
"""Godot's global class registry (.godot/global_script_class_cache.cfg) for a project, from the
`class_name` and `extends` lines of its scripts: what an editor import writes, without running
one (the unit's headless import crashes).

    scripts/class-cache.py project/ > out.cfg
"""
import os
import re
import sys

root = sys.argv[1]
rows = []
for d, _, files in os.walk(root):
    if "/.godot" in d or d.endswith(".godot"):
        continue
    for f in sorted(files):
        if not f.endswith(".gd"):
            continue
        p = os.path.join(d, f)
        name = base = None
        tool = abstract = False
        for line in open(p, encoding="utf-8"):
            s = line.strip()
            tool = tool or s == "@tool"
            abstract = abstract or s.startswith("@abstract")
            m = re.match(r"class_name\s+(\w+)", s)
            if m:
                name = m.group(1)
            m = re.match(r"extends\s+(\w+)", s)
            if m:
                base = m.group(1)
            if name and base:
                break
        if name:
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            rows.append((name, base or "RefCounted", rel, tool, abstract))

rows.sort()
out = []
for name, base, rel, tool, abstract in rows:
    out.append(
        '{\n"base": &"%s",\n"class": &"%s",\n"icon": "",\n"is_abstract": %s,\n"is_tool": %s,\n'
        '"language": &"GDScript",\n"path": "res://%s"\n}'
        % (base, name, str(abstract).lower(), str(tool).lower(), rel)
    )
print("list=[" + ", ".join(out) + "]")
