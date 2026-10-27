#!/usr/bin/env python3
"""Checks that every user-facing Chinese string literal in Sources/ has an English translation.

Interpolations like \\(count) are matched against any printf specifier (%@, %lld, %1$@ …), so the
check doesn't need to know their types. Exits 1 if translations are missing.
"""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CJK = re.compile(r"[一-鿿]")
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f)")
HOLE = "\x00"


def literals(src: str):
    """Yields Swift string literals with interpolations replaced by HOLE.

    Skips // comments and Text(verbatim:) literals, which are deliberately not localized."""
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            i = src.find("\n", i)
            if i < 0:
                return
        elif src[i] == '"':
            verbatim = src[max(0, i - 16):i].rstrip().endswith("verbatim:")
            text, i = read_string(src, i + 1)
            if not verbatim:
                yield text
        else:
            i += 1


def read_string(src: str, i: int):
    out = []
    while i < len(src):
        c = src[i]
        if c == "\\" and src[i + 1] == "(":
            i = skip_interpolation(src, i + 2)
            out.append(HOLE)
        elif c == "\\":
            out.append(src[i:i + 2])
            i += 2
        elif c == '"':
            return "".join(out), i + 1
        else:
            out.append(c)
            i += 1
    return "".join(out), i


def skip_interpolation(src: str, i: int):
    depth = 1
    while depth:
        c = src[i]
        if c == '"':
            _, i = read_string(src, i + 1)
            continue
        depth += {"(": 1, ")": -1}.get(c, 0)
        i += 1
    return i


def normalize_key(key: str) -> str:
    return SPEC.sub(HOLE, key)


def main() -> int:
    en = ROOT / "Resources/en.lproj"
    keys = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', (en / "Localizable.strings").read_text(), re.M))
    keys |= set(plistlib.loads((en / "Localizable.stringsdict").read_bytes()).keys())
    known = {normalize_key(k) for k in keys}

    used, missing = set(), []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        if "selftest" in path.parts[-2]:
            continue
        for text in literals(path.read_text()):
            if CJK.search(text):
                used.add(text)
                if text not in known:
                    missing.append(f"{path.relative_to(ROOT)}: {text.replace(HOLE, '\\(…)')}")

    unused = sorted(k for k in keys if normalize_key(k) not in used)
    for m in missing:
        print(f"✗ missing English: {m}")
    for k in unused:
        print(f"! unused key: {k}")
    print(f"i18n: {len(used)} strings, {len(missing)} missing, {len(unused)} unused")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
