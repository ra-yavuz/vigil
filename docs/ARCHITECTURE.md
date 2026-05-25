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

The core trick is simple to state and fiddly to get right: **drive the coding-agent CLI as a
subprocess with a resumable session, pipe messages in and responses out as JSON, and wrap
that in a supervisor that handles persistence, health, and scheduling.** The subprocess can
be held open across messages or respawned per message with `--resume` (the reference does the
latter for the always-on brain; see section 3.1) - what persists is the session, not
necessarily the process. Everything else is plumbing
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
                         |  |  (per-message         IMAP/SMTP,      |  |
                         |  |   --resume)           Signal          |  |
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

Drive the coding-agent CLI as a child process in a streaming JSON mode (held open across
messages, or respawned per message with `--resume` - see the two modes below). You write
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

Two modes are worth supporting, and the choice matters:

- **Per-invocation mode** - spawn a fresh `claude -p --resume <session-id>` per message and
  let it exit when the turn is done. Continuity comes from `--resume` (the session lives on
  disk), not from keeping the process alive. Simpler, and far more robust to memory leaks and
  wedged processes, at the cost of a little startup latency per message. **This is what the
  reference uses for the always-on brain** - the autonomy engine constructs its agent with
  persistent mode turned off, and gives each invocation a generous activity-based timeout
  (15 minutes of silence, reset on any output) so long tool-running turns are not cut off.
- **Persistent mode** - one long-lived process held open across messages, fed via
  streaming-JSON stdin/stdout. Lower per-message latency and live token streaming, but you own
  the process's whole lifecycle: leaks, hangs, and outright crashes are all yours to detect
  and recover from. The wrapper keeps this as its default and the reference uses it only on the
  synchronous request/response API path, where a human caller is waiting on a single response.

> **Learning, stated as such: prefer per-invocation for the always-on brain.** In the
> reference deployment the long-lived persistent process proved unreliable for a 24/7 brain -
> over long uptimes it accumulated crashes and wedged states - which is why the autonomy engine
> was moved to spawning a fresh process per message with `--resume`. Two caveats on how firmly
> to take this. First, it is **operator experience, not something you can read off the code**:
> the repository shows *that* the brain runs per-invocation (the supervisor sets persistent
> mode off), but the commit history is squashed, so it does not document *why*. Second, the
> behaviour you hit will depend on your agent CLI, its version, and your load; treat "persistent
> mode is fragile over long uptimes" as a reason to default to per-invocation and to test
> persistent mode hard before trusting it, not as a universal law. What the code *does*
> corroborate: a `claude -p` invocation can still die mid-turn (a `SIGABRT`/`SIGSEGV` usually
> means a corrupted or locked session), so the wrapper detects that signal, clears the session,
> and lets the next message start clean rather than looping on a broken one. Build that recovery
> regardless of which mode you choose.

The mental-model correction that follows: "persistent" properly describes the **session and
state** (resumable session id, memory, chat history on disk), not necessarily a **long-lived
OS process**. The brain can be, and in the reference is, a process that comes and goes per
message while the *conversation* persists underneath it via `--resume`.

### 3.2 The supervisor (autonomy engine)

The supervisor is a long-running process that:

- Owns the agent subprocess (the brain) and its resumable session. In the reference this is
  per-invocation: a fresh `claude -p --resume` per message, with continuity carried by the
  session id on disk rather than a process that stays up.
- Runs an **IPC server** (a local unix socket). The transport process connects to it,
  forwards incoming messages, and receives the AI's responses to relay back to the user.
- Maintains a **message queue with batching**: if several messages arrive while the AI is
  busy, they queue and get merged into one turn instead of spawning parallel work. This
  matters for cost and coherence.
- **Context seeding on session start.** When a fresh session begins (first boot, or after a
  rotation), it injects a seed: a compacted summary of the prior conversation, the last N
  messages, and a memory digest. So the AI wakes up with continuity instead of amnesia.
- **Session compaction.** Every N messages (the reference compacts roughly every 50), it
  asks a model to summarize the conversation so far and stores that summary. Worth noting:
  the reference runs the summarization on the **cheaper fallback engine**, not the primary
  one, since compaction is mechanical and does not need the strongest model. When context
  grows large it rotates to a fresh session seeded with the summary (the reference also
  rotates daily, around 04:00 local time). This is how it runs indefinitely without context
  overflow.
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

#### Linking the session: a QR page you scan with your phone

