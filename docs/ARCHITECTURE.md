# vigil: architecture of an autonomous AI operations assistant

This document describes the architecture of an always-on AI assistant: a persistent
"operator" that lives in a container, talks to its owner over normal chat channels
(WhatsApp, Signal, email), and can autonomously develop software, install what it needs,
run scheduled tasks, and host services.

It is written so that any developer (or a coding assistant like Claude Code) can recreate
an equivalent from scratch. It explains the **what** and the **why**, not just file names,
so you can adapt it to a different stack.

> **What is verified vs. described.** The autonomous-diligence layer (doctrine + hooks,
> see [AUTONOMOUS-DILIGENCE.md](AUTONOMOUS-DILIGENCE.md)) is documented from a working,
> verified setup; the example files in this repo are real, redacted copies. The broader
> operator architecture below (persistent CLI subprocess, supervisor, transport split,
> channel multiplexers, MCP tool fleet) is presented as a **reference architecture**: a
> design that is known to work in this shape, described so you can build your own. Where
> something is a recommendation rather than a verified fact, it is marked as such. Verify
> every flag, path, and API against current upstream docs before you rely on it - which is
> itself rule one of the diligence layer.

The reference implementation is Node.js plus a coding-agent CLI, running in Docker. You can
swap languages; the architecture is the important part.

---

## 1. What you are building

A persistent operator AI that:

- Is reachable through normal chat channels (WhatsApp as the main one), plus email and Signal.
- Replies conversationally, but can also **do** things: write and run code, install
  packages, manage files, call external APIs, schedule reminders, send messages on its own.
- Stays alive 24/7 and survives crashes, restarts, and its own context filling up.
- Has persistent memory and a task scheduler, so it can act proactively (morning briefings,
  reminders, monitoring) without a human poking it.
- Can host the software it builds (a static web host container sits next to it).
- **Holds itself to an engineering doctrine on every turn** so that acting without a
  human in the loop does not mean acting carelessly. This is the diligence layer, and it
  is what makes the autonomy tolerable. See
  [AUTONOMOUS-DILIGENCE.md](AUTONOMOUS-DILIGENCE.md) - read it first; it is the load-bearing
  idea, not an add-on.

The core trick is simple to state and fiddly to get right: **run the coding-agent CLI as a
long-lived subprocess, pipe messages in and responses out as JSON, and wrap that in a
supervisor that handles persistence, health, and scheduling.** Everything else is plumbing
around that idea, plus the doctrine layer that keeps the plumbing honest.

---

## 2. High-level architecture

```
                         +---------------------------------------------+
                         |  Docker host (one box, or a VPS)            |
                         |                                             |
   WhatsApp phone  <===> |  +-----------------------+                  |
                         |  | WhatsApp multiplexer  |  (its OWN        |
                         |  | container             |   container,     |
                         |  | - WA Web library      |   because the    |
                         |  | - holds the WA session|   WA session is  |
                         |  | - HTTP API + webhook  |   stateful/fragile)
                         |  +----------+------------+                  |
                         |             | HTTP (send) + webhook (recv)  |
                         |             v                               |
                         |  +---------------------------------------+  |
                         |  | MAIN container                        |  |
                         |  |                                       |  |
                         |  |  supervisor  --- IPC ---  server      |  |
                         |  |  (autonomy)              (transport)  |  |
                         |  |       |                      |        |  |
                         |  |       v                      v        |  |
                         |  |  agent CLI            HTTP/WS :8080,   |  |
                         |  |  (persistent          IMAP/SMTP,      |  |
                         |  |   subprocess)         Signal          |  |
                         |  |       |                               |  |
                         |  |       v (stdin/stdout stream-json)    |  |
                         |  |   MCP tool servers (email, calendar,  |  |
                         |  |   git host, memory, image gen, ...)   |  |
                         |  +---------------------------------------+  |
                         |                                             |
                         |  +-------------------+                      |
                         |  | webhost container |  (nginx serving a    |
                         |  | (nginx static)    |   shared folder -    |
                         |  +-------------------+   AI drops sites here)|
                         +---------------------------------------------+
```

