#!/usr/bin/env python3
"""test-hygiene.py — catch tests that silently do not run.

XCTest discovers test methods through the Objective-C runtime, which only sees
methods declared as members of an `XCTestCase` subclass. A `func testX()`
declared *inside another function* is a plain local closure: it compiles, it
reads exactly like a test in review and in a diff, and it is never executed.
Nothing fails, nothing warns — the coverage is simply imaginary.

This is not hypothetical. The audit that added this guard found three such
tests in the suite, one of which had been dead since it was written:

  * PropfindXMLParserTests.testWellFormedNonMultistatusDocumentIsRejected
  * PropfindXMLParserTests.testNegativeContentLengthIsIgnored
  * MediaAliasLedgerTests.testRepeatedActivationDoesNotRepublishUnchangedSnapshot

They all pass once hoisted to real methods, so the bug was purely that they had
been nested by accident — the single most expensive kind of test defect, because
it costs full authoring effort and delivers nothing.

Nested XCTestCase *classes* are fine and deliberately allowed: the runtime does
register them (verified against a real run log), so `final class Inner:
XCTestCase` inside another test case executes normally.

Why Python on the host instead of a Swift test?
  Same reason as tools/arch-guard.py: every unit test runs inside the tvOS
  Simulator sandbox and cannot read the repo's Tests/ tree. A source-level
  invariant has to be enforced from the host.

Usage:
  tools/test-hygiene.py             # check Tests/; exit 1 on any violation
  tools/test-hygiene.py --self-test # run embedded fixtures proving the logic
"""
from __future__ import annotations

import os
import re
import sys

TESTS_DIR = "Tests"

# `func testFoo(` optionally preceded by attributes/modifiers on the same line.
FUNC_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*[(<]")
# Any func declaration, used to track whether we are inside a function body.
ANY_FUNC_RE = re.compile(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*[(<]")
# A type declaration resets "inside a function" — a nested type's methods are
# real members again (e.g. a helper class declared inside a factory function is
# unusual, but its methods are still members of that class).
TYPE_RE = re.compile(r"\b(class|struct|enum|extension|actor|protocol)\s+[A-Za-z_]")


def find_nested_test_funcs(source: str) -> list[tuple[int, str]]:
    """Return (line_number, test_name) for every test func nested in a function.

    Brace-depth scan: we record the depth at which each function body opens, and
    flag a `func testX` whose innermost enclosing scope is a function body rather
    than a type body. String literals and comments are stripped first so braces
    inside them can't skew the depth.
    """
    stripped = _strip_comments_and_strings(source)
    findings: list[tuple[int, str]] = []
    # Stack of scope kinds, one entry per open brace: "func", "type" or "other".
    scopes: list[str] = []
    pending: str | None = None

    for lineno, line in enumerate(stripped.splitlines(), start=1):
        # Classify what this line declares before consuming its braces, so the
        # brace that opens the declaration's body is tagged correctly.
        test_match = FUNC_RE.search(line)
        if test_match and any(s == "func" for s in scopes):
            findings.append((lineno, test_match.group(1)))

        if TYPE_RE.search(line):
            pending = "type"
        elif ANY_FUNC_RE.search(line):
            pending = "func"

        for char in line:
            if char == "{":
                scopes.append(pending or "other")
                pending = None
            elif char == "}":
                if scopes:
                    scopes.pop()
    return findings


def _strip_comments_and_strings(source: str) -> str:
    """Blank out string literals and comments, preserving line structure."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        two = source[i:i + 2]
        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append("".join(c if c == "\n" else " " for c in source[i:end]))
            i = end
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            out.append(" " * (min(j, n - 1) - i + 1))
            i = j + 1
        elif two == "//":
            end = source.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
        elif two == "/*":
            end = source.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in source[i:end]))
            i = end
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def check_tree(root: str) -> list[str]:
    violations: list[str] = []
    for dirpath, _, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8", errors="replace") as handle:
                source = handle.read()
            for lineno, test_name in find_nested_test_funcs(source):
                violations.append(
                    f"{path}:{lineno}: '{test_name}' is declared inside another "
                    f"function, so XCTest never runs it. Hoist it to a method of "
                    f"the XCTestCase."
                )
    return violations


SELF_TEST_CASES = [
    (
        "nested test func is caught",
        """
        final class T: XCTestCase {
            func testOuter() {
                XCTAssertTrue(true)
                func testInner() { XCTAssertTrue(true) }
            }
        }
        """,
        ["testInner"],
    ),
    (
        "normal test methods are clean",
        """
        final class T: XCTestCase {
            func testA() { XCTAssertTrue(true) }
            func testB() throws { XCTAssertTrue(true) }
        }
        """,
        [],
    ),
    (
        "nested XCTestCase class is allowed (the runtime does register it)",
        """
        final class Outer: XCTestCase {
            func testA() {}
            final class Inner: XCTestCase {
                func testB() {}
            }
        }
        """,
        [],
    ),
    (
        "closures and braces in strings do not confuse the scan",
        """
        final class T: XCTestCase {
            func testA() {
                let s = "{ func testFake() {"
                // func testCommented() {
                run { XCTAssertTrue(true) }
            }
        }
        """,
        [],
    ),
    (
        "helper func containing a test-named local is caught too",
        """
        final class T: XCTestCase {
            private func makeThing() {
                func testHidden() {}
            }
        }
        """,
        ["testHidden"],
    ),
]


def self_test() -> bool:
    ok = True
    for name, source, expected in SELF_TEST_CASES:
        found = [test for _, test in find_nested_test_funcs(source)]
        if found != expected:
            ok = False
            print(f"  FAIL: {name}: expected {expected}, got {found}")
        else:
            print(f"  ok: {name}")
    print("test-hygiene --self-test: " + ("OK" if ok else "FAILED"))
    return ok


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--self-test":
        return 0 if self_test() else 1

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", TESTS_DIR)
    root = os.path.normpath(root)
    if not os.path.isdir(root):
        print(f"test-hygiene.py: no {TESTS_DIR}/ directory at {root}")
        return 1

    violations = check_tree(root)
    if violations:
        print("TEST HYGIENE: FAILED — tests that XCTest will never run:")
        for violation in violations:
            print(f"  {violation}")
        return 1

    print("TEST HYGIENE: OK (no unreachable test methods)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
