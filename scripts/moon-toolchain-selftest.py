#!/usr/bin/env python3
"""Check that `scripts/moon-toolchain.sh` actually gates on the MoonBit surface.

Usage: moon-toolchain-selftest.py REPO_ROOT

`scripts/ci.sh` runs `scripts/moon-toolchain.sh` before anything else, because
the failure the guard explains is indistinguishable from a source bug once it
reaches `moon fmt --check`:

    Error: [4032]
         ╭─[ /workspace/client.mbt:223:11 ]
      223 │   start : Int32,
         │           ──┬──
         │             ╰──── The type Int32 is undefined.

187 of those, from `fmt` through `build` and every demo behind them, all naming
the *sources* while the actual fault is the `moon` binary in the image. So the
guard has one job: decide whether this toolchain can parse this repo, and when
it cannot, say so in terms of the toolchain.

That decision is what a real CI run cannot exercise, because the image is
usually fine -- the gate would only ever be seen passing. Its outcomes are
therefore driven here through stub `moon` binaries, with no Docker and no
toolchain download:

  * a toolchain that parses the probe is accepted and the job goes on
  * the toolchain that broke CI is rejected, and the message blames the
    toolchain rather than printing the source-level error again
  * a PATH with no `moon` at all fails instead of passing silently

The old stub reproduces the one behaviour that matters: it exits non-zero from
`moon check` when the probe mentions `Int32`, which is what 0.1.20260920 did to
every file in this repo.

The last group checks that `scripts/ci.sh` *calls* the guard and calls it first.
A guard placed after `moon fmt --check` never runs, because that command is
already the first casualty of the bug.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
GUARD = ROOT / "scripts" / "moon-toolchain.sh"
BASH = "/bin/bash"

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def stub(directory, body):
    """Write a stub `moon` in `directory` and return its path."""
    path = Path(directory) / "moon"
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)
    return path


def run_guard(bin_dir):
    """Run the guard with `bin_dir` first.

    Not `bin_dir` alone: the guard is a shell script and needs `head`, `grep`
    and `mktemp` from the system, and the stubs need `bash`. Only the search for
    `moon` is being redirected -- that is the one the guard resolves by name,
    and the stub directory wins because it comes first.
    """
    env = dict(os.environ)
    env["PATH"] = str(bin_dir) + os.pathsep + os.environ.get("PATH", "")
    return subprocess.run(
        [BASH, str(GUARD), "moon"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )


# A toolchain that parses the probe: `moon check` succeeds, and the version is
# the one that passed CI.
MODERN = (
    'case "$1" in\n'
    '  version) echo "moon 0.1.20261012 (748b63c 2026-10-12)";;\n'
    '  *) exit 0;;\n'
    'esac\n'
)

# The toolchain that failed CI: `moon check` rejects anything using `Int32`,
# which is what turned into 187 errors in the pipeline.
OLD = (
    'case "$1" in\n'
    '  version) echo "moon 0.1.20260920 (914d7da 2026-09-20)";;\n'
    '  check)\n'
    '    if grep -q Int32 probe.mbt 2>/dev/null; then\n'
    '      echo "Error: [4032]"; exit 1\n'
    '    fi\n'
    '    exit 0;;\n'
    '  *) exit 0;;\n'
    'esac\n'
)

print("moon-toolchain.sh self-test")

with tempfile.TemporaryDirectory() as tmp:
    # One directory per stub: `moon` is one name, so sharing a directory would
    # make the second stub overwrite the first.
    modern_dir = Path(tmp) / "modern"
    old_dir = Path(tmp) / "old"
    empty_dir = Path(tmp) / "empty"
    for directory in (modern_dir, old_dir, empty_dir):
        directory.mkdir()
    stub(modern_dir, MODERN)
    stub(old_dir, OLD)

    result = run_guard(modern_dir)
    check("accepts a toolchain that parses the sources", result.returncode == 0,
          f"rc={result.returncode} {result.stderr.strip()!r}")

    result = run_guard(old_dir)
    check("rejects the toolchain that failed CI", result.returncode != 0,
          "an old toolchain must fail the gate, not the sources")
    # The whole point of the gate: when it fails, it has to name the toolchain.
    check("its failure blames the toolchain, not the sources",
          "toolchain" in result.stderr.lower(),
          f"stderr={result.stderr.strip()!r}")
    # The guard may *quote* the symptom to explain itself, but it must not emit
    # the compiler's own error block again: repeating 187 of those is exactly
    # what made the pipeline unreadable and sent two rounds hunting the sources.
    check("its failure does not reprint the compiler's error block",
          "[4032]" not in result.stderr and "client.mbt" not in result.stderr,
          f"stderr={result.stderr.strip()!r}")
    check("its failure names the step it would have broken",
          "moon fmt" in result.stderr or "fmt" in result.stderr,
          "the reader has to be able to match it to the pipeline")

    # A guard that cannot find `moon` at all must fail rather than pass, or it
    # would green-light an image with no toolchain at all. `moon` has to be
    # genuinely *absent*, so PATH is replaced rather than prefixed.
    env = dict(os.environ)
    env["PATH"] = str(empty_dir)
    result = subprocess.run(
        [BASH, str(GUARD), "moon"], cwd=ROOT, env=env,
        capture_output=True, text=True, timeout=300,
    )
    check("fails when `moon` is not on PATH", result.returncode != 0,
          "a missing toolchain is not a passing toolchain")

# The guard is only useful if the pipeline calls it, and calls it *first*.
ci = (ROOT / "scripts" / "ci.sh").read_text()


def position(needle):
    """Where `needle` is *run* as a step, not merely mentioned.

    A plain `str.find` would be fooled by the comments this change adds: the
    guard is named in its own explanatory block and in the self-test line
    further down, and a comment mentioning `moon update` or `moon fmt --check`
    sits above both. Only `run ...` lines are steps, so anchor on those.
    """
    for index, line in enumerate(ci.splitlines()):
        stripped = line.strip()
        if stripped.startswith("run ") and needle in stripped:
            return index
    return -1


guard_at = position("moon-toolchain.sh")
fmt_at = position("moon fmt --check")
update_at = position("moon update")
check("ci.sh runs the toolchain guard", guard_at != -1,
      "the guard is not wired into the pipeline")
check("ci.sh runs it before `moon fmt --check`",
      guard_at != -1 and fmt_at != -1 and guard_at < fmt_at,
      "after that step the guard never runs: it is the first casualty")
check("ci.sh runs it before `moon update`",
      guard_at != -1 and update_at != -1 and guard_at < update_at,
      "an unusable toolchain should not be asked to do work first")

if failures:
    print(f"\nmoon-toolchain.sh self-test FAILED: {len(failures)}", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("moon-toolchain.sh self-test: all checks passed")
