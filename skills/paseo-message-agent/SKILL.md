---
name: paseo-message-agent
description: Coordinate with another Paseo-managed agent. Use `paseo-queue add` for routine or non-emergency reports, handoffs, policy updates, and follow-ups so FIFO ordering and permission holds are preserved. For messages important enough to interrupt, use `paseo-queue add --interrupt` rather than a bare `paseo send`: it delivers immediately and records the send, so the message cannot be delivered twice.
---

# Paseo Message Agent

Use this skill when one agent must message another agent directly.

Choose transport by urgency:

- For routine or non-emergency coordination, use `paseo-queue add <agent> "msg"`. This is the default even when the target might be idle; it preserves per-agent FIFO order and permission holds.
- Add `--wait` only when the next step must block until dispatch. It confirms delivery to the agent, not completion of the requested work.
- To interrupt, use `paseo-queue add <agent-id> "<message>" --interrupt`. It
  delivers immediately, skipping the idle wait and the permission hold, and
  files the message as sent so no dispatcher re-delivers it.
- Avoid a bare `paseo send` for content you would otherwise queue. The queue
  has no record of a direct send, so a message that was also queued gets
  delivered a second time later. Reach for `paseo send` only when you need
  the raw transport and are deliberately not queueing at all.

## Transport

Default non-emergency path:

```bash
paseo-queue add <agent-id> "<message>"
paseo-queue add <agent-id> --file /path/to/message.txt
paseo-queue add <agent-id> "<message>" --wait
```

Interruption-worthy path:

```bash
paseo-queue add <agent-id> "<message>" --interrupt
paseo-queue add <agent-id> --file /path/to/message.txt --interrupt
```

`<agent-id>` may be a full ID or an accepted prefix. Multi-line text, including
markdown bullets, is accepted inline as a single quoted argument. Prefer the file
form when the message is long or when its quoting is awkward to get right in a
shell, not because of its shape.

## Message shape

Include:

- purpose of the message;
- repository or deliverable context;
- decision, instruction, or blocker;
- exact action requested from the receiving agent;
- branch/SHA/workspace facts when they matter;
- any durable receipt or report path the receiver should rely on.

## Do not overclaim

- `paseo send` is a directed message, not a hook broadcast.
- Do not claim hook delivery when you used `paseo send`.
- Do not claim the message changed policy unless a durable source of truth also
  exists.

## Failure handling

If the local daemon is unreachable or hooks are disabled, say so explicitly and
fall back to a durable written handoff or manual relay instead of pretending the
message was delivered.
