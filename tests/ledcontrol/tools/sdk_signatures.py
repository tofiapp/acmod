"""Builds tests/ledcontrol/sdk_signatures.txt: every CSP API name LedControl uses, with the line that defines it in
the CSP Lua SDK (https://github.com/ac-custom-shaders-patch/acc-lua-sdk). test_api_names.lua then fails when the app
uses a name that is not in this file, so a new API call needs its definition looked up first.

    python3 -I tests/ledcontrol/tools/sdk_signatures.py /path/to/acc-lua-sdk [/path/to/official/code ...]

The public SDK repository holds the Lua side only: functions bound from C++ (most of ui.*, ac.getSim, ac.getCarID,
render.on, ...) are generated into extension/internal/lua-sdk of a CSP install and are not in it. For those the file
records where official CSP code (app-csp-defaults, acc-lua-internal, acc-lua-examples) calls them, as evidence of the
name and the argument shape. "NOT FOUND" = neither: the app must probe it under pcall.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
APP = ROOT / "apps" / "lua" / "LedControl"
OUT = ROOT / "tests" / "ledcontrol" / "sdk_signatures.txt"


def strip(src):
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    src = re.sub(r"--[^\n]*", "", src)
    return re.sub(r"'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\"", "''", src)


def used_names():
    names = set()
    methods = set()
    for p in sorted(APP.rglob("*.lua")):
        code = strip(p.read_text(encoding="utf-8"))
        for m in re.finditer(r"(?<![\w.:])(ac|ui|render|io|os)\.([A-Za-z_]\w*)(?:\.([A-Za-z_]\w*))?", code):
            names.add(m.group(1) + "." + m.group(2) + ("." + m.group(3) if m.group(3) and m.group(2)[0].isupper() else ""))
        for m in re.finditer(r":([A-Za-z_]\w*)\(", code):
            methods.add(m.group(1))
        # a method called under pcall: pcall(obj.method, obj, ...)
        for m in re.finditer(r"pcall\(\s*([\w\[\].]+)\.([A-Za-z_]\w*)\s*,\s*([\w\[\].]+)\s*[,)]", code):
            if m.group(1) == m.group(3):
                methods.add(m.group(2))
    return sorted(names), sorted(methods)


def app_defined_methods():
    out = set()
    for p in APP.rglob("*.lua"):
        for m in re.finditer(r"function [\w.]+:(\w+)\(", p.read_text(encoding="utf-8")):
            out.add(m.group(1))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sdk = pathlib.Path(sys.argv[1])
    official = [pathlib.Path(a) for a in sys.argv[2:]]
    rev = subprocess.run(["git", "-C", str(sdk), "log", "-1", "--format=%h %cd"], capture_output=True, text=True).stdout.strip()
    files = [p for p in sdk.rglob("*.lua") if p.is_file()]
    texts = {p: p.read_text(encoding="utf-8", errors="replace").split("\n") for p in files}
    app_methods = app_defined_methods()
    otexts = {}
    for d in official:
        for p in d.rglob("*.lua"):
            if not p.is_file():
                continue
            otexts[p] = p.read_text(encoding="utf-8", errors="replace").split("\n")
    names, methods = used_names()
    lines = [f"# CSP API names used by LedControl, looked up in acc-lua-sdk {rev}", "# name | SDK file:line | definition"]

    def find(patterns):
        for p, rows in texts.items():
            for i, row in enumerate(rows):
                for pat in patterns:
                    if re.search(pat, row):
                        return f"{p.relative_to(sdk).as_posix()}:{i + 1} | {row.strip()[:150]}"
        return None

    def used_in_official(pat):
        for p, rows in otexts.items():
            for i, row in enumerate(rows):
                if re.search(pat, row) and not row.strip().startswith("--"):
                    root = next(d for d in official if d in p.parents)
                    return f"official {root.name}/{p.relative_to(root).as_posix()}:{i + 1} | {row.strip()[:150]}"
        return None

    for n in names:
        base, _, last = n.rpartition(".")
        hit = find([r"^\s*function\s+" + re.escape(n) + r"\s*\(", r"^\s*" + re.escape(n) + r"\s*=",
                    r"^\s*" + re.escape(base) + r"\." + re.escape(last) + r"\s*=",
                    r"^\s*---@field\s+" + re.escape(last) + r"\b"])
        if not hit and base.count(".") == 1 and last[0].isupper():   # enum value: '  OpaqueForced = 4, -- ...'
            hit = find([r"^\s*" + re.escape(last) + r"\s*=\s*[-\d]"])
        if not hit and n.startswith(("io.", "os.")) and last in ("open", "popen", "time", "clock", "date", "getenv"):
            hit = "Lua standard library | " + n
        if not hit:
            hit = used_in_official(r"(?<![\w.])" + re.escape(n) + r"\b")
        lines.append(f"{n} | {hit or 'NOT FOUND'}")
    for m in methods:
        if m in app_methods:
            continue
        hit = find([r"^\s*function\s+[\w.]+[:.]" + re.escape(m) + r"\s*\(", r"^\s*" + re.escape(m) + r"\s*=\s*function\s*\("])
        if not hit:
            hit = used_in_official(r":" + re.escape(m) + r"\(")
        lines.append(f":{m} | {hit or 'NOT FOUND (a Lua string / table method or an app object)'}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUT} ({len(names)} names, {len(methods)} methods)")


if __name__ == "__main__":
    main()
