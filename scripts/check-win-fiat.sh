#!/usr/bin/env bash
# check-win-fiat.sh — guard the fork-owned win64 fiat P-256 ADX shim against
# upstream drift, obsolescence, and symbol collision.
#
# src/win_fiat/fiat_p256_adx_{mul,sqr}.S each wrap a BYTE-IDENTICAL, de-ELF'd
# copy of the upstream SysV body (third_party/fiat/asm/fiat_p256_adx_*.S) in a
# Win64->SysV calling-convention shim. Upstream files at the repo root merge
# cleanly on `git merge upstream/main` (different paths), so a regeneration of
# the upstream fiat asm would NOT produce a git conflict — our frozen copy would
# silently go stale instead. This script turns that silent drift into a loud
# failure. Run it from scripts/sync-upstream.sh after the merge, and in CI.
#
# Exit non-zero on drift (body no longer matches upstream) or a detected nasm
# collision. Prints advisory notices if upstream changes make the shim
# unnecessary (then it can be simplified or deleted).
#
# Requires: zig on PATH (override with $ZIG), plus grep/diff/awk.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ZIG="${ZIG:-zig}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# Emit just the instruction body: .cfi_startproc .. .cfi_endproc inclusive.
extract_body() { awk '/\.cfi_startproc/{f=1} f{print} /\.cfi_endproc/{f=0}'; }

for op in mul sqr; do
  upstream="third_party/fiat/asm/fiat_p256_adx_${op}.S"
  fork="src/win_fiat/fiat_p256_adx_${op}.S"
  # Re-derive the de-ELF'd body from the CURRENT upstream .S (same pipeline the
  # .S header documents) and compare against the body embedded in the fork file.
  # OPENSSL_X86_64 is auto-defined by target.h for x86_64; __ELF__ must be forced
  # so the upstream `__APPLE__ || __ELF__` guard emits the body on this COFF target.
  "$ZIG" cc -target x86_64-windows -E -Iinclude -D__ELF__=1 "$upstream" 2>/dev/null \
    | grep -vE '^[[:space:]]*(#|\.(type|size|hidden|private_extern|pushsection|popsection|section[[:space:]]+\.note))' \
    | extract_body > "$tmp/up_$op"
  extract_body < "$fork" > "$tmp/fork_$op"
  if diff -q "$tmp/up_$op" "$tmp/fork_$op" >/dev/null; then
    echo "ok: $fork body is byte-identical to de-ELF'd $upstream"
  else
    echo "DRIFT: $fork body no longer matches $upstream." >&2
    echo "  Regenerate the body (see the .S header) and re-verify the shim." >&2
    diff "$tmp/up_$op" "$tmp/fork_$op" >&2 || true
    fail=1
  fi
done

# OBSOLETE: has upstream made the shim (or the whole file) unnecessary?
disp="third_party/fiat/p256_64.h"
if grep -B1 -A3 'fiat_p256_adx_mul' "$disp" | grep -q 'sysv_abi'; then
  echo "notice: $disp now declares fiat_p256_adx_* with __attribute__((sysv_abi));"
  echo "        clang will marshal the ABI itself — the Win64->SysV shim in"
  echo "        src/win_fiat/ can be reduced to a plain de-ELF'd body."
fi
if grep -B2 -A3 'fiat_p256_adx_mul' "$disp" | grep -q 'OPENSSL_WINDOWS'; then
  echo "notice: $disp now guards fiat_p256_adx_* with OPENSSL_WINDOWS — win64 no"
  echo "        longer references these symbols; src/win_fiat/ may be removable."
fi

# COLLISION: did upstream ship a nasm/.asm variant that would duplicate our symbol?
# (build.zig's containsFiatAdx() already skips the fork files in that case; this
# is a louder heads-up so a maintainer verifies there is no duplicate symbol.)
if grep -E 'fiat_p256_adx[^"]*\.asm' gen/sources.json >/dev/null 2>&1; then
  echo "WARNING: gen/sources.json lists a fiat_p256_adx .asm (nasm) variant." >&2
  echo "  build.zig should now skip src/win_fiat/; confirm no duplicate symbol." >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "check-win-fiat: FAILED" >&2
  exit 1
fi
echo "check-win-fiat: OK"
