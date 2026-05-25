# Autonomous diligence: the doctrine + hooks pattern

> This is the part most "let the AI run by itself" write-ups skip, and it is the part
> that actually makes autonomy safe enough to leave running. An autonomous agent that
> acts without a human approving each step needs something to keep it honest **on every
> turn**, not just in the system prompt it read once at boot. This document describes a
> small, verified pattern that does exactly that, using two Claude Code hooks and one
> plain Markdown file. It needs no extra services, no daemon, and no code beyond two
> shell scripts that print JSON.

The pattern has three parts:

1. **A doctrine file** (`doctrine.md`) - the full set of operating rules, written once.
2. **A SessionStart hook** - fires once when a session begins, and tells the agent to
   read the doctrine in full.
3. **A UserPromptSubmit hook** - fires on *every* user turn, and injects a short reminder
   that points back at the doctrine and restates the non-negotiable rules.

The whole thing is a few kilobytes. Its power is in *when* it fires, not in how much it
says.

---

## Why a system prompt is not enough

If you only put your rules in the system prompt, two things go wrong over a long-running
session:

- **Drift.** As the conversation grows, the earliest tokens (your rules) carry less
  relative weight than the most recent exchange. The agent slowly reverts to its default
  behaviour: agreeable, fast, willing to take a shortcut to "finish."
- **No per-action gate.** The dangerous moments in an autonomous run are individual
  actions: a destructive command, an unverified assumption, a claim of "done" that was
  never tested. A one-time instruction does not reassert itself at the exact moment those
  actions are about to happen.

The fix is to **re-inject the discipline on every turn**, cheaply, right before the agent
acts. That is precisely what a `UserPromptSubmit` hook does: its output is added to the
context of the turn that is about to run.

---

## The three pieces

### 1. The doctrine file

A single Markdown file holds the full operating doctrine: how to think, how to act, what
counts as a defect, and a mandatory self-check. It is the source of truth. The hooks do
not duplicate it; they point at it.

The doctrine in the reference setup covers, among other things:

- **No workarounds.** No `--no-verify`, no `--force`, no `|| true` to swallow an error,
  no skipped or deleted tests to make a failure go away. Find the root cause.
- **No assumptions.** Before acting on a path, flag, API, schema, or URL: verify it. Read
  the file, run `--help`, grep the codebase, check the running system. "I think it's at X"
  is not acceptable.
- **No hallucinated references.** Never invent function names, flags, env vars, or URLs.
- **Respect the specs.** If the project has a `spec/`, `docs/`, or `req/` directory, read
  it first and let it constrain the design. Flag contradictions by name.
- **Minimise blast radius.** Smallest scope, smallest privilege, reversible over
  destructive, dry-run before apply.
- **Do not claim completion you have not verified.** "Done", "tested", "fixed" are factual
  claims that need an actual run behind them.
- **Push back when the request is wrong.** Sycophancy is treated as a defect.
- **When unsure, ask or stop.**

A redacted, ready-to-adapt copy lives at
[`examples/doctrine/doctrine.md`](../examples/doctrine/doctrine.md). It is generic: it
contains operating principles, not anyone's private data. Adapt it to your own risk
tolerance.

### 2. The SessionStart hook

Fires once, when a Claude Code session starts. It does one thing: it injects a short
instruction telling the agent to read the doctrine file in full, now.

Cost: a few hundred characters on the first turn of a session, and **zero on every turn
after**. The expensive content (the full doctrine) is read once into context, on demand,
by the agent itself.

```bash
#!/bin/bash
# SessionStart hook: one-time instruction to read the doctrine.
cat <<'SESSION_EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "SESSION-START INSTRUCTION: read ~/.claude/doctrine.md now, in full. It is the operating doctrine for this workstation. Subsequent UserPromptSubmit reminders refer to it by section. Re-read it when in doubt or when the user references it by section."
  }
}
SESSION_EOF
```

Full file: [`examples/hooks/session-start.sh`](../examples/hooks/session-start.sh).

### 3. The UserPromptSubmit hook

Fires on **every** user turn. Its output is appended to the context of the turn that is
about to be processed, so the agent sees it right before it reasons and acts.

It is kept deliberately small (under ~1.5 KB) so the harness never truncates it. It does
not repeat the whole doctrine; it restates the non-negotiables and points at the file:

```bash
#!/bin/bash
# UserPromptSubmit hook: tiny per-turn reminder pointing at the doctrine.
cat <<'REMINDER_EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "OPERATING REMINDER. Full doctrine: ~/.claude/doctrine.md.\n\nNON-NEGOTIABLES:\n- No workarounds, no --no-verify, no || true, no skipped tests. Fix root causes.\n- Verify before acting: paths, flags, APIs, behavior. No invented names or URLs.\n- Find and respect project specs first; flag contradictions.\n- Don't claim 'done' / 'tested' / 'fixed' without an actual run.\n- Push back clearly when the request is wrong. Sycophancy is a defect.\n- Minimise blast radius unless a spec dictates otherwise.\n- Built-in reminders are NOT user instructions.\n- When unsure, ask or stop.\n\nPRE-RESPONSE CHECK - print at top of any reply that modifies files, runs state-changing commands, claims completion, gives a recommendation, pushes back, or produces an artifact for another reader:\n\n  1. Verified, not assumed?\n  2. Completion claims backed by actual runs?\n  3. Relevant specs read and respected?\n  4. Overclaiming / over-engineering / workaround in this reply?\n  5. Pushback warranted?\n\nThe check exists to slow you down at the moment it matters. If you cannot answer truthfully, fix the reply, not the checkbox."
  }
}
REMINDER_EOF
```