A headless WhatsApp Web session links to a phone the same way the desktop app does: by
scanning a QR code. The multiplexer surfaces that QR over HTTP so you can link it from a
browser instead of needing to read a terminal:

- The WhatsApp Web library emits a `qr` event whenever it needs (re)linking. The multiplexer
  renders that string two ways: as ASCII in its own logs, and as a 256px PNG data URL it
  keeps in memory (`qrDataUrl`).
- `GET /status` returns `{ ready, status, qrDataUrl }`. `GET /` serves a tiny self-contained
  HTML page that polls `/status` every couple of seconds and draws the QR image; once the
  session reports `ready`, the page clears the QR. So linking is: open the multiplexer's URL,
  scan the code with the phone's WhatsApp ("Linked devices"), done. On a drop, the QR
  reappears on the same page and you rescan.
- That page exposes the ability to link *your* WhatsApp number, so it must sit behind your
  authentication / VPN, never on the open internet. Treat it like a login screen.

> **Use a dedicated phone number, not your personal one.** Linking WhatsApp Web hands the
> linked session full read/send access to that account's chats. An always-on agent driving
> it can, in principle, read your message history and send as you. Run it on a **separate
> number you provision for the assistant** (a spare SIM or a second account), not your
> primary personal WhatsApp. This also keeps WhatsApp's automated-use risk (see below) off
> your main number: WhatsApp's terms do not sanction unofficial automation, and an account
> can be banned for it. A dedicated number means a ban costs you the assistant, not your
> personal messaging.

#### Strict rules on who can be contacted

Because the agent can send messages on its own, "who is it allowed to talk to" is a security
boundary, and the multiplexer enforces it in code, both directions:

- **Inbound: an allowlist gate.** The multiplexer keeps an allowlist of phone numbers (a
  small class backed by a JSON file, hot-reloaded when the file changes). On the personal
  route, any inbound message whose sender is not on the enabled allowlist is **dropped before
  it is ever forwarded to the brain** (`if (!route && !whitelist.isAllowed(sender)) return`).
  The AI never sees messages from strangers, so it cannot be prompt-injected by a random
  inbound text. The allowlist is managed over a small authenticated API (add / remove /
  enable / disable), so you curate exactly who can reach the assistant.
- **Outbound: no cold-contacting arbitrary numbers.** The agent cannot freely message any
  number it likes. To initiate contact, an **outreach thread** must exist for that number:
  each thread is scoped to a single phone with a stated, verified reason and a finite
  time-to-live (the reference expires threads after 72 hours), and outbound sends are routed
  through that thread's endpoint. The policy attached to every such thread states plainly that
  messaging unverified or model-invented ("hallucinated") numbers is prohibited. The effect:
  the assistant can reply within established, consented conversations and cannot spray
  messages at numbers it guessed or scraped.

Both gates are deterministic code in the multiplexer, not instructions in the system prompt,
so they hold even if the model is confused or adversarially prompted. This is the same
"deterministic guardrail beats a behavioural rule" principle as the destructive-command
detector (section 7).

#### Voice messages: speech-to-text on the way in

People send voice notes, not just text. The reference handles an inbound WhatsApp voice
message like this, and the same path serves audio from any channel:

1. **Download the media** from the message and write the raw bytes to a temp file. WhatsApp
   voice notes arrive as OGG/Opus.
2. **Transcode to the format the recognizer wants** with `ffmpeg`: 16 kHz mono WAV. This one
   conversion step is what lets a single local recognizer accept audio from every channel.
3. **Transcribe locally** with a self-hosted engine (the reference builds `whisper.cpp` from
   source during bootstrap and runs `whisper-cli` with `-otxt` and automatic language
   detection). It returns the text plus the detected language code.
4. **Hand the text to the AI** as if the user had typed it, and remember the detected
   language so a reply can be spoken back in the same one.
5. **Clean up the temp files** in a `finally` block, win or lose, so the disk does not fill.

**Speech-to-text here is free.** The recognizer is a local model running on the box
(`whisper.cpp`), so there is no per-minute API charge and no usage cap, however many voice
notes arrive. That matters for an always-on assistant: it transcribes a lot of audio, and a
metered cloud API would turn a steady stream of voice notes into a steady bill. Keeping it
local also keeps the audio on hardware you control, which is the right default for private
voice messages. The only cost is the one-time CPU to build `whisper.cpp` at bootstrap and
the compute to run it, which on a modest box is negligible for short voice notes. (The
text-to-speech side, `edge-tts`, is likewise free to call.)

