#!/usr/bin/env python3
"""Check that every t("...") key in the sources exists in Localizable.strings.

Usage: check-l10n.py <sources-dir> <strings-file>
Interpolations in code (\\(expr)) match any %-specifier in the key.
Exits 1 and lists the keys that do not match.
"""
import re
import sys
from pathlib import Path

CALL_RE = re.compile(r'\bt\("((?:[^"\\]|\\.)*)"\)')
INTERP_RE = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
SPEC_RE = re.compile(r"%(?:@|lld|d|\d+\$@)")


def normalize(text: str) -> str:
    text = INTERP_RE.sub(" ", text)
    text = SPEC_RE.sub(" ", text)
    return text.replace('\\"', '"')


def main() -> None:
    sources, strings_file = Path(sys.argv[1]), Path(sys.argv[2])
    known = set()
    for line in strings_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^"((?:[^"\\]|\\.)*)" = ', line)
        if match:
            known.add(normalize(match.group(1)))

    missing = []
    for swift in sources.rglob("*.swift"):
        for match in CALL_RE.finditer(swift.read_text(encoding="utf-8")):
            key = normalize(match.group(1))
            if key not in known:
                missing.append(f"{swift.name}: {match.group(1)}")

    if missing:
        print("Keys not found in", strings_file)
        print("\n".join(sorted(set(missing))))
        sys.exit(1)
    print("All t() keys are present in", strings_file)


if __name__ == "__main__":
    main()
