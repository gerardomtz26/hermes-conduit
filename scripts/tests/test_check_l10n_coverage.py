"""Regression coverage for scripts/check-l10n-coverage.py (catalog guard)."""

import importlib.util
import json
import os
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "check_l10n_coverage", os.path.join(SCRIPTS_DIR, "check-l10n-coverage.py"))
check_l10n_coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_l10n_coverage)

parse = check_l10n_coverage.parse_swift_string_literal
extract = check_l10n_coverage.extract_sites
specs = check_l10n_coverage.placeholder_specs
compatible = check_l10n_coverage.placeholders_compatible
problems_for = check_l10n_coverage.catalog_problems


class StringLiteralParsingTests(unittest.TestCase):
    def test_plain_literal(self):
        self.assertEqual(parse('"Hello"', 0), ("Hello", 7, False))

    def test_escaped_quote_and_backslash(self):
        self.assertEqual(parse('"a\\"b\\\\"', 0), ('a"b\\', 8, False))

    def test_escapes_are_decoded_for_key_matching(self):
        self.assertEqual(parse('"line\\nbreak"', 0), ("line\nbreak", 13, False))

    def test_interpolation_becomes_placeholder(self):
        skeleton, end, has_interp = parse('"prefix \\(value) suffix"', 0)
        self.assertEqual(skeleton, "prefix %@ suffix")
        self.assertTrue(has_interp)
        self.assertEqual(end, len('"prefix \\(value) suffix"'))

    def test_interpolation_with_nested_string_and_parens(self):
        source = r'"a \(f("x", (1 + 2))) b"'
        skeleton, _end, has_interp = parse(source, 0)
        self.assertEqual(skeleton, "a %@ b")
        self.assertTrue(has_interp)

    def test_unterminated_returns_none(self):
        self.assertIsNone(parse('"no close', 0))


class ExtractSiteTests(unittest.TestCase):
    def test_string_localized_call_is_found(self):
        source = 'return String(localized: "Hello \\(name)!")'
        sites = list(extract(source))
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0][0], "Hello %@!")

    def test_app_localization_string_call_is_found(self):
        source = 'return AppLocalization.string("Hello \\(name)!")'
        sites = list(extract(source))
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0][0], "Hello %@!")

    def test_multiline_app_localization_call_is_found(self):
        source = 'return AppLocalization.string(\n    "Hello")'
        sites = list(extract(source))
        self.assertEqual([s[0] for s in sites], ["Hello"])

    def test_swiftui_initializer_literal_is_found(self):
        source = 'Text("Welcome back")'
        sites = list(extract(source))
        self.assertEqual(sites[0][0], "Welcome back")

    def test_extended_swiftui_initializers_are_found(self):
        source = ('ProgressView("Loading")\n'
                  'ContentUnavailableView("Empty", systemImage: "tray")\n'
                  'Section("Header") {}\n'
                  'Menu("Title") {}\n'
                  'GroupBox("Note") {}')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons,
                         ["Loading", "Empty", "Header", "Title", "Note"])

    def test_alert_and_confirmation_dialog_literals_are_found(self):
        source = ('view.alert("Delete?", isPresented: $shown) {}\n'
                  'view.confirmationDialog("Archive 1 Task?", isPresented: $p) {}')
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons, ["Delete?", "Archive 1 Task?"])

    def test_full_line_comments_are_skipped(self):
        source = '// Text("not a call site")\nText("real")'
        skeletons = [s[0] for s in extract(source)]
        self.assertEqual(skeletons, ["real"])

    def test_swiftui_variable_argument_is_skipped(self):
        source = "Text(message)\nLabel(title, systemImage: \"star\")"
        self.assertEqual(list(extract(source)), [])

    def test_non_localized_string_is_skipped(self):
        source = 'let url = URL(string: "https://example.com")'
        self.assertEqual(list(extract(source)), [])


class CatalogHasTests(unittest.TestCase):
    def test_static_key_requires_exact_match(self):
        keys = {"Hello"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys, "Hello"))
        self.assertFalse(check_l10n_coverage.catalog_has(keys, "Hello!"))

    def test_interpolated_key_accepts_placeholder_variants(self):
        keys = {"%lld tokens"}
        self.assertTrue(check_l10n_coverage.catalog_has(keys, "%@ tokens"))
        self.assertFalse(check_l10n_coverage.catalog_has(keys, "%@ of %@"))


