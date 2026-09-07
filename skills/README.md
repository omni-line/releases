# Agent skills

Skills that let a coding agent (Claude Code, Codex, Cursor, and others that read
`SKILL.md`) operate Omni Line on a host. They are synced to
`github.com/omni-line/releases` under `skills/` on every release, next to `install.sh`.

| Skill | Purpose |
|---|---|
| [`omniline/`](omniline/) | Detect an existing install, then install, upgrade, activate the license, create the first org and PAT, or troubleshoot. Wraps `install.sh`; never reinstalls over data. |

## Install the skill

With the `skills` CLI (any agent that supports the SKILL.md format):

```bash
npx skills add omni-line/releases
```

Manually, for Claude Code:

```bash
mkdir -p .claude/skills
git clone --depth 1 https://github.com/omni-line/releases.git /tmp/omni-line-releases
cp -a /tmp/omni-line-releases/skills/omniline .claude/skills/omniline
```

Then, on the target host or over SSH from your machine:

```
Install Omni Line on this host. Public URL is http://203.0.113.10:8080 and the license key is OMNI-...
```

The skill asks only for the public URL and the license key. Everything else uses
the installer defaults, and an existing install is upgraded instead of replaced.

## Editing

`SKILL.md` stays short: rules, detection, routing. Procedure lives in
`references/*.md`, one file per phase. Keep commands in sync with `install.sh` flags
and with the public docs mirrors at `https://omniline.app/docs/<path>.md`; the docs
are the source of truth for API shapes.
