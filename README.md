# vigil

**How to build an always-on, autonomous AI operations assistant - and how to make it
diligent enough to leave running unattended.**

`vigil` is a documentation project. It describes, in enough depth to recreate from scratch,
the architecture of a persistent "operator" AI: one that lives in a container, talks to its
owner over normal chat channels (WhatsApp, Signal, email), and can autonomously write and
run code, install packages, schedule tasks, and host the things it builds.

The part most write-ups skip - and the part `vigil` puts front and centre - is **how an
agent that acts without a human approving each step stays honest.** That is the
**autonomous-diligence pattern**: a doctrine file plus two Claude Code hooks that re-assert
an engineering standard on every single turn, at near-zero cost, with no human present.

There is no daemon to install here and no `.deb` to ship. This repo is the spec and the
example files. Read it, adapt it, build your own.

## What's inside

| Document | What it covers |
|---|---|
| **[docs/AUTONOMOUS-DILIGENCE.md](docs/AUTONOMOUS-DILIGENCE.md)** | The doctrine + hooks pattern that makes autonomy safe to leave running. **Start here.** |
| **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** | The full operator architecture: persistent agent subprocess, supervisor, transport split, channel multiplexers, voice/media (free local speech-to-text), encrypted searchable email DB, cost monitoring + dashboard, MCP tools, persistence, scheduling, resilience. Ends with a concrete **[implementation plan](docs/ARCHITECTURE.md#9-implementation-plan-prerequisites-and-a-path-to-running)** (prerequisites and bring-up order). |
| **[examples/](examples/)** | Drop-in starting points: a generic `doctrine.md`, the two hook scripts, and a `settings.json` fragment. |

### Before you build the WhatsApp channel, read this

Linking a headless WhatsApp Web session hands the running agent full read and send access to
that account. **Use a dedicated phone number you provision for the assistant, never your
personal WhatsApp.** WhatsApp does not sanction unofficial automation and can ban the
account; a dedicated number means a ban costs you the assistant, not your personal messaging.
The multiplexer enforces *who the agent may talk to* in code, both directions: an
**allowlist** drops inbound messages from anyone not explicitly permitted (so strangers
cannot even prompt the agent), and an **outreach-thread** rule stops the agent cold-messaging
arbitrary or model-invented numbers. Both gates and the QR-linking page are detailed in the
[architecture doc](docs/ARCHITECTURE.md#34-the-whatsapp-multiplexer-separate-container).

## The idea in one paragraph

Run a coding-agent CLI (the reference uses the Claude CLI) as a long-lived subprocess in a
container, piping messages in and responses out as JSON. Wrap it in a **supervisor** that
handles persistence, health, scheduling, and session rotation, and split all the I/O into a
separate **transport** process so the chat layer can restart without killing the brain.
Give the AI a real Linux box with tools rather than a fixed API, and expose extra
capabilities as small MCP servers. Then - and this is the load-bearing part - hold the agent
to an **operating doctrine** it reads at session start, kept fresh by a minimal per-turn
`UserPromptSubmit` reminder that points back at it, so an auto-approved agent keeps verifying
before it acts, refuses workarounds, and never claims "done" without a real run. The
architecture makes it reliable; the doctrine makes it diligent.

## The autonomous-diligence pattern, in brief

Three pieces, a few kilobytes total:

1. **`doctrine.md`** - the full operating rules, written once (verify before acting, no
   workarounds, respect specs, don't claim completion you haven't verified, push back when
   the request is wrong, minimise blast radius, when unsure ask or stop).
2. **A `SessionStart` hook** - fires once per session, tells the agent to read the doctrine
   in full. Cost: a few hundred characters once.
3. **A `UserPromptSubmit` hook** - fires on *every* turn, re-states the non-negotiables and
   asks the agent to print a **pre-response check** before any consequential reply. Cost:
   ~1.5 KB per turn, negligible.

Why on every turn? Because over a long autonomous run, rules buried in a one-time system
prompt drift, and the dangerous moments are individual actions. Re-asserting the discipline
right before the agent acts - deterministically, with no model call - is what keeps a
capable, auto-approved agent reasoning like a diligent engineer instead of an eager one.

Full write-up, including why a system prompt is not enough and how to adapt it:
**[docs/AUTONOMOUS-DILIGENCE.md](docs/AUTONOMOUS-DILIGENCE.md)**.

## What is verified vs. described

- The **diligence layer** (doctrine + hooks) is documented from a working, verified setup;
  the files in [`examples/`](examples/) are real, redacted copies that emit valid hook JSON.
- The **operator architecture** in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is presented
  as a **reference architecture**: a design known to work in this shape, written so you can
  build your own. Verify every flag, path, and API against current upstream docs before you
  rely on it.

## Who this is for

Developers building their own always-on assistant, or anyone curious how such a system is
put together and kept from going off the rails. It assumes comfort with containers, a shell,
and a coding-agent CLI.

## Disclaimer / no warranty

This repository is **documentation and example configuration**, provided **as is, without
warranty of any kind**, express or implied, including but not limited to merchantability,
fitness for a particular purpose, and noninfringement.

It describes how to build a system that runs an AI agent with **auto-approved tool calls**
and **broad shell, file, and network access**. Building or running such a system is
inherently risky. By using anything in this repository you accept that:

- **You alone are responsible** for anything an autonomous agent you build does, including
  destructive, irreversible, or costly actions - up to and including data loss, leaked
  credentials, unintended spending, and damage to systems you do not own.
- The doctrine and hooks described here are a **behavioural guardrail, not a security
  boundary.** They reduce careless mistakes; they do **not** sandbox the agent or prevent a
  confused or adversarially-prompted agent from taking a bad action. Real containment is the
  container/VM boundary and tightly scoped credentials - use those, and treat the doctrine
  as defence in depth on top.
- The author(s) and contributors are **not liable** for any harm, loss, or damages, however
  caused, arising from following this documentation or running anything built from it.
- Auto-approved permission modes remove the human from the loop on every action. Only run
  such a configuration inside an isolated environment you fully control and can afford to
  lose, on accounts and data you own.

Read [docs/ARCHITECTURE.md, section 7 (Security)](docs/ARCHITECTURE.md#7-security-this-is-the-part-to-read-twice)
before building anything. If you do not accept these terms, do not use this repository.

## License

MIT. See [LICENSE](LICENSE).

## Author

[Ramazan Yavuz](https://ra-yavuz.github.io/). Part of the public, open-source projects at
[github.com/ra-yavuz](https://github.com/ra-yavuz), independent of any business work.
