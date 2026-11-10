#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = ["pyyaml>=6"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Checks the documentation of the repository.

No Markdown file links to a path that the repository does not track or to a heading that the
linked file does not have. Every skill opens with YAML frontmatter whose name
is its folder and whose description an agent can trigger on, and .claude/skills is the symlink that
lets Claude Code find them. A row of the Map of a skill links the section of a reference to open,
never a whole file, and no section of a reference passes SECTION_MAX lines, so that opening one
costs a bounded read. A file of docs/game, tracked or still being written, links only inside
docs/game, opens with frontmatter when it is a topic and stays within the line cap of its kind: the
engine serves that folder to projects, where the rest of the repository does not exist.

Every documentation file also keeps its lines within LINE_WIDTH (a lone URL and a table row may
pass) and has no two headings with the same anchor. A file named in backticks (.odin, .slang, .py)
is tracked, and a test named in a Verification section exists in some *_test.odin. Every skill
folder is a row of the table of README.md, and a root CLAUDE.md imports AGENTS.md.

Usage: uv run scripts/check_docs.py
"""

import posixpath
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

import yaml

SKILLS = ".agents/skills/"
SKILLS_LINK = ".claude/skills"
GAME_DOCS = "docs/game/"
GAME_TOPIC_LINES = 80
GAME_TASK_LINES = 120
LINE_WIDTH = 100
DESCRIPTION_MAX = 1024
SECTION_MAX = 200
FENCE = re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.S | re.M)
INLINE = re.compile(r"`[^`\n]*`")
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
DEFINITION = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+\"[^\"]*\")?\s*$", re.M)
EXTERNAL = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.+?)[ \t#]*$", re.M)
HEADING_LEVEL = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.+?)[ \t#]*$")
MAP = re.compile(r"^## Map[ \t]*$(.*?)(?=^## |\Z)", re.S | re.M)
HEADING_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
TAG = re.compile(r"<[^>]+>")
ANCHOR = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"")
SOURCE_SUFFIXES = (".odin", ".slang", ".py")
UNLINTED_PREFIXES = ("assets/", "demo/", "third_party/")
UNLINTED_NAMES = ("THIRD_PARTY_NOTICES.md", "UPSTREAM.md")
PROJECT_DOCS = ("docs/game/", "templates/")
# Names a document may use that no tracked file has: generated files, the include paths of shaders,
# files of the project a game generates, files of other repositories and placeholders.
UNTRACKED_NAMES = (
    "render/shaders_gen.odin",
    "shaders_gen_test.odin",
    "material_schema.slang",
    "shared_constants.slang",
    "surface_programs.slang",
    "surface_coverage.slang",
    "postprocess_programs.slang",
    "vfx_programs.slang",
    "ui_programs.slang",
    "extensions.slang",
    "extension_hooks.slang",
    "extension_probes.slang",
    "game/main.odin",
    "game/names.odin",
    "editor/main.odin",
    "play/main.odin",
    "programs/plugins/deform/deform.slang",
    "scripts/validate.py",
    "name.comp.slang",
    "name.vert.slang",
    "name.frag.slang",
    "a.odin",
    "b.odin",
)
TEST_NAME = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$")
TEST_WORDS = 5
MULTILINE_INLINE = re.compile(r"`([^`\n]+(?:\n[^`\n]+)*)`")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True
    ).stdout
    return [p for p in out.decode("utf-8").split("\0") if p]


def tracked_symlinks(root: Path) -> set[str]:
    out = subprocess.run(
        ["git", "ls-files", "-s", "-z"], cwd=root, check=True, capture_output=True
    ).stdout
    entries = (e.split("\t", 1) for e in out.decode("utf-8").split("\0") if e)
    return {path for meta, path in entries if meta.startswith("120000")}


def links(text: str) -> list[str]:
    text = INLINE.sub("", FENCE.sub("", text))
    return LINK.findall(text) + DEFINITION.findall(text)


def slug(heading: str) -> str:
    """The anchor GitHub gives a heading."""
    text = TAG.sub("", HEADING_LINK.sub(r"\1", heading)).replace("`", "").replace("*", "")
    kept = (c for c in text.lower() if c in " -" or unicodedata.category(c)[0] in "LMN" or c == "_")
    return "".join(kept).replace(" ", "-")


def anchors(text: str) -> set[str]:
    found: set[str] = set(ANCHOR.findall(text))
    seen: dict[str, int] = {}
    for heading in HEADING.findall(FENCE.sub("", text)):
        base = slug(heading)
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def sections(text: str) -> list[tuple[int, str, int, int]]:
    """Every heading outside fences as (level, heading, line, lines up to the next heading that
    is not below it)."""
    heads: list[tuple[int, str, int]] = []
    fence = ""
    lines = text.split("\n")
    for number, line in enumerate(lines, 1):
        marker = re.match(r"^(```|~~~)", line)
        if marker:
            fence = "" if fence == marker.group(1) else fence or marker.group(1)
        elif not fence and (h := HEADING_LEVEL.match(line)):
            heads.append((len(h.group(1)), h.group(2), number))
    found = []
    for i, (level, heading, number) in enumerate(heads):
        end = next((n for lv, _, n in heads[i + 1 :] if lv <= level), len(lines) + 1)
        found.append((level, heading, number, end - number))
    return found


def section_errors(p: str, text: str) -> list[str]:
    """Sections of a reference above SECTION_MAX lines; the title (level 1) is the file itself."""
    return [
        f"{p}:{number}: section {heading!r} has {size} lines; split it at its sub-headings, "
        f"promoting them if needed, to keep {SECTION_MAX}"
        for level, heading, number, size in sections(text)
        if level > 1 and size > SECTION_MAX
    ]


def map_errors(p: str, text: str, texts: dict[str, str]) -> list[str]:
    """Rows of the Map of a skill that link a reference without the section to open."""
    errors: list[str] = []
    found = MAP.search(FENCE.sub("", text))
    for target in links(found.group(1)) if found else []:
        if EXTERNAL.match(target):
            continue
        resolved, fragment = resolve_link(p, target)
        if not (resolved.startswith(SKILLS) and "/references/" in resolved):
            continue
        if not fragment:
            errors.append(f"{p}: the Map links {target}, a whole file; link the section to open")
            continue
        title = next(iter(sections(texts.get(resolved, ""))), None)
        if title and title[0] == 1 and slug(title[1]) == fragment.lower():
            if len(texts[resolved].splitlines()) > SECTION_MAX:
                errors.append(
                    f"{p}: the Map links {target}, the title of a file of more than {SECTION_MAX} "
                    "lines; link the section to open"
                )
    return errors


def frontmatter_errors(p: str, text: str, name: str, source: str) -> list[str]:
    if not text.startswith("---\n"):
        return [f"{p}: the first line must be --- to open the YAML frontmatter"]
    end = text.find("\n---\n", 4)
    if end < 0:
        return [f"{p}: the frontmatter has no closing --- on a line of its own"]
    try:
        fields = yaml.safe_load(text[4:end])
    except yaml.YAMLError as e:
        return [f"{p}: the frontmatter is not valid YAML ({e.problem}); quote a value with ': '"]
    if not isinstance(fields, dict):
        return [f"{p}: the frontmatter must be a mapping with name and description"]
    errors: list[str] = []
    if fields.get("name") != name:
        errors.append(f"{p}: name must be {name!r}, the name of its {source}")
    description = fields.get("description")
    if not isinstance(description, str) or not description.strip():
        errors.append(f"{p}: description is missing; say what it covers and when to use it")
    elif len(description) > DESCRIPTION_MAX:
        errors.append(f"{p}: description has {len(description)} characters; keep {DESCRIPTION_MAX}")
    return errors


def resolve_link(p: str, target: str) -> tuple[str, str]:
    """The repository path a link of the file p points to, and its fragment."""
    path, _, fragment = unquote(target.split("?", 1)[0]).partition("#")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(p), path)) if path else p
    return resolved, fragment


def game_doc_files(root: Path) -> set[str]:
    return {f.relative_to(root).as_posix() for f in (root / GAME_DOCS).rglob("*.md")}


def game_doc_errors(p: str, text: str) -> list[str]:
    errors: list[str] = []
    for target in links(text):
        if EXTERNAL.match(target):
            continue
        resolved, _ = resolve_link(p, target)
        if not resolved.startswith(GAME_DOCS):
            errors.append(f"{p}: links to {target}, outside {GAME_DOCS}; a project gets only that")
    depth = p.count("/") - GAME_DOCS.count("/")
    if depth > 1:
        return errors + [f"{p}: a task file goes straight under its topic: {GAME_DOCS}<topic>/<task>.md"]
    if depth == 0:
        errors += frontmatter_errors(p, text, posixpath.basename(p)[: -len(".md")], "file")
    cap = GAME_TASK_LINES if depth else GAME_TOPIC_LINES
    lines = text.splitlines()
    if len(lines) > cap:
        errors.append(f"{p}: has {len(lines)} lines; keep {cap}")
    return errors


def linted(p: str) -> bool:
    """Documentation the repository writes itself, not the files of third parties."""
    name = posixpath.basename(p)
    return not (p.startswith(UNLINTED_PREFIXES) or name in UNLINTED_NAMES or name.startswith("LICENSE"))


def prose(text: str) -> list[tuple[int, str]]:
    """Every line outside fenced code as (number, line)."""
    found = []
    fence = ""
    for number, line in enumerate(text.split("\n"), 1):
        marker = re.match(r"^(```|~~~)", line)
        if marker:
            fence = "" if fence == marker.group(1) else fence or marker.group(1)
        elif not fence:
            found.append((number, line))
    return found


def width_errors(p: str, text: str) -> list[str]:
    """Lines above LINE_WIDTH, except a lone token (a URL) and a table row."""
    return [
        f"{p}:{number}: has {len(line)} characters; keep {LINE_WIDTH}"
        for number, line in enumerate(text.splitlines(), 1)
        if len(line) > LINE_WIDTH and " " in line.strip() and not line.lstrip().startswith("|")
    ]


def duplicate_heading_errors(p: str, text: str) -> list[str]:
    """Two headings of a file with the same anchor: a link reaches only the first."""
    seen: dict[str, int] = {}
    errors: list[str] = []
    for _, heading, number, _ in sections(text):
        key = slug(heading)
        if key in seen:
            errors.append(f"{p}:{number}: heading {heading!r} repeats the one at line {seen[key]}")
        else:
            seen[key] = number
    return errors


def source_names(span: str) -> list[str]:
    """The files named by the words of one inline code span, without line numbers."""
    names = []
    for word in span.split():
        word = re.sub(r"(?::\d+(?:-\d+)?)?[.,;:)]*$", "", word.lstrip("(")).removeprefix("./")
        if (
            word.endswith(SOURCE_SUFFIXES)
            and word.rpartition("/")[2].partition(".")[0].strip("_")
            and not word.startswith(("_", "/", "-", "~", ".mirai/", "bin/", ".deps/"))
            and not re.search(r"[*<>{}$\[\]|=%\\]", word)
            and not re.match(r"^[A-Za-z]:", word)
        ):
            names.append(word)
    return names


def untracked_name(name: str) -> bool:
    return any(name == g or name.endswith("/" + g) for g in UNTRACKED_NAMES)


def file_errors(p: str, text: str, known: set[str]) -> list[str]:
    """Files named in backticks that the repository does not track."""
    return [
        f"{p}:{number}: names {name}, which is not a tracked file"
        for number, line in prose(text)
        for span in INLINE.findall(line)
        for name in source_names(span.strip("`"))
        if name not in known and not untracked_name(name)
    ]


def known_paths(files: list[str]) -> set[str]:
    """Every tracked path and each of its trailing sub-paths: a doc may name a file by its tail."""
    known: set[str] = set()
    for f in files:
        parts = f.split("/")
        known.update("/".join(parts[i:]) for i in range(len(parts)))
    return known


def test_words(root: Path, files: list[str]) -> set[str]:
    """The identifiers of the test files, which include the names of their tests."""
    words: set[str] = set()
    for f in files:
        if f.endswith("_test.odin") and (root / f).exists():
            words.update(WORD.findall((root / f).read_text(encoding="utf-8")))
    return words


def verification_name_errors(p: str, text: str, tests: set[str]) -> list[str]:
    """Test-like names in a Verification section that no *_test.odin declares. A code span may
    run over several lines, as a `mirai test` command with its test names does."""
    kept = dict(prose(text))
    errors = []
    for _, heading, start, size in sections(text):
        if not heading.lower().startswith("verification"):
            continue
        numbers = range(start, start + size)
        body = "\n".join(kept.get(n, "") for n in numbers)
        for span in MULTILINE_INLINE.finditer(body):
            for token in span.group(1).split():
                if (
                    TEST_NAME.match(token)
                    and (token.count("_") + 1 >= TEST_WORDS or token.startswith("test_"))
                    and token not in tests
                ):
                    number = start + body.count("\n", 0, span.start(1) + span.group(1).find(token))
                    errors.append(
                        f"{p}:{number}: Verification names {token}, which no *_test.odin declares"
                    )
    return errors


def readme_errors(skills: list[str], readme: str) -> list[str]:
    """Skill folders that the table of README.md does not list."""
    return [
        f"README.md: the skill table lacks {name}; add its row"
        for name in skills
        if f"{SKILLS}{name}/SKILL.md" not in readme
    ]


def claude_errors(claude: str | None, agents: bool) -> list[str]:
    """A root CLAUDE.md that does not import AGENTS.md leaves Claude Code without its rules."""
    if claude is not None and agents and not re.search(r"^@AGENTS\.md\s*$", claude, re.M):
        return ["CLAUDE.md: must import AGENTS.md with a line @AGENTS.md"]
    return []


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    files = tracked_files(root)
    game_docs = game_doc_files(root)
    present = {p for p in files if (root / p).exists()} | game_docs
    folders = {posixpath.dirname(p) for p in present}
    for p in list(folders):
        while p:
            p = posixpath.dirname(p)
            folders.add(p)
    markdown = sorted(p for p in present if p.endswith(".md"))
    errors: list[str] = []

    texts = {p: (root / p).read_text(encoding="utf-8") for p in markdown}

    headings: dict[str, set[str]] = {}
    for p, text in texts.items():
        for target in links(text):
            if EXTERNAL.match(target):
                continue
            resolved, fragment = resolve_link(p, target)
            if resolved.startswith(".."):
                continue
            if resolved not in present and resolved not in folders:
                errors.append(f"{p}: links to {target}, which is not in the repository")
                continue
            if fragment and resolved in texts:
                if resolved not in headings:
                    headings[resolved] = anchors(texts[resolved])
                if fragment.lower() not in headings[resolved]:
                    errors.append(f"{p}: links to {target}, but {resolved} has no such heading")

    for p in sorted(game_docs):
        errors += game_doc_errors(p, texts[p])

    known = known_paths(files)
    tests = test_words(root, files)
    for p in markdown:
        if not linted(p):
            continue
        errors += width_errors(p, texts[p])
        errors += duplicate_heading_errors(p, texts[p])
        if not p.startswith(PROJECT_DOCS):
            errors += file_errors(p, texts[p], known)
            errors += verification_name_errors(p, texts[p], tests)

    skills = sorted(p for p in present if p.startswith(SKILLS) and p.count("/") == 3)
    for p in skills:
        if posixpath.basename(p) == "SKILL.md":
            errors += frontmatter_errors(p, texts[p], posixpath.basename(posixpath.dirname(p)), "folder")
            errors += map_errors(p, texts[p], texts)
    for p in markdown:
        if p.startswith(SKILLS) and "/references/" in p:
            errors += section_errors(p, texts[p])
    skill_names = sorted({p.split("/")[2] for p in skills})
    errors += readme_errors(skill_names, texts.get("README.md", ""))
    claude = root / "CLAUDE.md"
    errors += claude_errors(
        claude.read_text(encoding="utf-8") if claude.exists() else None, "AGENTS.md" in present
    )
    if SKILLS_LINK not in tracked_symlinks(root):
        errors.append(f"{SKILLS_LINK}: must be a symlink to ../{SKILLS.rstrip('/')} in git")
    elif not (root / SKILLS_LINK).is_symlink():
        errors.append(
            f"{SKILLS_LINK}: git checked it out as a file, so Claude Code finds no skill; run "
            f"git config core.symlinks true, delete it and git checkout -- {SKILLS_LINK}"
        )

    for e in errors:
        print(e)
    print(f"{len(errors)} problems in {len(markdown)} Markdown files")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
