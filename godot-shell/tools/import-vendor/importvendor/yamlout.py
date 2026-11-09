"""A small YAML writer: block maps and lists, flow style for short scalar-only ones.

The standard library has no YAML, and the shell's loader (serde_yaml) reads anything valid.
"""
import json
import re

_PLAIN = re.compile(r"^[A-Za-z_][A-Za-z0-9_./-]*$")
_RESERVED = {"true", "false", "yes", "no", "on", "off", "null", "y", "n", "~"}


def scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(round(v, 3)) if v != int(v) else str(int(v)) if abs(v) < 1e15 else repr(v)
    s = str(v)
    if _PLAIN.match(s) and s.lower() not in _RESERVED:
        return s
    return json.dumps(s, ensure_ascii=False)


def _key(k):
    return scalar(str(k))


def _flowable(v):
    if isinstance(v, dict):
        return all(not isinstance(x, (dict, list)) for x in v.values())
    if isinstance(v, list):
        return all(not isinstance(x, (dict, list)) for x in v)
    return True


def _flow(v):
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{_key(k)}: {scalar(x)}" for k, x in v.items()) + " }" if v else "{}"
    if isinstance(v, list):
        return "[" + ", ".join(scalar(x) for x in v) + "]"
    return scalar(v)


def dump(data, width=100):
    lines = []

    def emit(v, indent):
        pad = "  " * indent
        if isinstance(v, dict):
            for k, x in v.items():
                head = f"{pad}{_key(k)}:"
                if isinstance(x, (dict, list)) and x and not (_flowable(x) and len(head + _flow(x)) < width):
                    lines.append(head)
                    emit(x, indent + 1)
                else:
                    lines.append(f"{head} {_flow(x)}")
        elif isinstance(v, list):
            for x in v:
                if isinstance(x, dict) and x and not (_flowable(x) and len(pad + _flow(x)) < width):
                    sub = []
                    lines_before = len(lines)
                    emit(x, indent + 1)
                    sub = lines[lines_before:]
                    del lines[lines_before:]
                    first = sub[0].lstrip()
                    lines.append(f"{pad}- {first}")
                    lines.extend(sub[1:])
                elif isinstance(x, list) and x and not _flowable(x):
                    lines.append(f"{pad}-")
                    emit(x, indent + 1)
                else:
                    lines.append(f"{pad}- {_flow(x)}")
        else:
            lines.append(pad + scalar(v))

    emit(data, 0)
    return "\n".join(lines) + "\n"


def write(path, data, header=None):
    with open(path, "w", encoding="utf-8") as f:
        if header:
            for line in header.strip().splitlines():
                f.write(f"# {line}\n" if line else "#\n")
        f.write(dump(data))
