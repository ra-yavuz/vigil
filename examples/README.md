# examples/

Drop-in starting points for the [autonomous-diligence pattern](../docs/AUTONOMOUS-DILIGENCE.md).

| File | What it is |
|---|---|
| `doctrine/doctrine.md` | The full operating doctrine. Copy to `~/.claude/doctrine.md` and adapt to your standards. Generic, no project or personal data. |
| `hooks/session-start.sh` | `SessionStart` hook. Tells the agent to read the doctrine once per session. |
| `hooks/diligence-reminder.sh` | `UserPromptSubmit` hook. Re-asserts the non-negotiables and the pre-response check on every turn. |
| `settings.example.json` | A `settings.json` fragment that registers both hooks. Merge the `hooks` block into your own settings. |

## Install

```bash
# 1. Copy the doctrine and edit it to taste.
cp doctrine/doctrine.md ~/.claude/doctrine.md

# 2. Copy the hooks and make them executable.
mkdir -p ~/.claude/hooks
cp hooks/session-start.sh hooks/diligence-reminder.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/session-start.sh ~/.claude/hooks/diligence-reminder.sh

# 3. Merge the "hooks" block from settings.example.json into ~/.claude/settings.json.

# 4. Start a fresh session and confirm:
#    - on the first turn the agent reads doctrine.md,
#    - on later turns the reminder and pre-response check appear.
```

The hooks emit a JSON object on stdout that Claude Code reads as
[hook output](https://docs.claude.com/en/docs/claude-code/hooks). They are plain shell, run
deterministically, and cost no model call. Validate either one yourself with:

```bash
bash hooks/session-start.sh | python3 -m json.tool
```

> Provided as is, without warranty of any kind. See the repository
> [README](../README.md#disclaimer--no-warranty).
