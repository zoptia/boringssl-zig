#!/usr/bin/env bash
# Merge the latest google/boringssl@main into this fork.
#
# This repo is a fork of google/boringssl: upstream files live at the repo
# root, and our additions (build.zig, src/, tests/, scripts/, .github/) sit
# alongside them with non-conflicting names. Upstream sync is therefore a
# plain `git fetch && git merge`.
#
# Conflicts are unlikely but possible — most often if upstream renames a
# directory we list in build.zig.zon's `.paths`, or changes the
# gen/sources.json schema.

set -euo pipefail

UPSTREAM_URL="https://github.com/google/boringssl.git"
UPSTREAM_BRANCH="main"
REMOTE_NAME="upstream"

cd "$(git rev-parse --show-toplevel)"

# Add the upstream remote if it isn't there yet.
if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    echo "Adding remote '$REMOTE_NAME' -> $UPSTREAM_URL"
    git remote add "$REMOTE_NAME" "$UPSTREAM_URL"
fi

echo "Fetching $REMOTE_NAME/$UPSTREAM_BRANCH..."
git fetch "$REMOTE_NAME" "$UPSTREAM_BRANCH"

echo "Merging $REMOTE_NAME/$UPSTREAM_BRANCH..."
git merge --no-edit "$REMOTE_NAME/$UPSTREAM_BRANCH"

# The fork freezes a de-ELF'd copy of two upstream fiat P-256 ADX asm bodies in
# src/win_fiat/ (for the win64 build). Those live at a non-colliding path, so an
# upstream regeneration of the originals merges cleanly and would NOT raise a
# git conflict — it would silently leave our copy stale. Catch that here.
echo
echo "Checking win64 fiat shim against upstream..."
if ! scripts/check-win-fiat.sh; then
    echo
    echo "WARNING: src/win_fiat/ drifted from upstream (see above). The merge is" >&2
    echo "done, but regenerate the de-ELF'd body before shipping a win64 build." >&2
fi

echo
echo "Done. Run 'zig build test' to verify the new upstream still builds."
