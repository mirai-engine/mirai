"""Self-check of the rules of scripts/check_docs.py.

Usage: uv run --with pyyaml scripts/tests/test_check_docs.py
"""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "check_docs", Path(__file__).resolve().parents[1] / "check_docs.py"
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class LineWidthTest(unittest.TestCase):
    def test_a_long_line_fails_unless_it_is_a_lone_url_or_a_table_row(self):
        long_line = "word " * 30
        text = "\n".join(
            [long_line, "https://example.com/" + "a" * 120, "| " + long_line + " |", "short"]
        )
        errors = checker.width_errors("a.md", text)
        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("a.md:1:"))


class DuplicateHeadingTest(unittest.TestCase):
    def test_two_headings_with_one_anchor_fail_but_a_fenced_one_does_not(self):
        text = "# T\n\n## Widgets\n\n```\n## Widgets\n```\n\n### `Widgets`\n"
        errors = checker.duplicate_heading_errors("a.md", text)
        self.assertEqual(len(errors), 1)
        self.assertIn("line 3", errors[0])


class FileNameTest(unittest.TestCase):
    known = checker.known_paths(["core/table.odin", "plugins/x/runtime/y.odin"])

    def errors(self, text):
        return checker.file_errors("a.md", text, self.known)

    def test_a_file_is_found_by_its_name_or_any_tail_of_its_path(self):
        self.assertEqual(self.errors("`table.odin` `core/table.odin` `runtime/y.odin:12-30`"), [])

    def test_a_missing_file_fails_with_its_line(self):
        errors = self.errors("ok\nsee `core/gone.odin` and `scripts/none.py`")
        self.assertEqual(len(errors), 2)
        self.assertIn("a.md:2:", errors[0])

    def test_generated_files_patterns_and_fences_are_not_checked(self):
        text = "`render/shaders_gen.odin` `*_test.odin` `_test.odin` `<name>.slang` `/abs/x.py`\n"
        text += "```\n`core/gone.odin`\n```\n"
        self.assertEqual(self.errors(text), [])


class VerificationTest(unittest.TestCase):
    def test_only_test_like_names_of_a_verification_section_must_exist(self):
        name = "a_name_with_five_words_long"
        text = (
            f"# T\n\n## Map\n\n- `{name}`\n\n## Verification\n\n- `{name}`, `a_short_name` and\n"
            "  `one_that_is_gone_from_every_test_file`\n\n## Other\n\n- `another_gone_name_of_five`\n"
        )
        errors = checker.verification_name_errors("a.md", text, {name})
        self.assertEqual(len(errors), 1)
        self.assertIn("one_that_is_gone", errors[0])
        self.assertIn("a.md:10:", errors[0])


class RepositoryRulesTest(unittest.TestCase):
    def test_every_skill_must_be_a_row_of_the_readme(self):
        readme = "| a | [x](.agents/skills/mirai-x/SKILL.md) |"
        self.assertEqual(checker.readme_errors(["mirai-x"], readme), [])
        self.assertEqual(len(checker.readme_errors(["mirai-x", "mirai-y"], readme)), 1)

    def test_a_claude_file_imports_agents_only_when_both_exist(self):
        self.assertEqual(checker.claude_errors(None, True), [])
        self.assertEqual(checker.claude_errors("x", False), [])
        self.assertEqual(checker.claude_errors("@AGENTS.md\n", True), [])
        self.assertEqual(len(checker.claude_errors("see AGENTS.md\n", True)), 1)

    def test_a_map_row_that_links_a_whole_reference_fails(self):
        skill = ".agents/skills/s/SKILL.md"
        reference = ".agents/skills/s/references/r.md"
        texts = {reference: "# R\n\n## Part\n\ntext\n"}
        bad = "## Map\n\n| Task | Section |\n| --- | --- |\n| x | [r](references/r.md) |\n"
        good = bad.replace("r.md)", "r.md#part)")
        self.assertEqual(len(checker.map_errors(skill, bad, texts)), 1)
        self.assertEqual(checker.map_errors(skill, good, texts), [])


if __name__ == "__main__":
    unittest.main()