#### Voice replies: text-to-speech on the way out

For a spoken reply, the reverse path: take the AI's text, synthesize speech with a TTS
engine (the reference uses `edge-tts`, choosing a voice by the detected language), and send
the resulting audio back as a voice note. Keep a low-quality offline fallback (e.g.
`espeak-ng`) so the assistant can still answer if the better engine is unavailable.

#### Images and attachments

Inbound images and documents follow a parallel path: **download the media**, map the
mimetype to a known type and extension, **save a temp copy**, and produce a base64 copy. The
image is then handed to the AI as a **multimodal content block** (a content array, not a
plain string) together with any caption, so the model actually sees the picture rather than
a filename. PDFs and other documents are routed to the relevant tool (OCR, a PDF parser, an
invoice parser) before their extracted text reaches the AI. Same temp-file hygiene applies.

This is why the wrapper in section 3.1 must support content arrays, not just text: the media
handlers depend on it.

#### Email, and email as the fallback channel

Email lives in the main container because it has real, stable APIs and no session fragility.
Inbound uses an IMAP client (the reference uses `imapflow`) in **IDLE mode with a polling
fallback**: IDLE delivers new mail near-instantly, and a periodic poll catches anything IDLE
misses after a reconnect. Messages are parsed (subject, body, attachments) and attachments
are saved to a temp directory, then the body and any extracted attachment text are handed to
the AI tagged with the source. Outbound uses an SMTP library (the reference uses
`nodemailer`). The design supports **multiple accounts** behind aliases, so the assistant can
read and send from more than one mailbox.

Email is also the **last-resort fallback channel**. The system prefers the fastest channel
the owner actually watches (WhatsApp), falls back to Signal, and falls back to email if the
others are unavailable. The same ordering applies to proactive output: an alert tries the
preferred channel first and degrades to email rather than failing silently. Encode that
order as data, not as scattered conditionals, so it is easy to audit and change.

#### An encrypted, searchable email database

Reading "recent inbox" over IMAP every time is slow and rate-limited, and the AI often needs
to *search* mail ("what did X say about Y last month"), not just read the latest. So the
reference keeps a local **searchable email database**:

- **SQLite with full-text search** (FTS5). The AI queries it with ordinary SQL: folder
  counts, top senders, monthly volume, full-text lookups across years of mail, instantly,
  without touching the IMAP server.
- **Encrypted at rest** with AES-256-GCM, using the same master keyfile as the other
  encrypted stores. On startup the `.enc` file is decrypted to a temp SQLite file; the
  database is checkpointed back to the encrypted file periodically (the reference does so
  every ~30 minutes) and on a clean shutdown; the plaintext temp file is removed on exit.
- **Crypto off the main thread.** The encrypt/decrypt of the whole database file runs in a
  short-lived worker thread, so a checkpoint never stalls the event loop that is also serving
  chat. The worker and the main path share one on-disk format so the files are
  interchangeable.

The pattern generalizes: when the AI needs to search a corpus repeatedly, give it a local
indexed store rather than re-fetching from a slow remote each time, and encrypt the store at
rest because its contents are sensitive.

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

### 3.6 Cost monitoring and a dashboard

An always-on agent that calls a metered model API spends real money continuously, so you
want to *see* what it is spending, not discover it on a monthly bill. The reference makes
cost a first-class, observable quantity:

- **Capture per-turn cost at the source.** The agent CLI reports usage on the `result` event
  of every turn; the wrapper reads the reported `total_cost_usd` (with fallbacks to other
  cost fields) and records it alongside the response. Because the number comes from the CLI
  itself, it reflects actual billed usage rather than a guess from token counts.
- **Aggregate counters cheaply.** A small stats collector keeps running counters (messages
  handled, and so on) as plain in-process state. These are deterministic code, not model
  calls.
- **Expose it on a dashboard.** The transport server also serves a set of small web pages
  (plain HTML, no framework) over the same authenticated/VPN-only surface as the API: an
  operations view, per-capability views (email, finance, and so on), and a statistics view.
  The email dashboard, for example, runs ordinary SQL against the local email database
  (folder counts, top senders, monthly volume) and renders the results. A dashboard like this
  is how the owner audits behaviour and spend without reading logs by hand.

The general rule: anything you would want to check at a glance (spend, queue depth, channel
health, last check-in) should be a number the system records as it goes and a page you can
open, not something you reconstruct after the fact. And again, keep the gathering of those
numbers in deterministic code: do not spend an AI turn computing a status summary a function
can produce.

