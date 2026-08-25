# paseo-queue

`paseo-queue` is a local FIFO queueing tool for delivering follow-up prompts
to busy Paseo-managed agents. Paseo has no built-in "deliver at the agent's
next convenience" primitive today: `paseo send` delivers immediately (which
is undefined behavior mid-turn), and `paseo wait` is a broadcast release
shared by every waiter. `paseo-queue` provides a safe, ordered,
fire-and-forget queue in front of an agent so callers can enqueue a message
and move on, trusting it will be delivered once the agent goes idle.

This is a **stopgap**. The daemon-owned queue feature this project stands in
for exists only as unmerged upstream PRs
([getpaseo/paseo#3797](https://github.com/getpaseo/paseo/pull/3797),
[#1826](https://github.com/getpaseo/paseo/pull/1826)) with no ETA. Once
#3797 ships and is released, `paseo-queue` should be uninstalled and this
repo retired — see the disposal note at the bottom of this file.

Full usage docs, the state-directory layout, the recovery runbook, and the
FIFO/pid-reuse/clock caveats will be added as the CLI subcommands and
dispatcher are implemented (see the design plan tracked outside this repo).

## Status

This repository is currently at the scaffold stage: `bin/paseo-queue`
dispatches to subcommand stubs (`add`, `ls`, `rm`, `status`, `drain`,
`stop`, `log`) that are not yet implemented. `--help` / `help` works.

## Disposability

Once getpaseo/paseo#3797 merges and ships in a release, this tool is no
longer needed. Uninstalling is: remove the `~/.local/bin/paseo-queue`
symlink, remove the installed skill from each skill directory, and delete
this repo. The queue state directory (`$PQ_HOME`, default
`~/.paseo-queue`) holds no irreplaceable data.
