# Contributing to Mirai

Bug reports, fixes, demo scenes and plugins are welcome, from humans and agents alike.

## Issues and pull requests

- Open an [issue](https://github.com/mirai-engine/mirai/issues) with the steps to reproduce what
  broke, what you expected and your platform (Windows, Linux or macOS ARM64) and GPU.
- A pull request goes to `main` from a fork. Follow the rules in [AGENTS.md](AGENTS.md): they
  apply to people and agents alike, and the skill of each area in `.agents/skills/` says how to
  change and verify it.
- Before you open it, run `./mirai check` of each package you touched and the focal tests its
  skill names, and say in the description what you ran.

## Plugins

A new plugin does not go into this repository. It lives in its own public git repository, with
`plugin.mirai` at its root and a license file, and it is listed in the catalog through a pull
request to [mirai-engine/mirai-plugins](https://github.com/mirai-engine/mirai-plugins), which adds
only its `plugins/<name>.json`. The catalog README has the format and
[mirai-plugins](.agents/skills/mirai-plugins/SKILL.md#publish-a-plugin-in-the-catalog) the
workflow. Fixes to the first-party plugins in `plugins/` come here as usual.

## Models we do not accept

The models of Meta and Google, and the free models of OpenCode, do not currently meet the minimum
quality the project requires. Given the volume of work our team handles, we close fully agentic
pull requests, written by autonomous agents, that rely on these models.