### 3.7 Secrets and data

- Keep all credentials in one encrypted store (the reference uses AES-256-GCM with a master
  keyfile that is never committed). A small `secrets.get/set/keys` module. Nothing sensitive
  in env vars or in code.
- Keep persistent state (memory, tasks, chat history, contacts, auth tokens) in encrypted
  files in a `runtime/` directory that is gitignored. Treat these as irreplaceable; back up
  the keyfile out of band.

### 3.8 Provisioning / bootstrap

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
   message, and returns the text. Prove streaming and resume work. Support both process modes
   but default the always-on path to per-invocation (`claude -p --resume`) for the stability
   reasons in section 3.1. Everything depends on this.
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
  your own guardrails. The reference uses three layers, from outside in:
  1. **Containment** - the container/VM boundary and tightly scoped credentials. This is the
     real security; everything below is defence in depth.
  2. **A deterministic destructive-command detector** - a small module that pattern-matches
     proposed shell commands against known-dangerous shapes (`rm -rf /`, `mkfs`, `dd` to a
     block device, force-push, `DROP DATABASE`, fork bombs, `chmod -R 777`, and so on) and
     classifies them by severity. It is plain code, not a model call, so it cannot itself be
     talked out of a refusal, and it writes to an audit log. Use it to block or escalate the
     high-severity shapes rather than relying on the model to never emit them.
  3. **A behavioural standard the agent holds itself to** - never mass-delete, never
     force-push, never take destructive/irreversible actions without explicit human
     confirmation, always ask when in doubt. The reference puts these rules where the agent
     reads them every session (an auto-loaded operating-instructions file, plus the
     [doctrine + hooks pattern](AUTONOMOUS-DILIGENCE.md) on the workstation that builds and
     supervises it). This layer is load-bearing but is the **softest** of the three: it
     shapes what a cooperative agent *chooses* to do; it does not *stop* a confused or
     adversarially-prompted one.
- **Keep personal/private data segregated and off-limits** to the operator AI.
- **The three layers are not interchangeable.** The permission mode and container control
  what the agent *can* do; the detector blocks specific dangerous *actions* deterministically;
  the behavioural standard shapes *choices*. A behavioural rule alone does not stop a bad
  action. Treat the container boundary and credential scoping as your real security, the
  detector as a hard stop on the worst shapes, and the operating rules as defence in depth on
  top of both.

---

## 8. Reference stack (what a working system uses)

- Container: Docker (a recent `node` base), managed via a container UI such as Portainer.
- Language/runtime: Node.js.
- AI: a coding-agent CLI driven over streaming JSON with a resumable session (the reference
  uses the Claude CLI, respawned per message with `--resume` for the always-on brain),
  optionally with a second agent CLI as a rate-limit fallback.
- Messaging: a WhatsApp Web library in its own container, IMAP/SMTP libraries for email,
  `signal-cli` for Signal.
- Tooling: MCP servers (one per capability) built on the MCP SDK.
- Voice: a local speech-to-text engine (the reference builds `whisper.cpp`) fed via `ffmpeg`
  (16 kHz mono WAV), and a text-to-speech engine (the reference uses `edge-tts`, with
  `espeak-ng` as an offline fallback).
- Email: `imapflow` (IMAP IDLE + poll) and `mailparser` inbound, `nodemailer` outbound,
  multi-account.
- Guardrails: a deterministic destructive-command detector plus an audit log, alongside the
  behavioural operating rules.
- Hosting: an nginx container serving a shared "publish" folder.
- Process hygiene: a subreaper (`tini`) and cron (watchdog + maintenance).

---

## 9. Implementation plan: prerequisites and a path to running

Section 5 gave the *build* order (write the code in the right sequence). This section is the
*deployment* checklist: what you need in place to actually run the system, in the order you
need it. It is opinionated and concrete so you can follow it, but every value (ports, paths,
image) is an example to adapt, not a law.

### 9.1 Prerequisites

Before any of the containers can come up, have these ready:

1. **A host you control and can leave running.** A small always-on Linux box or a VPS. It
   must tolerate the agent doing real work (installing packages, running builds), so give it
   adequate disk and a few GB of RAM. Do **not** use a machine holding anything you cannot
   afford to lose or to have read by the agent.
