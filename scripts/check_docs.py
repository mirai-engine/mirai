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
lets Claude Code find them. A file of docs/game, tracked or still being written, links only inside
docs/game, opens with frontmatter when it is a topic and stays within the line cap of its kind: the
engine serves that folder to projects, where the rest of the repository does not exist.

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
FENCE = re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.S | re.M)
INLINE = re.compile(r"`[^`\n]*`")
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
DEFINITION = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+\"[^\"]*\")?\s*$", re.M)
EXTERNAL = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.+?)[ \t#]*$", re.M)
HEADING_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
TAG = re.compile(r"<[^>]+>")
ANCHOR = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"")


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
    for number, line in enumerate(lines, 1):
        if len(line) > LINE_WIDTH and " " in line.strip():
            errors.append(f"{p}:{number}: has {len(line)} characters; keep {LINE_WIDTH}")
    return errors


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

    skills = sorted(p for p in present if p.startswith(SKILLS) and p.count("/") == 3)
    for p in skills:
        if posixpath.basename(p) == "SKILL.md":
            errors += frontmatter_errors(p, texts[p], posixpath.basename(posixpath.dirname(p)), "folder")
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
