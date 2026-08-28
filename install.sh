#!/bin/sh
# install.sh: idempotent, non-interactive installer for paseo-queue.
#
# Installs:
#   1. ~/.local/bin/paseo-queue         -> symlink to <repo>/bin/paseo-queue
#   2. ~/.claude/skills/paseo-queue/    -> copy of skills/paseo-queue/SKILL.md
#   3. ~/.codex/skills/paseo-queue/     -> copy of skills/paseo-queue/SKILL.md
#   4. ~/.agents/skills/paseo-queue/    -> copy of skills/paseo-queue/SKILL.md
#
# Safe to re-run: every step below is idempotent (chmod, ln -sf, mkdir -p,
# cp -f). Touches nothing outside the four locations above.
set -eu

# Resolve the directory this script lives in, so paseo-queue can be
# installed from a checkout at any path (not just ~/paseo-queue).
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=${REPO_DIR:-"$script_dir"}

# 1. Verify the runtime the CLI needs. bin/paseo-queue is a Python 3
# program, so a missing python3 would produce a confusing exec failure at
# first use rather than here.
if ! command -v python3 >/dev/null 2>&1; then
    echo "install.sh: FAILED - python3 is not on PATH." >&2
    echo "paseo-queue is a Python 3 program and needs python3 available." >&2
    exit 1
fi

# 2. Ensure the CLI is executable.
chmod +x "$REPO_DIR/bin/paseo-queue"

# 3. Symlink the CLI onto PATH via ~/.local/bin.
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/bin/paseo-queue" "$HOME/.local/bin/paseo-queue"

# 4. Install the skill into every skill directory Paseo-managed agents read.
for skills_root in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
    mkdir -p "$skills_root/paseo-queue"
    cp -f "$REPO_DIR/skills/paseo-queue/SKILL.md" "$skills_root/paseo-queue/SKILL.md"
done

# 5. Verify: the CLI must resolve on PATH and run.
if ! command -v paseo-queue >/dev/null 2>&1; then
    echo "install.sh: FAILED - paseo-queue is not on PATH." >&2
    echo "Remedy: add \$HOME/.local/bin to PATH, e.g.:" >&2
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    exit 1
fi

if ! paseo-queue --help >/dev/null 2>&1; then
    echo "install.sh: FAILED - paseo-queue --help did not exit 0." >&2
    echo "Remedy: run '$REPO_DIR/bin/paseo-queue --help' directly to see the error." >&2
    exit 1
fi

echo "install.sh: SUCCESS - installed $HOME/.local/bin/paseo-queue (-> $REPO_DIR/bin/paseo-queue) and skills/paseo-queue/SKILL.md into $HOME/.claude/skills/paseo-queue, $HOME/.codex/skills/paseo-queue, $HOME/.agents/skills/paseo-queue"