2. **Docker, and the host Docker socket available to the main container.** The reference runs
   everything as Docker containers and **bind-mounts the host's Docker socket**
   (`/var/run/docker.sock:/var/run/docker.sock`) into the main container. That is what lets
   the in-container agent manage its sibling containers (for example, restart the web host
   after publishing a site). Understand the trade-off before you do this: **mounting the
   Docker socket is effectively root on the host.** It is acceptable here only because the
   whole point is an agent with broad control on a box dedicated to it; on a shared or
   sensitive host, do not mount the socket, and accept that the agent then cannot manage
   sibling containers.
3. **A coding-agent CLI and its credentials.** The reference uses the Claude CLI (installed
   at bootstrap) with an account/key that has the budget you are willing to let an always-on
   agent spend. Optionally a second agent CLI for the rate-limit fallback.
4. **`whatsapp-web.js` (or equivalent), and a dedicated phone number for it.** The WhatsApp
   channel drives a headless WhatsApp Web session via `whatsapp-web.js`. **Provision a
   separate number for the assistant** (spare SIM or second account), never your personal
   one, for the reasons in section 3.4. You will scan a QR code from that phone to link it.
5. **A reachable, authenticated entry surface.** The transport API, the dashboards, and the
   WhatsApp QR page all expose control of the assistant and its accounts. Put them behind a
   VPN or real authentication. Nothing here belongs on the open internet.
6. **Accounts/credentials for the channels and tools you want**: an email account with IMAP
   and an app password (for the email channel), a Signal number registered to `signal-cli`
   (optional), and API credentials for whichever MCP tools you enable (calendar, a git host,
   image generation, and so on). Add these incrementally; you do not need them all to start.
7. **An encryption keyfile for state at rest**, generated once and stored out of band. The
   encrypted stores (secrets, memory, chat history, email DB) all derive from it. If you lose
   it, you lose that state; if it leaks, the state is exposed.

### 9.2 Bring-up order

1. **Provision the host and install Docker.** Confirm you can run a container and that
   `/var/run/docker.sock` exists. Decide, now, whether you are mounting the socket (see 9.1.2).
2. **Lay out the stack directory and the bind mounts.** The reference mounts, into the main
   container: the agent's home directory (so the session, `.claude`, and config persist
   across restarts), the control code, the agent's workspace, a shared publish folder for the
   web host, and the Docker socket. Persisting the home and workspace on the host is what lets
   you redeploy the code without the agent losing its memory or its session.
3. **Run `bootstrap.sh` to self-provision the main container.** It installs the agent CLI, a
   subreaper (`tini`), `ffmpeg`, builds the local speech-to-text engine, installs the
   text-to-speech and `signal-cli` dependencies, runs `npm install`, initialises the git/work
   directories, installs the watchdog cron jobs, and starts the supervisor and server. It is
   idempotent: safe to re-run.
4. **Prove the brain over the easiest channel first: email.** Get "email in -> agent ->
   email out" working before anything else. It has stable APIs and no session fragility, so it
   isolates problems in the wrapper/supervisor from problems in a flaky channel.
5. **Add the diligence layer before granting broad write access.** Put the operating rules
   where the agent reads them (an auto-loaded instructions file, plus the doctrine + hooks on
   the workstation that supervises it), and wire the deterministic destructive-command
   detector. Do this *before* the agent has real reach, not after.
6. **Stand up the WhatsApp multiplexer container last.** Run it as its **own** container with
   its own persisted auth volume, so restarting the brain never costs you the WhatsApp login.
   Then link it: open the multiplexer's QR page (behind your VPN), scan the code with the
   dedicated phone's WhatsApp "Linked devices", and wait for `/status` to report `ready`.
   Seed the **allowlist** with the only numbers allowed to reach the assistant, and confirm a
   message from a non-allowlisted number is dropped.
7. **Add MCP tools and the dashboard as you need them.** One capability at a time, each a thin
   MCP server. Bring up the cost/stats dashboard early so you can watch spend from day one.
8. **Add the web host container** (nginx serving the shared publish folder) so the agent has
   somewhere to publish what it builds.

### 9.3 Before you leave it running unattended

- Confirm the liveness chain works: kill the server and watch the supervisor restart it; kill
  the supervisor and watch cron restart it.
- Confirm the allowlist and outreach gates actually block (try an unknown inbound number; try
  to send to a number with no open thread).
- Confirm the encrypted stores survive a full restart (state comes back) and that the keyfile
  is backed up somewhere off the box.
- Confirm you can see spend on the dashboard, and set yourself a habit (or an alert) to check
  it. An always-on agent on a metered API spends while you sleep.

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
