---
name: paseo-queue
description: Queue prompts to busy Paseo agents for ordered, safe FIFO delivery. Use instead of paseo send whenever the target agent may be busy or you want fire-and-forget follow-ups.
---

## Why

Sending to a busy agent mid-turn is unsafe with plain `paseo send`.
`paseo-queue` enqueues the message and a per-agent dispatcher auto-delivers
it once the agent is idle with no pending permission. Delivery is strict
FIFO per agent; queues to different agents run in parallel.

## Commands

- `paseo-queue add <agent> "text"` — enqueue a message, fire-and-forget.
- `paseo-queue add <agent> --file f` — enqueue message content from a file.
- `echo hi | paseo-queue add <agent>` — enqueue message content from stdin.
- `paseo-queue add <agent> "text" --wait` — block until actually sent; exit
  4 on `--wait-timeout N` elapsed (message stays queued).
- `paseo-queue ls` — list every agent's queue (pending/sent/failed counts).
- `paseo-queue status` — per-agent state, counts, dispatcher liveness.
- `paseo-queue rm <agent> <msg|--all>` — delete one or all pending messages.
- `paseo-queue log <agent>` — show the dispatch log.
- `paseo-queue drain <agent>` — force-(re)start the dispatcher.
- `paseo-queue stop <agent>` — SIGTERM the live dispatcher (queue untouched).

## Agent argument

Accepts an exact agent name, a unique agent-id prefix (subsumes the 7-char
shortId), or the full 36-char UUID. Ambiguous queries exit 2 and list every
candidate on stderr — name matching is exact, never a prefix.

## Rules for agents

- Default `add` is fire-and-forget — do not poll or `paseo wait` on it.
- Never call plain `paseo send` to an agent that has queued items — it
  would jump the queue.
- Use `--wait` only when the next step depends on the message having been
  processed.
- If `status` shows `holding-permission`, a human must approve in the
  Paseo app.
- If `status` shows `halted-failed`, inspect `~/.paseo-queue/<uuid>/failed/`
  then run `paseo-queue drain <agent>`.

## Limits

Messages are capped at 256 KiB by default (`PASEO_QUEUE_MAX_BYTES`). This
is a local stopgap — delete it once getpaseo/paseo#3797 ships upstream.