class PlaceholderTests(unittest.TestCase):
    def test_printf_forms_are_typed(self):
        self.assertEqual(specs("%@"), [(None, "object")])
        self.assertEqual(specs("%lld"), [(None, "int")])
        self.assertEqual(specs("%d"), [(None, "int")])
        self.assertEqual(specs("%f"), [(None, "float")])
        self.assertEqual(specs("%%"), [])

    def test_positional_forms_keep_indices(self):
        self.assertEqual(specs("%1$@ and %2$@"),
                         [(1, "object"), (2, "object")])
        self.assertEqual(specs("%1$lld items"),
                         [(1, "int")])

    def test_multiple_placeholders(self):
        self.assertEqual(specs("%@ of %lld (%@)"),
                         [(None, "object"), (None, "int"), (None, "object")])

    def test_compatible_positions_and_types(self):
        key = [(None, "object"), (None, "int")]
        # Identical non-positional forms are compatible.
        self.assertTrue(compatible(key, list(key)))
        # A translation may switch to positional forms to reorder.
        self.assertTrue(compatible(key, [(1, "object"), (2, "int")]))
        # Type mismatch is never compatible.
        self.assertFalse(compatible(key, [(None, "int"), (None, "int")]))
        # Fully positional on both sides must match index-for-index.
        self.assertTrue(compatible([(1, "object"), (2, "object")],
                                   [(1, "object"), (2, "object")]))
        # Same index sets with equal types still match.
        self.assertTrue(compatible([(1, "object"), (2, "object")],
                                   [(2, "object"), (1, "object")]))
        # Swapped indices with different types do not.
        self.assertFalse(compatible([(1, "object"), (2, "int")],
                                    [(2, "object"), (1, "int")]))


def zh_catalog(key, value, state="translated"):
    return {"strings": {key: {"localizations": {"zh-Hans": {
        "stringUnit": {"state": state, "value": value}}}}}}


class CatalogProblemTests(unittest.TestCase):
    def test_missing_zh_hans_is_reported(self):
        catalog = {"strings": {"Hello": {"localizations": {
            "en": {"stringUnit": {"state": "translated", "value": "Hello"}}}}}}
        problems = problems_for(catalog)
        self.assertIn("Hello", problems)
        self.assertTrue(any("missing zh-Hans" in p for p in problems["Hello"]))

    def test_empty_value_is_reported(self):
        problems = problems_for(zh_catalog("Hello", "  "))
        self.assertTrue(any("empty" in p for p in problems["Hello"]))

    def test_untranslated_state_is_reported(self):
        problems = problems_for(zh_catalog("Hello", "你好", state="new"))
        self.assertTrue(any("state is 'new'" in p for p in problems["Hello"]))

    def test_placeholder_mismatch_is_reported(self):
        problems = problems_for(zh_catalog("%lld files", "%@ 个文件"))
        self.assertTrue(any("placeholders" in p for p in problems["%lld files"]))

    def test_positional_translation_is_accepted(self):
        catalog = {"strings": {"Move %@ selected %@": {"localizations": {
            "zh-Hans": {"stringUnit": {
                "state": "translated",
                "value": "移动所选 %1$@ 个 %2$@"}}}}}}
        self.assertEqual(problems_for(catalog), {})

    def test_translated_direct_entry_passes(self):
        self.assertEqual(problems_for(zh_catalog("Hello", "你好")), {})

    def test_variation_only_translation_passes(self):
        catalog = {"strings": {"%lld conversations": {"localizations": {
            "zh-Hans": {"variations": {"plural": {"other": {
                "stringUnit": {"state": "translated", "value": "%lld 个会话"}}}}}}}}}
        self.assertEqual(problems_for(catalog), {})

    def test_variation_leaf_violation_is_reported(self):
        catalog = {"strings": {"%lld conversations": {"localizations": {
            "zh-Hans": {"variations": {"plural": {"other": {
                "stringUnit": {"state": "new", "value": "%lld 个会话"}}}}}}}}}
        problems = problems_for(catalog)
        self.assertTrue(any("state is 'new'" in p for p in problems["%lld conversations"]))

    def test_exempt_keys_are_not_required(self):
        catalog = {"strings": {"Hermes": {"localizations": {}}}}
        self.assertEqual(problems_for(catalog), {})

    def test_regression_keys_are_enforced(self):
        catalog = {"strings": {}}
        problems = check_l10n_coverage.required_key_problems(
            catalog, ["Missing regression key"])
        self.assertIn("Missing regression key", problems)


class CheckIntegrationTests(unittest.TestCase):
    def test_repo_catalog_covers_every_call_site(self):
        checked, missing, key_problems = check_l10n_coverage.check(
            os.path.dirname(SCRIPTS_DIR))
        self.assertEqual(
            missing, {},
            f"localizable keys missing from the catalog: {sorted(missing)}")
        self.assertGreater(checked, 1000)
        self.assertEqual(
            key_problems, {},
            f"catalog keys without usable zh-Hans: {sorted(key_problems)}")
        for key in check_l10n_coverage.REGRESSION_KEYS:
            self.assertIn(key, keys_view())


def keys_view():
    """Helper: the repo catalog's keys, for regression-key assertions."""
    catalog_path = os.path.join(os.path.dirname(SCRIPTS_DIR),
                                "Conduit", "Localizable.xcstrings")
    with open(catalog_path, encoding="utf-8") as handle:
        return set(json.load(handle)["strings"])


if __name__ == "__main__":
    unittest.main()
