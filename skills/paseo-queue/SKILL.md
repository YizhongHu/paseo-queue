---
name: paseo-queue
description: Queue routine and non-emergency prompts to Paseo agents for ordered FIFO delivery with permission holds. Use as the default coordination path regardless of whether the target appears busy. Reserve paseo send for messages important enough to interrupt current work.
---

## Why

Queueing is the default for routine and non-emergency coordination.
`paseo-queue` enqueues the message and a per-agent dispatcher auto-delivers
it once the agent is idle with no pending permission. Delivery is strict
FIFO per agent; queues to different agents run in parallel.

`paseo send` is the priority interrupt path. Use it when the message is
important enough to interrupt the target's current work and intentionally
take precedence over ordinary queued coordination.

## Commands

- `paseo-queue add <agent> "text"` — enqueue a message, fire-and-forget.
  Prints `enqueued <shortid> pending/<file>` on success. That receipt means
  *enqueued*, not delivered — treat it as proof the message was accepted,
  not proof the target read it.
- `paseo-queue add <agent> --file f` — enqueue message content from a file.
- `echo hi | paseo-queue add <agent>` — enqueue message content from stdin.
- `paseo-queue add <agent> "text" --wait` — block until actually sent, then
  print `delivered <shortid> <file>`; exit 4 on `--wait-timeout N` elapsed
  (message stays queued). Use this when you need to report that a message
  actually arrived.
- `paseo-queue add <agent> "text" --quiet` — suppress the receipt lines
  (errors still print). For callers that only check the exit status.
- `paseo-queue ls` — list every agent's queue (pending/sent/failed counts).
- `paseo-queue status` — per-agent state, counts, dispatcher liveness.
- `paseo-queue rm <agent> <msg|--all>` — delete one or all pending messages;
  prints every filename it removes. Read that output before moving on:
  `--all` can take undelivered messages you did not know were queued.
- `paseo-queue log <agent>` — show the dispatch log.
- `paseo-queue drain <agent>` — force-(re)start the dispatcher.
- `paseo-queue stop <agent>` — SIGTERM the live dispatcher (queue untouched).

## Agent argument

Accepts an exact agent name, a unique agent-id prefix (subsumes the 7-char
shortId), or the full 36-char UUID. Ambiguous queries exit 2 and list every
candidate on stderr — name matching is exact, never a prefix.

## Rules for agents

- Default `add` is fire-and-forget — do not poll or `paseo wait` on it.
- Use the queue for every non-emergency prompt, even when the target appears idle.
- Do not use plain `paseo send` merely to jump queued items. Bypass FIFO when
  the message genuinely warrants interrupting current work.
- Use `--wait` only when the next step depends on dispatch. It does not prove
  that the recipient completed the requested work.
- If `status` shows `holding-permission`, a human must approve in the
  Paseo app.
- If `status` shows `halted-failed`, inspect `~/.paseo-queue/<uuid>/failed/`
  then run `paseo-queue drain <agent>`.

## Limits

Messages are capped at 256 KiB by default (`PASEO_QUEUE_MAX_BYTES`). This
is a local stopgap — delete it once getpaseo/paseo#3797 ships upstream.
