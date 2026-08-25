---
name: paseo-message-agent
description: Coordinate with another Paseo-managed agent. Use `paseo-queue add` for routine or non-emergency reports, handoffs, policy updates, and follow-ups so FIFO ordering and permission holds are preserved. Reserve `paseo send` for messages important enough to interrupt the agent's current work.
---

# Paseo Message Agent

Use this skill when one agent must message another agent directly.

Choose transport by urgency:

- For routine or non-emergency coordination, use `paseo-queue add <agent> "msg"`. This is the default even when the target might be idle; it preserves per-agent FIFO order and permission holds.
- Add `--wait` only when the next step must block until dispatch. It confirms delivery to the agent, not completion of the requested work.
- Use `paseo send` only when the message is important enough to interrupt the target's current work. Direct send is the intentional priority path, not a convenience shortcut around the queue.

## Transport

Default non-emergency path:

```bash
paseo-queue add <agent-id> "<message>"
paseo-queue add <agent-id> --file /path/to/message.txt
paseo-queue add <agent-id> "<message>" --wait
```

Interruption-worthy path:

```bash
paseo send <agent-id> "<message>"
paseo send <agent-id> --prompt-file /path/to/message.txt
```

`<agent-id>` may be a full ID or an accepted prefix. Prefer the file form for
multi-line messages.

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
