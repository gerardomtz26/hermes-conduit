#!/usr/bin/env python3
"""Localization catalog coverage: every localizable call site must resolve,
and every required key must carry a REAL zh-Hans translation.

Scans Conduit Swift sources for sites that look up String Catalog keys -

  1. AppLocalization.string("...") / String(localized: "...") - the
     interpolated skeleton must exist in Localizable.xcstrings as a format
     string (either %@ or %lld placeholder forms are accepted).
  2. SwiftUI literal initializers (Text/Button/Label/TextField/SecureField/
     Toggle/NavigationLink/Picker/ProgressView/ContentUnavailableView/
     Section/Menu/GroupBox) - a leading string literal is a
     LocalizedStringKey and is checked the same way.
  3. LocalizedStringKey modifier literals (.alert / .confirmationDialog).

For every required key (static call sites plus the explicit REGRESSION_KEYS
below - dynamic/ternary sites that cannot be extracted statically), the
checker then validates the zh-Hans localization:

  * the key must exist;
  * a zh-Hans localization must be present (a key with en-only content
    fails);
  * every stringUnit leaf - direct or inside plural/device variations -
    must have state == "translated" and a non-empty value;
  * the printf placeholders of each localized value must match the key's
    placeholders (type and count; positional forms compared by index), so a
    translation can never break the runtime format substitution.

Any violation is reported with file:line (call sites) or by key (catalog)
and fails the run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

REQUIRED_LANGUAGE = "zh-Hans"

# SwiftUI initializers whose first argument is a LocalizedStringKey when a
# string literal is passed directly. Variables/interpolations elsewhere are
# not statically checkable and are simply skipped.
SWIFTUI_LOCALIZED_INITIALIZERS = (
    "Text", "Button", "Label", "TextField", "SecureField",
    "Toggle", "NavigationLink", "Picker",
    "ProgressView", "ContentUnavailableView", "Section", "Menu", "GroupBox",
)

# Modifier-style APIs whose first argument is a LocalizedStringKey when a
# string literal is passed directly (there are String overloads too, but a
# raw literal in a String-position branch is exactly the bug class this
# checker exists for, so literal sites are always required to be keys).
SWIFTUI_LOCALIZED_MODIFIERS = ("alert", "confirmationDialog")

# Keys that are intentionally not statically present in the catalog: pure
# variable passthroughs, separators, brand/protocol names, and placeholder
# tokens that must never be translated.
EXEMPT_KEYS = frozenset({
    "%@",            # verbatim variable passthrough
    "%@ %@",         # two-variable passthrough
    "%@/%@",         # numeric done/total counters
    "%@.",           # numbered step prefix ("1.")
    "/", "•",        # separators
    "v%@",           # version prefix ("v1.2.3")
    "×%@",           # multiplier badge
    "A",             # typography size sample glyph
    "Conduit", "GitHub", "Hermes", "HTTP", "HTTPS",  # brand/protocol names
    "https://hermes.example", "https://push.milim.dev",  # literal URLs
    "skill-name",    # example placeholder token
})

# Dynamic sites the extractor cannot see (string literals on ternary
# branches, variable-key lookups such as the config display-label table).
# Each entry must exist in the catalog WITH a valid zh-Hans translation.
# When adding a dynamic localizable site, add its key here.
REGRESSION_KEYS = (
    # Text(ternary) branches in the Connection Setup wizard
    "Enter the local IP address and port Hermes gave you. You don’t need to type http://.",
    "Enter the Tailscale hostname or address Hermes gave you. Tailscale Serve hostnames use HTTPS; leave the port blank unless Hermes supplied one.",
    "Review or edit your current dashboard address, including its port and path.",
    "Paste the full HTTPS dashboard address Hermes supplied, including any port or path.",
    "Checks for HTTPS and certificate problems when connecting to your dashboard.",
    "Checks for Cloudflare Access service-token problems when connecting to your dashboard.",
    # Text(ternary) branches in Login
    "Face ID, with device passcode recovery, is required on launch.",
    "Saved credentials reconnect without a Face ID prompt.",
    # Text(ternary) branches in the sidebar / composer / chat
    "Sessions will appear here once created.",
    "Try a different search.",
    "Projects created in Hermes Desktop will appear here.",
    "Update this Hermes gateway to recover active turns safely.",
    "Diagram",
    "Formula",
    "Code",
    "You",
    "Pin",
    "Unpin",
    "Active",
    "Paused",
    "Hidden",
    "Visible",
    "Edit",
    "Connect",
    "Connecting...",
    "Show %lld more",
    "Apply to %lld",
    "Show all %lld lines",
    "Show %lld more rows (%lld of %lld left)",
    "Add %@",
    "Edit %@",
    "Edit phrase %@",
    "Context usage, %lld percent",
    "Hermes asked %lld questions before it can continue",
    "Confirm %lld selected",
)

CALL_RE = re.compile(
    r"\b(?:String\s*\(\s*localized\s*:|AppLocalization\s*\.\s*string\s*\()")
SWIFTUI_RE = re.compile(
    r"\b(" + "|".join(SWIFTUI_LOCALIZED_INITIALIZERS) + r")\s*\(")
MODIFIER_RE = re.compile(
    r"\.\s*(" + "|".join(SWIFTUI_LOCALIZED_MODIFIERS) + r")\s*\(")

_PLACEHOLDER_RE = re.compile(r"%(?:(\d+)\$)?([@dfIu]|l+l[d|i]|lld|ll|ld|lf|@|d|i|u|f|%)")
# Normalize a printf spec to (position_or_None, type) with %d/%lld/%u/%i
# folded to "int", %f/%lf to "float", %@ to "object".


def placeholder_specs(formatted: str) -> list:
    """Extract (position, type) pairs from a printf-style format string.

    %% escapes are ignored. Positional forms (%1$@) keep their index;
    non-positional forms get None.
    """
    specs = []
    i = 0
    while i < len(formatted):
        if formatted[i] != "%":
            i += 1
            continue
        match = _PLACEHOLDER_RE.match(formatted, i)
        if not match:
            i += 1
            continue
        i = match.end()
        if match.group(0) == "%%":
            continue
        position = int(match.group(1)) if match.group(1) else None
        body = match.group(2)
        if body in ("@",):
            kind = "object"
        elif body in ("f", "lf", "F"):
            kind = "float"
        else:
            kind = "int"
        specs.append((position, kind))
    return specs


def parse_swift_string_literal(source: str, start: int):
    """Parse a Swift string literal starting at source[start] == '"'.

    Returns (skeleton, end_index, has_interpolation) or None when the
    literal is unterminated at EOF. Interpolations \\(...) collapse to a
    single placeholder; nested strings inside them are skipped.
    """
    assert source[start] == '"'
    out = []
    i = start + 1
    while i < len(source):
        ch = source[i]
        if ch == "\\":
            if i + 1 >= len(source):
                return None
            nxt = source[i + 1]
            if nxt == "(":
                # Interpolation: skip to the matching close paren.
                depth = 1
                j = i + 2
                while j < len(source) and depth:
                    if source[j] == '"':
                        parsed = parse_swift_string_literal(source, j)
                        if parsed is None:
                            return None
                        j = parsed[1] - 1
                    elif source[j] == "(":
                        depth += 1
                    elif source[j] == ")":
                        depth -= 1
                    j += 1
                if depth:
                    return None
                out.append("%@")
                i = j
            else:
                escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                           "\\": "\\", '"': '"', "'": "'"}
                out.append(escapes.get(nxt, nxt))
                i += 2
        elif ch == '"':
            return "".join(out), i + 1, "%@" in out
        else:
            out.append(ch)
            i += 1
    return None


def strip_comment_lines(source: str) -> str:
    """Drop full-line // comments so doc diagrams can't look like call sites.

    Only WHOLE-LINE comments are removed - code with trailing comments is
    kept intact, and '//' inside string literals lives on code lines.
    """
    kept = []
    for line in source.split("\n"):
        if line.lstrip().startswith("//"):
            continue
        kept.append(line)
    return "\n".join(kept)


def extract_sites(source: str):
    """Yield (key_skeleton, offset) for every checkable call site."""
    source = strip_comment_lines(source)
    for match in CALL_RE.finditer(source):
        i = match.end()
        while i < len(source) and source[i] in " \t\n":
            i += 1
        if i < len(source) and source[i] == '"':
            parsed = parse_swift_string_literal(source, i)
            if parsed is not None and parsed[0]:
                yield parsed[0], match.start()
    for regex in (SWIFTUI_RE, MODIFIER_RE):
        for match in regex.finditer(source):
            i = match.end()
            while i < len(source) and source[i] in " \t\n":
                i += 1
            if i < len(source) and source[i] == '"':
                parsed = parse_swift_string_literal(source, i)
                if parsed is not None and parsed[0]:
                    yield parsed[0], match.start()


def catalog_has(catalog_keys: set, skeleton: str) -> bool:
    if skeleton in catalog_keys:
        return True
    if "%@" in skeleton:
        return skeleton.replace("%@", "%lld") in catalog_keys
    return False


def string_unit_leaves(localization) -> list:
    """Flatten a localization dict into every stringUnit leaf."""
    if "stringUnit" in localization:
        return [localization["stringUnit"]]
    leaves = []
    for variation in localization.get("variations", {}).values():
        for unit in variation.values():
            if "stringUnit" in unit:
                leaves.append(unit["stringUnit"])
    return leaves


def catalog_problems(catalog: dict) -> dict:
    """Return {key: [problems]} for every required-language violation."""
    problems = {}
    for key, entry in catalog.get("strings", {}).items():
        if key in EXEMPT_KEYS:
            continue
        localization = entry.get("localizations", {}).get(REQUIRED_LANGUAGE)
        if localization is None:
            problems.setdefault(key, []).append(
                f"missing {REQUIRED_LANGUAGE} localization")
            continue
        leaves = string_unit_leaves(localization)
        if not leaves:
            problems.setdefault(key, []).append(
                f"{REQUIRED_LANGUAGE} localization has no string units")
            continue
        key_specs = placeholder_specs(key)
        for unit in leaves:
            value = unit.get("value")
            if unit.get("state") != "translated":
                problems.setdefault(key, []).append(
                    f"{REQUIRED_LANGUAGE} state is {unit.get('state')!r}, not 'translated'")
            elif not value or not value.strip():
                problems.setdefault(key, []).append(
                    f"{REQUIRED_LANGUAGE} value is empty")
            elif not placeholders_compatible(key_specs, placeholder_specs(value)):
                problems.setdefault(key, []).append(
                    f"{REQUIRED_LANGUAGE} placeholders {placeholder_specs(value)} "
                    f"do not match key placeholders {key_specs}")
    return problems


def placeholders_compatible(key_specs, value_specs) -> bool:
    """A translation's placeholders must substitute like the key's.

    Types are always compared as multisets. Positions matter only when BOTH
    sides are fully positional (a translation may introduce positional
    forms %1$@ to reorder non-positional key arguments, which printf
    handles).
    """
    if sorted(key_specs) == sorted(value_specs):
        return True
    key_types = sorted(kind for _, kind in key_specs)
    value_types = sorted(kind for _, kind in value_specs)
    if key_types != value_types:
        return False
    key_positional = all(pos is not None for pos, _ in key_specs)
    value_positional = all(pos is not None for pos, _ in value_specs)
    if key_positional and value_positional:
        return sorted(key_specs) == sorted(value_specs)
    return True


def required_key_problems(catalog: dict, required_keys) -> dict:
    """Problems for keys the extractor cannot see (REGRESSION_KEYS)."""
    problems = {}
    strings = catalog.get("strings", {})
    all_problems = catalog_problems(catalog)
    for key in required_keys:
        if key not in strings:
            problems.setdefault(key, []).append(
                "regression key absent from the catalog")
        elif key in all_problems:
            problems.setdefault(key, []).extend(all_problems[key])
    return problems


def check(repo_root: str):
    """Full check. Returns (checked_site_count, missing_sites, catalog_problems)."""
    catalog_path = os.path.join(repo_root, "Conduit", "Localizable.xcstrings")
    with open(catalog_path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    catalog_keys = set(catalog["strings"])

    missing = {}
    checked = 0
    source_root = os.path.join(repo_root, "Conduit")
    for dirpath, _dirnames, filenames in os.walk(source_root):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            for skeleton, offset in extract_sites(source):
                checked += 1
                if skeleton in EXEMPT_KEYS:
                    continue
                if catalog_has(catalog_keys, skeleton):
                    continue
                line = source.count("\n", 0, offset) + 1
                rel = os.path.relpath(path, repo_root)
                missing.setdefault(skeleton, []).append(f"{rel}:{line}")
    return checked, missing, catalog_problems(catalog)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify every localizable call site resolves in "
                    "Conduit/Localizable.xcstrings with a real zh-Hans "
                    "translation.")
    parser.add_argument("--repo-root", default=".",
                        help="Repository root (default: current directory).")
    args = parser.parse_args()

    checked, missing, key_problems = check(args.repo_root)
    regression = required_key_problems(
        json.load(open(os.path.join(args.repo_root, "Conduit",
                                    "Localizable.xcstrings"),
                       encoding="utf-8")),
        REGRESSION_KEYS)

    failed = False
    if missing:
        failed = True
        print(f"FAIL: {len(missing)} localizable key(s) missing from the "
              f"String Catalog ({checked} call sites checked):")
        for skeleton in sorted(missing):
            for location in missing[skeleton]:
                print(f"  {location}")
            print(f"    key: {skeleton!r}")
    else:
        print(f"OK: {checked} localizable call sites all resolve in the catalog.")

    all_key_problems = dict(key_problems)
    for key, probs in regression.items():
        all_key_problems.setdefault(key, []).extend(probs)
    if all_key_problems:
        failed = True
        print(f"FAIL: {len(all_key_problems)} catalog key(s) lack a usable "
              f"{REQUIRED_LANGUAGE} translation:")
        for key in sorted(all_key_problems):
            print(f"    {key!r}")
            for problem in all_key_problems[key]:
                print(f"        {problem}")
    if not failed:
        print(f"OK: every catalog key has a real {REQUIRED_LANGUAGE} "
              f"translation with matching placeholders.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
