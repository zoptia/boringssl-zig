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

# Upstream gates its fiat P-256 ADX SysV assembly on `__ELF__ || __APPLE__` in
# third_party/fiat/p256_64.h, so COFF builds never reference
# fiat_p256_adx_{mul,sqr}. If that gate ever loosens again (it was `__GNUC__`
# before upstream 28950bf42), win64 would reference a SysV-only body that is not
# assembled on PE/COFF — and, lacking a sysv_abi attribute, would call it with
# the wrong convention. Warn here so it is caught before a release, not by a
# downstream link error.
echo
gate_file="third_party/fiat/p256_64.h"
echo "Checking fiat P-256 ADX gate in $gate_file..."
if [ -f "$gate_file" ] && grep -q 'void fiat_p256_adx_mul' "$gate_file"; then
    # The `#if` line directly governing the declaration, plus its continuation.
    gate="$(sed -n '1,/void fiat_p256_adx_mul/p' "$gate_file" | grep -A1 '^#if' | tail -2)"
    if printf '%s' "$gate" | grep -q '__ELF__'; then
        echo "ok: fiat_p256_adx_* still gated on __ELF__/__APPLE__ (COFF unaffected)"
    else
        echo "WARNING: $gate_file no longer gates fiat_p256_adx_* on __ELF__:" >&2
        printf '%s\n' "$gate" >&2
        echo "  win64 (nasm path) may now reference SysV-only assembly. Verify the" >&2
        echo "  x86_64-windows-gnu build; see git history of src/win_fiat/ for the" >&2
        echo "  Win64->SysV shim that used to cover this." >&2
    fi
else
    echo "notice: fiat_p256_adx_* not declared in $gate_file; gate check skipped"
fi

echo
echo "Done. Run 'zig build test' to verify the new upstream still builds."