Two design choices drive everything:

1. **Split transport from brain.** The `server` process owns all the I/O (HTTP, WebSocket,
   email, the WhatsApp HTTP link, Signal). The `supervisor` process owns the AI and the
   autonomy. They talk over a local IPC socket. This means the chat-facing process can
   restart without killing the AI's session, and the AI can be busy for minutes without
   blocking incoming messages (they queue).

2. **Give the AI a real computer, not an API.** Because the AI is a coding-agent CLI
   running with shell and file access inside the container, it can install packages, write
   files, run builds, start servers - the same things a developer does. The capabilities
   are not a fixed list of functions; they are "a Linux box with tools."

---

## 3. The pieces, in detail

### 3.1 The agent wrapper (the heart of it)

Run the coding-agent CLI as a persistent child process in a streaming JSON mode. You write
user messages to its stdin as JSON lines, and read assistant output (token deltas, tool
calls, final result) from its stdout as JSON lines.

The reference uses the Claude CLI. The relevant flags are documented at
[Claude Code CLI reference](https://docs.claude.com/en/docs/claude-code/cli-reference) -
**check that page for current flag names rather than trusting this list**, since a CLI's
interface evolves:

- a print / non-interactive mode (so it does not open a TUI),
- a streaming JSON input format and a streaming JSON output format (machine I/O both ways),
- partial-message streaming (so you get token deltas, not just the final block),
- a permission mode that does not prompt for each tool call - this is what lets the AI act
  without a human approving every step, and is **only** acceptable inside a sandboxed
  container you control (see the security section),
- a session id on first launch, and resume-by-id afterwards, so the conversation survives
  process restarts,
- optionally a model selector and a disallowed-tools list.

**Wrapper responsibilities** (reference: a `AgentProcess`-style class, on the order of a
few hundred lines):

- Spawn the process, parse the JSON stream into events (system, message-start,
  content-block-delta, result, and so on).
- `send(text)` writes a user message to stdin and returns a promise that resolves on the
  result event with the final text.
- Support image content blocks (multimodal) by sending content arrays, not just text.
- Track state: starting / idle / busy / dead. Reject sends while busy.
- Persist the session id to a file; on boot, resume it. Detect a stale session after a
  redeploy ("no conversation found") and transparently start a fresh one.
- Auto-restart on crash with backoff. On a fatal signal (corrupted session), clear the
  session and start clean.

Two modes are worth supporting:

- **Persistent mode** - one long-lived process, used for the always-on supervisor brain.
- **Per-invocation mode** - spawn the CLI per message and resume the session. Simpler, more
  robust to leaks, slightly slower. Good for the request/response API path.

### 3.2 The supervisor (autonomy engine)

The supervisor is a long-running process that:

- Owns the persistent agent subprocess (the brain).
- Runs an **IPC server** (a local unix socket). The transport process connects to it,
  forwards incoming messages, and receives the AI's responses to relay back to the user.
- Maintains a **message queue with batching**: if several messages arrive while the AI is
  busy, they queue and get merged into one turn instead of spawning parallel work. This
  matters for cost and coherence.
- **Context seeding on session start.** When a fresh session begins (first boot, or after a
  rotation), it injects a seed: a compacted summary of the prior conversation, the last N
  messages, and a memory digest. So the AI wakes up with continuity instead of amnesia.
- **Session compaction.** Every N messages, it asks the AI to summarize the conversation so
  far and stores that summary. When context grows large, it rotates to a fresh session
  seeded with the summary. This is how it runs indefinitely without context overflow.
- **Task scheduler.** A list of scheduled tasks (one-off and recurring, with timezones).
  When one is due, it injects a `[SCHEDULED TASK]` message into the AI's queue. Tasks are
  stored as data; firing them is deterministic code, not an AI call. The AI only runs when
  the task actually fires.
- **Proactive check-ins.** A periodic trigger that tells the AI "review your memory/tasks
  and send a status update if anything is noteworthy."
- **Health monitor.** Pings the transport process every couple of minutes; if it is down or
  wedged, restarts it (with a suppress-file mechanism so manual restarts do not race the
  monitor).
- **Self-restart hook.** The AI can request its own clean restart by writing a file; the
  supervisor watches for it and does a graceful session rotation. The AI must **never** kill
  its own process directly (death-loop protection).
- **Fallback engine (optional).** If the primary agent hits a rate limit or a transient API
  error, it can fail over to a second agent CLI for the same message, then probe
  periodically to switch back.

Keep the supervisor itself alive with an external watchdog: a cron job every minute that
restarts it if the process is gone. Layered liveness: cron -> supervisor -> server.

### 3.3 The transport server

The transport process is the I/O layer:

- HTTP plus WebSocket API (the reference listens on `:8080`, WS path `/ws`).
- Receives WhatsApp messages (via the multiplexer webhook), email (IMAP), Signal.
- Forwards each inbound message to the supervisor over IPC, tagged with its source
  (`[WhatsApp from X]`, `[Email from X] Subject: ...`, and so on). The AI uses that tag to
  decide tone and routing.
- Takes the AI's response and sends it back out the same channel ("auto-relay"). The AI does
  **not** call a send tool to answer a direct message; the response text is relayed for it.
  The AI only calls send tools for **proactive** messages (alerts, scheduled output) where
  there is no inbound message to reply to. Getting this rule right avoids duplicate messages.
- Wrap long-running child processes (browser automation, etc.) with a subreaper such as
  `tini` so zombies get cleaned up.

### 3.4 The WhatsApp multiplexer (separate container)

WhatsApp has no official API for this use case, so the reference drives a headless WhatsApp
Web session via a community library. That session is stateful and fragile: it holds auth,
can drop, and needs a QR scan to (re)link. So it gets its **own container**, isolated from
the main app, exposing a tiny HTTP surface:

- `GET /status` -> `{ ready, status, qrDataUrl }` (main app polls this every ~15s),
- `POST /send`, `/send-image`, `/send-file`, `/send-voice`,
- a **webhook**: when a message arrives, the multiplexer POSTs it to the main app, which
  pre-downloads any media and hands it to the AI.

The benefit of isolating it: you can restart, redeploy, or crash the brain without losing
the WhatsApp login, and vice versa. Email and Signal are less fragile, so they live in the
main container directly (IMAP/SMTP libraries for email, `signal-cli` for Signal).

### 3.5 MCP tools (giving the AI capabilities)

Beyond shell and files, the AI gets structured tools via MCP (the Model Context Protocol).
You write small MCP server processes that expose typed tools, and register them in an MCP
config that the agent CLI auto-discovers:

```json
{
  "mcpServers": {
    "tools":  { "command": "node", "args": ["/path/mcp-tools.js"] },
    "memory": { "command": "node", "args": ["/path/mcp-memory.js", "/path/data"] },
    "calendar": { "command": "node", "args": ["/path/mcp-calendar.js"] }
  }
}
```

The reference fields on the order of a couple dozen MCP servers (email, chat-send, memory
and tasks, calendar and drive, a git host, image generation, finance data, a knowledge
base, etc.). The pattern: one server per capability domain, each a thin wrapper over an API
or a local function. Two rules matter:

- **Prefer deterministic code over AI calls.** A health check, a dedup, a status summary
  with fixed structure - write it as code, do not spend an AI turn on it. AI tokens are a
  budget; spend them on judgment, not on things a function can do.
- **Memory and tasks are themselves MCP tools**, backed by encrypted files, so they persist
  across restarts and are the AI's continuity.

For details on writing MCP servers, see the
[Model Context Protocol docs](https://modelcontextprotocol.io/).

### 3.6 Secrets and data

- Keep all credentials in one encrypted store (the reference uses AES-256-GCM with a master
  keyfile that is never committed). A small `secrets.get/set/keys` module. Nothing sensitive
  in env vars or in code.
- Keep persistent state (memory, tasks, chat history, contacts, auth tokens) in encrypted
  files in a `runtime/` directory that is gitignored. Treat these as irreplaceable; back up
  the keyfile out of band.

### 3.7 Provisioning / bootstrap

A single `bootstrap.sh` makes the container self-provisioning and idempotent (safe to
re-run). It:

- Checks prerequisites (a recent Node, npm, git).
- Installs the agent CLI if missing.
- Installs system deps the tools need (ffmpeg, etc.), a subreaper (`tini`), optional
  speech-to-text / text-to-speech binaries.
- Runs `npm install`, and `git init` for the code and workspace directories.
- Installs cron jobs (the supervisor watchdog, plus small maintenance jobs).
- Starts the supervisor and the server, each under the subreaper.

One subtlety: a self-updating agent CLI can replace a permission wrapper on update. A tiny
cron job re-applies the wrapper (and re-points a symlink at the latest version) every few
minutes so the desired permission mode is always present. Only relevant if you wrap the CLI
to enforce a permission mode.

---

## 4. Autonomy: how it actually works end to end

**Inbound:** WhatsApp -> multiplexer -> webhook -> server -> IPC -> supervisor queue ->
agent subprocess -> response -> IPC -> server -> WhatsApp reply. Same path for email and
Signal, different transport.

**Proactive:** cron keeps the supervisor alive; the supervisor's scheduler fires due tasks
and periodic check-ins by injecting messages into the same queue. The AI handles them like
any other turn, and uses send tools (not auto-relay) to push the result to the user.

**Continuity:** persistent session + session id on disk + periodic compaction + memory MCP.
When the session rotates, the new one is seeded with the summary, recent messages, and
memory, so the AI keeps its thread and its sense of self.

**Resilience:** per-process auto-restart in the wrapper; supervisor restarts the server;
cron restarts the supervisor; rate-limit/transient failover to a second engine; stale and
corrupted sessions are detected and reset; a suppress-file prevents the health monitor from
racing manual restarts.

**Diligence (the part that makes all of the above safe to leave running):** the doctrine +
hooks layer re-asserts the engineering standard on every turn, so an auto-approved agent
keeps verifying before it acts, refuses workarounds, and does not claim "done" without a
real run - with no human present. See [AUTONOMOUS-DILIGENCE.md](AUTONOMOUS-DILIGENCE.md).

---

## 5. Minimal build order (suggested)

1. **Wrapper first.** Get a class that spawns the agent CLI in streaming-JSON mode, sends a
   message, and returns the text. Prove streaming and resume work. Everything depends on
   this.
2. **One channel.** Wire up the simplest channel end to end. Email (IMAP in, SMTP out) is
   easiest because it has real APIs and no session fragility. Get "email in -> AI -> email
   out" working.
3. **Supervisor + IPC.** Split the brain into a supervisor process; have the channel layer
   forward over IPC. Add the message queue and the source tags.
4. **The diligence layer.** Add `doctrine.md` and the two hooks now, before you give the AI
   write access to anything that matters. Do not bolt safety on at the end. See
   [AUTONOMOUS-DILIGENCE.md](AUTONOMOUS-DILIGENCE.md).
5. **Persistence.** Add memory and tasks as MCP servers backed by encrypted files. Add
   session-id persistence and a basic compaction/seed on restart.
6. **Scheduler + health.** Add the task scheduler, proactive check-in, and the
   cron -> supervisor -> server liveness chain.
7. **WhatsApp last.** Stand up the multiplexer in its own container. It is the most finicky
   piece; do it once the rest is solid.
8. **More tools as needed.** Add MCP servers per capability. Keep deterministic work in code.
9. **A place to host output.** An nginx container serving a shared folder lets the AI publish
   what it builds.

---

## 6. Hard-won gotchas (do not relearn these)

- **Do not block the queue.** A single long AI turn must not stall incoming messages; queue
  and batch them. Heavy work should be backgrounded.
- **Auto-relay vs explicit send.** Reply-to-inbound = relay the response text automatically;
  proactive output = explicit send tool. Mixing them up causes duplicate messages.
- **Never let the AI kill its own process.** Use a file-trigger that an external watchdog
  acts on. Direct self-kill plus an aggressive restarter = death loop.
- **Sessions go stale after redeploy.** Detect "no conversation found" and start fresh
  instead of looping on resume.
- **Isolate the fragile session (WhatsApp) in its own container.** Losing the brain should
  not mean rescanning a QR code.
- **Encrypt and never commit runtime state.** Auth tokens, memory, chat history are
  irreplaceable. gitignore `runtime/`, back up the keyfile out of band.
- **Watch disk and zombies.** Browser automation and core dumps fill disks; set
  `ulimit -c 0`, use a subreaper (`tini`), and run a periodic reaper cron job.
- **Token budget is real.** Route anything mechanical through code, not the model.

---

## 7. Security (this is the part to read twice)

This design runs an AI with full shell access and auto-approved tool calls. That is only
acceptable because it is confined to a container that the owner controls and trusts, acting
on the owner's own accounts and data. Before replicating:

- **Run it in an isolated container/VM**, not on a machine with anything you cannot lose.
- **Scope every credential to exactly what is needed.** Assume the AI can use any secret it
  can read.
- **The auto-approve permission flag means there is no human in the loop per action.** Add
  your own guardrails. The reference bakes rules into the doctrine: never mass-delete, never
  force-push, never take destructive/irreversible actions without explicit human
  confirmation, always ask when in doubt. Those rules are load-bearing - this is the
  diligence layer in [AUTONOMOUS-DILIGENCE.md](AUTONOMOUS-DILIGENCE.md). They are a
  behavioural guardrail, **not** a substitute for real containment. Use both.
- **Keep personal/private data segregated and off-limits** to the operator AI.
- **Auto-approved permissions and a behavioural doctrine are different layers.** The
  permission mode controls what the agent *can* do; the doctrine shapes what it *chooses* to
  do. A doctrine does not stop a sufficiently confused or adversarially-prompted agent from
  taking a bad action. Treat the container boundary and credential scoping as your real
  security, and the doctrine as defence in depth on top of it.

---

## 8. Reference stack (what a working system uses)

- Container: Docker (a recent `node` base), managed via a container UI such as Portainer.
- Language/runtime: Node.js.
- AI: a coding-agent CLI run as a persistent streaming-JSON subprocess (the reference uses
  the Claude CLI), optionally with a second agent CLI as a rate-limit fallback.
- Messaging: a WhatsApp Web library in its own container, IMAP/SMTP libraries for email,
  `signal-cli` for Signal.
- Tooling: MCP servers (one per capability) built on the MCP SDK.
- Voice (optional): a local speech-to-text engine (e.g. whisper.cpp) and a text-to-speech
  engine.
- Hosting: an nginx container serving a shared "publish" folder.
- Process hygiene: a subreaper (`tini`) and cron (watchdog + maintenance).

---

That is the whole system. Build the wrapper, prove one channel, add the diligence layer
before you grant real write access, then grow outward. The architecture - transport split
from brain, persistent resumable session, supervisor for autonomy, isolated fragile
sessions, capabilities as MCP tools, deterministic code over AI calls, and a per-turn
doctrine that keeps an auto-approved agent honest - is what makes it reliable. The rest is
plumbing you can adapt to any stack.

> **No warranty.** This is a reference architecture provided as is, without warranty of any
> kind. It describes a system that runs an AI agent with auto-approved tool calls and broad
> system access; building or running such a system carries significant risk, and you accept
> all of it. See the [README disclaimer](../README.md#disclaimer--no-warranty).
