---
name: paseo-message-agent
description: Coordinate with another Paseo-managed agent. Use `paseo-queue add` for routine or non-emergency reports, handoffs, policy updates, and follow-ups so FIFO ordering and permission holds are preserved. For urgent messages use `paseo-queue add --priority`, which jumps the queue and arrives mid-work; reserve `add --interrupt` for cases where the agent must STOP, since it cancels its current turn and destroys unreported work. Prefer either over a bare `paseo send`, which the queue cannot see.
---

# Paseo Message Agent

Use this skill when one agent must message another agent directly.

Choose transport by urgency:

- For routine or non-emergency coordination, use `paseo-queue add <agent> "msg"`. This is the default even when the target might be idle; it preserves per-agent FIFO order and permission holds.
- Add `--wait` only when the next step must block until dispatch. It confirms delivery to the agent, not completion of the requested work.
- To jump the queue, use `paseo-queue add <agent-id> "<message>" --priority`.
  It delivers immediately, skipping the idle wait and the permission hold, and
  files the message as sent so no dispatcher re-delivers it. It reaches the
  agent mid-work -- which CANCELS its in-flight tool call. The agent keeps its
  turn and context and can retry, but a long command in progress is cut short,
  so this is not a free action.
- To make the agent STOP, use `--interrupt` instead. It runs `paseo stop`
  first, so the agent's in-flight work is lost. Use it only when continuing
  would be wrong -- a stop order, a correction to a premise it is acting on, a
  revoked assumption. Not for routine status or "this is important".
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
paseo-queue add <agent-id> "<message>" --priority
paseo-queue add <agent-id> --file /path/to/message.txt --priority
paseo-queue add <agent-id> "STOP: <why continuing is wrong>" --interrupt
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
