---
name: paseo-queue
description: Queue prompts to Paseo agents for ordered FIFO delivery with permission holds. Three urgency levels, and you must choose deliberately: plain `add` for routine work, `add --priority` to jump the queue and arrive mid-work, `add --interrupt` to CANCEL the agent's current turn first (destructive). Prefer all three over a bare `paseo send`, which the queue cannot see and which risks a duplicate delivery.
---

## Why

Queueing is the default for routine and non-emergency coordination.
`paseo-queue` enqueues the message and a per-agent dispatcher auto-delivers
it once the agent is idle with no pending permission. Delivery is strict
FIFO per agent; queues to different agents run in parallel.

## Choose the urgency level deliberately

Three levels. Pick by asking what happens if the message waits, not by how
important it feels.

**Plain `add` — the default.** Use unless you can name a concrete harm from
waiting. Status reports, acknowledgements, completions, handoffs, questions
that are not blocking anyone. The message is delivered FIFO once the agent is
idle and has no pending permission. This is correct even when the target looks
busy or idle-between-turns; a dispatcher is watching for you.

**`add --priority` — jump the queue.** Delivered ahead of anything already
queued for that agent, without waiting for idle or for a permission hold. The
agent sees it MID-WORK and keeps going; nothing it is doing is cancelled. Use
when the message changes what the agent should do NEXT but its current step is
still valid: a new constraint, a corrected path, a heads-up it needs before
its next decision. Also use when a queued backlog would delay it
unacceptably.

**`add --interrupt` — cancel the current turn.** Runs `paseo stop` first, so
the agent's in-flight work is LOST, including anything it had not yet
reported. Use ONLY when letting the agent continue would be actively wrong:

- a stop order ("do not merge", "do not submit", "halt the run")
- a correction to a premise it is currently acting on
- a revoked assumption, permission, or assignment
- it is working on the wrong thing, or on something already done

Do NOT use it for routine status, acks, completions, or "this is important".
Importance is not the test — the test is whether continuing causes damage.
Cancelling a turn can destroy tens of minutes of unreported work.

If you are unsure between `--priority` and `--interrupt`, use `--priority`.
The failure mode of being too gentle is a delay; the failure mode of being too
aggressive is lost work.

Prefer any of the three over a bare `paseo send`. A direct send happens
outside the queue, so the queue has no record of it: if the same message was
also queued, a dispatcher delivers it a SECOND time later, and the sender has
no way to see that coming.

## Commands

- `paseo-queue add <agent> "text"` — enqueue a message, fire-and-forget.
  Prints `enqueued <shortid> (target: <state>) pending/<file>` on success;
  a `closed` target also warns, because its dispatcher will halt rather than
  deliver. That receipt means
  *enqueued*, not delivered — treat it as proof the message was accepted,
  not proof the target read it.
- `paseo-queue add <agent> --file f` — enqueue message content from a file.
- `echo hi | paseo-queue add <agent>` — enqueue message content from stdin.
- `paseo-queue add <agent> "text" --wait` — block until actually sent, then
  print `delivered <shortid> <file>`; exit 4 on `--wait-timeout N` elapsed
  (message stays queued). Use when you must report that a message actually
  arrived.
  EXPECT THIS TO BLOCK FOR MINUTES. There is no default deadline, and
  delivery requires the recipient to finish PROCESSING the message: median
  57s, p90 230s, up to ~10 minutes, plus the processing time of every message
  queued ahead of yours. Pass `--wait-timeout <seconds>` if you cannot afford
  that, and treat exit 4 as "still queued", not "failed".
- `paseo-queue add <agent> "text" --priority` — jump to the front of the
  queue and deliver now, bypassing the idle wait and the permission hold. The
  agent receives it mid-work and carries on. Receipt reads `prioritised`. A
  failed send leaves the message queued and exits nonzero.
- `paseo-queue add <agent> "text" --interrupt` — CANCEL the agent's current
  turn (`paseo stop`), then deliver. Destructive: unreported in-flight work is
  lost. Implies `--priority`. Receipt reads `interrupted`, and it tells you
  whether a running turn was actually cancelled. See the urgency section
  above before using it.
- `paseo-queue add <agent> "text" --quiet` — suppress the receipt lines
  (errors still print). For callers that only check the exit status.
- `paseo-queue ls` — list every agent's queue (pending/sent/failed counts).
- `paseo-queue status` — per-agent state, counts, dispatcher liveness.
- `paseo-queue rm <agent> <msg|--all>` — delete one or all pending messages;
  prints every filename it removes. Read that output before moving on:
  `--all` can take undelivered messages you did not know were queued.
- `paseo-queue log <agent>` — show the dispatch log.
- `paseo-queue drain <agent>` — force-(re)start the dispatcher; reports
  whether it spawned one or one was already live. This is the remedy
  `status` names when it warns about pending messages with no dispatcher.
- `paseo-queue stop <agent>` — SIGTERM the live dispatcher, naming the pid
  it killed. Idempotent: exits 0 whether or not one was running, so it is
  safe as an ensure-stopped step. Read the receipt, not the exit code, to
  tell "terminated something" from "already stopped". Queue untouched.

## Agent argument

Accepts an exact agent name, a unique agent-id prefix (subsumes the 7-char
shortId), or the full 36-char UUID. Ambiguous queries exit 2 and list every
candidate on stderr — name matching is exact, never a prefix.

## Rules for agents

- Default `add` is fire-and-forget — do not poll or `paseo wait` on it.
- Use the queue for every non-emergency prompt, even when the target appears idle.
- Do not use plain `paseo send` at all for content you would otherwise queue --
  it is invisible to the queue and risks a duplicate delivery. Use
  `--priority` to bypass FIFO, or `--interrupt` if the agent must stop.
- Use `--wait` only when the next step depends on dispatch. It does not prove
  that the recipient completed the requested work.
- If `status` shows `holding-permission`, a human must approve in the
  Paseo app.
- If `status` shows `halted-failed`, inspect `~/.paseo-queue/<uuid>/failed/`
  then run `paseo-queue drain <agent>`.

## Limits

Messages are capped at 256 KiB by default (`PASEO_QUEUE_MAX_BYTES`). This
is a local stopgap — delete it once getpaseo/paseo#3797 ships upstream.

FIFO is per-agent and holds for queued messages, but `--priority` and
`--interrupt` deliberately jump the backlog: they are delivered before
anything already waiting. Their receipts read `prioritised` and `interrupted`
rather than `delivered`, so the bypass is visible in logs. If ordering matters
more than immediacy, queue it normally.
