#!/usr/bin/env python3
"""Methods a test exercises and nothing ships.

WHY THIS CHECK AND NOT A DEAD-CODE ONE. Three defects reached a green
suite in one session, and none of them was found by the tests that
covered the code they were in. The shape was always the same: a helper
had tests and the SHIPPED path had an inlined copy of it, which had
already drifted. One of them — `migratePane` — had two tests, no
production caller, and its twin at the call site had inverted the very
property those tests pin.

So the question is not "is this dead". Dead code is cheap and a general
detector for it is loud: protocol conformances, SwiftUI hooks and
selector targets all look unreferenced. The question is "does a test
believe this ships". That pair — exercised by a test, called by nothing
— is narrow, and it is exactly the state that lets a suite be green
about code nobody runs.

WHAT IT DOES NOT CLAIM. A finding here is not "delete this". It is
"either wire it or drop it, and say which" — a method kept for a caller
that has not been written is a decision, and this asks for it to be a
recorded one rather than an accident.
"""
import glob
import re
import sys

DECL = re.compile(
    r"\s*(?:@\w+\s+)*"
    r"(?:public |internal |private |fileprivate |static |class |final |nonisolated |override |@discardableResult )*"
    r"func\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]"
)

# A NAME THAT SAYS IT IS A TEST SEAM IS NOT A FINDING. The project builds
# these deliberately — a clock a test can move, a cache it can clear —
# and naming them is how that intent survives review. Reporting them
# would be reporting the convention working.
SEAM = re.compile(r"(ForTesting|ForTest|_test)$")


def calls(name, texts):
    """How many times this name is INVOKED. The declaration matches too,
    which is why one is the floor rather than zero."""
    pattern = re.compile(r"\b" + re.escape(name) + r"\s*\(")
    return sum(len(pattern.findall(t)) for t in texts)


def main():
    sources = sorted(glob.glob("Sources/**/*.swift", recursive=True))
    tests = sorted(glob.glob("Tests/**/*.swift", recursive=True))
    src_text = [open(f, encoding="utf-8").read() for f in sources]
    test_text = [open(f, encoding="utf-8").read() for f in tests]

    declared = {}
    for path in sources:
        for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
            m = DECL.match(line)
            if m:
                declared.setdefault(m.group(1), (path, lineno))

    findings = []
    for name, (path, lineno) in declared.items():
        # A THREE-LETTER NAME IS A COINCIDENCE WAITING TO HAPPEN. `run(`
        # and `map(` appear everywhere and belong to everything.
        if len(name) < 4 or SEAM.search(name):
            continue
        in_tests = calls(name, test_text)
        if in_tests == 0:
            continue
        if calls(name, src_text) > 1:
            continue
        findings.append((f"{path}:{lineno}", name, in_tests))

    for where, name, n in sorted(findings):
        print(f"unshipped  {name}\n           {where}, exercised by {n} test call(s), called by no shipped code")
    print(f"\n{len(findings)} tested and unshipped, over {len(declared)} declared methods")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
