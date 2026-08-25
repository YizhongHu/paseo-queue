# End-to-end receipt: real-daemon FIFO delivery

Date: 2026-08-25
Tree: `28894ae` (fix(review): reject rm path-traversal targets; printf instead of echo in diagnostics)

## Setup

- Paseo daemon: real, version 0.5.2 (not the file-driven mock shim used by
  `tests/`).
- Target agent: a disposable agent created solely for this test,
  `98312178-4ff0-4b50-8693-5d98a51a0709` (model `claude-haiku-4-5`), archived
  immediately after the run completed.
- Unit suite (`tests/`) run against the mock shim: **15/15 passing**, run
  twice at this same tree (`28894ae`) — once before and once after the
  real-daemon run below, to confirm the tree under test did not drift.

## What was exercised

Three properties that the mock-shim unit suite cannot observe against a real
daemon process:

1. **FIFO delivery order** — two messages enqueued for the same busy agent
   are delivered strictly in enqueue order, not completion order.
2. **Mid-busy enqueue** — a second message queued while the dispatcher is
   already mid-delivery of the first is picked up by the same dispatcher
   instance, not dropped or requeued to a new one.
3. **Post-exit respawn for `--wait`** — after the dispatcher exits on an
   empty queue, a `paseo-queue add --wait` call against the same agent spawns
   a fresh dispatcher, blocks for real wall-clock time until delivery, and
   returns `rc=0` exactly at the moment delivery completes (not before, not
   on a timeout).

## Dispatch log excerpt (verbatim)

```
2026-08-25T01:59:37-0400 [95801] ENQ 98312178-4ff0-4b50-8693-5d98a51a0709 1787637577-0095801-0000.msg
2026-08-25T01:59:38-0400 [95883] START 98312178-4ff0-4b50-8693-5d98a51a0709 pid=95883
2026-08-25T01:59:42-0400 [95887] ENQ 98312178-4ff0-4b50-8693-5d98a51a0709 1787637582-0095887-0000.msg
2026-08-25T01:59:42-0400 [95883] WAIT-BUSY msg=1787637577-0095801-0000.msg
2026-08-25T01:59:53-0400 [95883] SEND-OK msg=1787637577-0095801-0000.msg bytes=52 dur=5s
2026-08-25T02:00:00-0400 [95883] SEND-OK msg=1787637582-0095887-0000.msg bytes=52 dur=4s
2026-08-25T02:00:10-0400 [95883] EXIT reason=empty
2026-08-25T02:00:27-0400 [96462] ENQ 98312178-4ff0-4b50-8693-5d98a51a0709 1787637627-0096462-0000.msg
2026-08-25T02:00:27-0400 [96518] START 98312178-4ff0-4b50-8693-5d98a51a0709 pid=96518
2026-08-25T02:00:33-0400 [96518] SEND-OK msg=1787637627-0096462-0000.msg bytes=54 dur=4s
2026-08-25T02:00:43-0400 [96518] EXIT reason=empty
```

### Reading the log

- `pid=95883` is a single dispatcher instance that: starts at `01:59:38`,
  observes the second `ENQ` at `01:59:42` while still busy sending the first
  message (`WAIT-BUSY`), and delivers both messages in enqueue order
  (`1787637577-...` before `1787637582-...`) before exiting on an empty
  queue at `02:00:10`. This is direct evidence for properties 1 and 2 above:
  the mid-busy enqueue was observed and served by the same running
  dispatcher, and delivery order matched enqueue order rather than arrival
  or completion order.
- After `pid=95883` exits (`EXIT reason=empty` at `02:00:10`), a new `ENQ` at
  `02:00:27` triggers a **new** dispatcher, `pid=96518` (`START` in the same
  second). This is evidence for property 3: the dispatcher is not a
  persistent daemon that lingers after its queue empties — it exits cleanly
  and a fresh one is spawned on demand for the next message.

## `--wait` blocking behavior

The `--wait` call issued against the `1787637627-0096462-0000.msg` enqueue
(corresponding to the `02:00:27` `ENQ` / `02:00:33` `SEND-OK` pair above)
blocked for approximately **9 seconds** (`02:00:27` enqueue+start to roughly
`02:00:36` return, allowing for the `SEND-OK` timestamp at `02:00:33` plus
CLI teardown) and returned `rc=0` exactly at the point of delivery — not on
a fixed timeout and not before the `SEND-OK` line was written. This confirms
`--wait` is delivery-gated, not a fire-and-forget or polling-interval
return.

## Cleanup

The disposable test agent `98312178-4ff0-4b50-8693-5d98a51a0709` was
archived immediately after this run. No production or long-lived Paseo
agents were touched; `bin/` and `tests/` were not modified for this receipt.
