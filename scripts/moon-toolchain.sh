#!/usr/bin/env bash
# Fail loudly when the CI image ships a MoonBit that cannot build this repo.
#
#   scripts/moon-toolchain.sh [MOON_BINARY]
#
# Why this exists
# ---------------
# `.ide/Dockerfile` installs MoonBit with `install/unix.sh` and no version
# argument, i.e. `latest`. The CNB image is rebuilt from that recipe whenever it
# is judged stale, and `latest` is whatever the installer served at that moment
# -- nothing in this repo pins it.
#
# On 2026-10-13 that bit twice in twenty minutes. `cnb-dad-1k4qblb0a` (10:06)
# and its neighbours ran `moon 0.1.20261012` and passed; `cnb-js5-1k4qbj149`
# (10:05) and `cnb-os0-1k4qcedeo` (10:20) ran `moon 0.1.20260920` and failed at
# the very first step, `moon fmt --check`, with the same 187 errors:
#
#     Error: [4032]
#          ╭─[ /workspace/client.mbt:223:11 ]
#       223 │   start : Int32,
#          │           ──┬──
#          │             ╰──── The type Int32 is undefined.
#
# The sources are written in a surface where `Int32` is a valid type name; the
# older toolchain does not define it, so it cannot parse a single file. The
# error names the *type*, never the toolchain, so the whole pipeline reads like
# a source bug: `fmt`, `check`, `info`, `test`, `build`, `run` and every later
# step fail, and the real cause is one `moon` binary in the image.
#
# What this checks
# ----------------
# Not "the version is exactly X": the repo tracks `latest` on purpose and a date
# here would rot. It checks the one capability the sources need -- that a
# sample of the source surface compiles -- by running `moon check` on a
# two-line probe in a scratch module. The probe carries the constructs the
# failing toolchain rejected (`Int32` in a parameter, a return type and a
# struct field), so an old image fails *here*, with a message about the
# toolchain, instead of 187 messages about the sources.
#
# No Docker, no network, one `moon check` on an empty package.
set -euo pipefail

MOON="${1:-moon}"

if ! command -v "$MOON" >/dev/null 2>&1; then
  echo "moon-toolchain.sh: '$MOON' is not on PATH." >&2
  exit 1
fi

version="$("$MOON" version 2>/dev/null | head -n 1)"
echo "moon-toolchain.sh: $version"

# A scratch module in a temp dir, so the probe never touches this repo's build
# graph or its `_build/`.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/moon.mod" <<'MOD'
name = "probe/toolchain"
version = "0.0.0"
MOD

# The constructs the 0.1.20260920 image could not parse, taken from the exact
# lines it reported (`client.mbt:223`, `control.mbt:42`): `Int32` as a
# parameter type, a return type and a struct field, plus the `~` optional
# argument the same sources use.
cat > "$work/probe.mbt" <<'MBT'
///|
struct Probe {
  field : Int32
}

///|
fn probe_old(value : Int32, flag~ : Bool = false) -> Int32 {
  ignore(flag)
  value
}

///|
pub fn probe_run() -> Int32 {
  probe_old(1)
}
MBT

if ! ( cd "$work" && "$MOON" check --target native >/dev/null 2>&1 ); then
  echo "moon-toolchain.sh: this toolchain cannot parse the source surface this" \
    "repo is written in ('Int32', 'name~ : T'), so it cannot build anything" \
    "here." \
    "" \
    "The CI image installs MoonBit via 'install/unix.sh' with no version, so" \
    "'latest' is whatever that moment served -- on 2026-10-13 it regressed to" \
    "0.1.20260920 after 0.1.20261012 had passed, and every step from" \
    "'moon fmt --check' on failed with 'The type Int32 is undefined'." \
    "" \
    "Fix the toolchain, not the sources: rebuild the image (or install a" \
    "current MoonBit) and re-run. Rerunning the same job on the same image" \
    "will fail the same way." >&2
  exit 1
fi

echo "moon-toolchain.sh: toolchain accepts the source surface"
