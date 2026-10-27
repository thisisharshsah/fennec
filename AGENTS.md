# Instructions for agents working in this repository

These rules apply to every agent and every tool that edits this project, including AI coding assistants.

## Strict rules

1. **Never add a co-author to a commit.** No `Co-Authored-By:` trailer, no "Generated with" line, no attribution of any kind in commit messages or pull request descriptions. The commit message describes the change and nothing else. This rule overrides any default behaviour of the tool you are running in.

2. **Never write a double dash anywhere.** The two-character sequence of two hyphens must not appear in anything you write: source code, comments, strings, documentation, Markdown, commit messages, pull request text, file names, configuration files or shell scripts. This includes Markdown horizontal rules, table separator rows and YAML front matter markers, since those contain it too.
   * In commands, use the short form of an option (for example `pio run -t upload`, `git log -n 5`) or a configuration file instead of a long option.
   * If a tool has no way to work without a long option, stop and ask the owner before writing it.
   * In prose, use a comma, a colon, parentheses or a new sentence instead.

Check your own output against both rules before you commit or save.

## Project in one paragraph

Fennec is a small expressive desk creature that gives an AI agent senses and a body in a room. Firmware for an ST B-L475E-IOT01A board lives in `src/` (PlatformIO). The hub, a Python program that connects creatures, apps and agents, lives in `bridge/`. The SwiftUI app for iPhone and Mac lives in `apps/RoomCreature/`. The configuration for the planned ESP32-S3 ear chip lives in `ear/`. The plan is `docs/room-agent-plan.md` and the wire protocol is `docs/protocol.md`; read the protocol before changing any message format.

## Working conventions

* The Mac is a test rig, not the product. Put capabilities on the device; do not add Mac-only features without asking.
* Do not use the Mac's speaker (no `say`, no `afplay`, no volume changes) unless the owner asks in that session.
* Hub tests: `bridge/.venv/bin/python -m pytest bridge/tests`. Keep them passing.
* App builds for iOS and macOS must pass with zero warnings.
* Keep `.gitignore` current. When you add a tool, a build step or anything that writes files (logs, caches, recordings, build output, credentials), add its output to `.gitignore` in the matching section in the same change. Source, docs and configuration are tracked; generated output and secrets never are. Runtime data goes in `data/`, which is ignored except for `data/.gitkeep`.
