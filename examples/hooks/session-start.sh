#!/bin/bash
# SessionStart hook (example) - one-time instruction to read the doctrine.
#
# Fires once per agent session start. Cost: a few hundred chars on the first
# turn, zero on every other turn. The full rules live in doctrine.md, which the
# agent reads on demand when this fires.
#
# Companion to: diligence-reminder.sh (per-turn) and doctrine.md (source of truth).
# See ../../docs/AUTONOMOUS-DILIGENCE.md for how the three fit together.
#
# Install: copy to ~/.claude/hooks/, chmod +x, and register under "SessionStart"
# in your Claude Code settings.json (see AUTONOMOUS-DILIGENCE.md for the JSON).

cat <<'SESSION_EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "SESSION-START INSTRUCTION: read ~/.claude/doctrine.md now, in full. It is the operating doctrine for this workstation. Subsequent UserPromptSubmit reminders refer to it by section. Re-read it when in doubt or when the user references it by section."
  }
}
SESSION_EOF