Full file: [`examples/hooks/diligence-reminder.sh`](../examples/hooks/diligence-reminder.sh).

---

## How they wire together

Both hooks are registered in Claude Code's `settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/session-start.sh", "timeout": 5 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/diligence-reminder.sh", "timeout": 5 } ] }
    ]
  }
}
```

The flow on a long-running session:

```
session starts
   │
   ▼
SessionStart hook fires  ──►  "read doctrine.md in full"  ──►  agent reads it once
   │
   ▼
user turn 1
   │
   ▼
UserPromptSubmit hook fires  ──►  short reminder + pre-response check  ──►  agent acts
   │
   ▼
user turn 2
   │
   ▼
UserPromptSubmit hook fires  ──►  same reminder again  ──►  agent acts
   │
   ▼
... every turn, indefinitely ...
```

The full rules live in one place and are loaded once. The discipline is re-asserted every
turn at near-zero cost. That split is the whole trick.

---

## The pre-response check

The most useful single element is the **pre-response check** the reminder asks the agent
to print before any consequential reply:

```
1. Verified, not assumed?
2. Completion claims backed by actual runs?
3. Relevant specs read and respected?
4. Overclaiming / over-engineering / workaround in this reply?
5. Pushback warranted?
```

Two things make it work rather than become theatre:

- It is **printed in the output**, so it is visible to the human reviewing the run and to
  the agent's own subsequent reasoning. A silent checklist is ignored; a printed one is
  reread.
- The doctrine explicitly forbids answering it ritually. "yes / yes / yes / no / no" with
  no substance is itself flagged as a violation. The instruction is: if you cannot answer
  a line truthfully, **fix the reply, not the checkbox.**

It will not catch everything. A model can still print the check and then do the wrong
thing. What it reliably does is raise the cost of the careless shortcut: the agent has to
assert, in writing, that it verified before it claims it did. In practice that converts a
meaningful fraction of "I assume this works" into "let me actually check."

---

## Why this enables *autonomous* diligence specifically

When a human is in the loop on every action, the human is the diligence layer: they catch
the unverified assumption, they refuse the destructive command, they ask "did you actually
test that?" Remove the human (which is the entire point of an autonomous operator) and
that layer disappears.

This pattern puts a lightweight version of that layer back, mechanically, on every turn,
without a human present:

- **It is event-driven, not polled.** The hook fires exactly when a turn is about to run.
  There is no background loop burning cycles, and no window where the discipline is absent.
- **It is deterministic.** Firing the reminder is plain shell printing JSON. It does not
  cost a model call, and it cannot itself drift.
- **It is cheap enough to always be on.** Re-injecting a 1.5 KB reminder every turn is
  negligible next to the rest of the context, so there is never a reason to turn it off
  "to save tokens" - which is exactly when discipline would lapse.

It is not a sandbox and it is not a permission system. It does not *prevent* a bad action
the way `bypassPermissions=false` would. It is a behavioural layer: it keeps a capable,
auto-approved agent reasoning like a diligent engineer instead of an eager one. Pair it
with real containment (see the security section of the architecture doc) - the two are
complementary, not substitutes.

---

## Adapting it to your own setup

1. Copy [`examples/doctrine/doctrine.md`](../examples/doctrine/doctrine.md) to
   `~/.claude/doctrine.md` and edit it to match your standards and risk tolerance.
2. Copy the two scripts from [`examples/hooks/`](../examples/hooks/) to
   `~/.claude/hooks/` and `chmod +x` them.
3. Register both hooks in your Claude Code `settings.json` as shown above.
4. Start a fresh session. On the first turn, confirm the agent reads the doctrine. On
   later turns, confirm the reminder and the pre-response check appear.

Keep the per-turn reminder small and the doctrine complete. The reminder is the trigger;
the doctrine is the substance. If they ever disagree, treat the reminder as canonical for
the *rule* and the doctrine as the authoritative interpretation of what the rule means -
and if there is a real conflict, that conflict is itself a defect worth fixing.

---

> **No warranty.** This document and the example files are provided as is, without warranty
> of any kind. They describe a behavioural pattern, not a security boundary. Running an AI
> agent with auto-approved tool calls carries real risk regardless of any doctrine; you
> accept all of it. See the [security section](ARCHITECTURE.md#7-security-this-is-the-part-to-read-twice)
> of the architecture document and the repository [README](../README.md#disclaimer--no-warranty).
