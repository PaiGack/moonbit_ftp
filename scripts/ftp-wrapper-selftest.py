#!/usr/bin/env python3
"""Check that `cmd/ftp/run.sh` hands the endpoint over without building flags.

Usage: ftp-wrapper-selftest.py REPO_ROOT

`cmd/ftp/run.sh` is the CI step right after `cmd/example/run.sh`, against the
container `scripts/start-ftp.sh` just reported ready. It used to read a `.env`
(auto-created from `.env.example`) and turn it into

    moon run cmd/ftp -- --host "$FTP_HOST" --port "$FTP_PORT" ...

which is a footgun, and it has one failure mode that is silent about its own
cause: `.env` is created *by the same script* that sources it, so any run where
that copy does not land has `set -a && . "$SCRIPT_DIR/.env"` fail before a
single variable is exported. What reaches the CLI then is `--host` with no value
and whatever `"$FTP_HOST"` expanded to as a positional argument, i.e. a usage
error on input nobody typed.

That is a latent hazard rather than a diagnosis: a later CI run
(`cnb-hka-1k4qa65hk`) shows `cmd/ftp/run.sh` completing normally, so the
`-e TCP socket / Connection reset / Connection refused` triple in the run before
it was the plaintext container dying mid-run, not this. Both are worth removing,
and this file only claims the second one -- it asserts the wrapper's *shape*,
and says nothing about why any particular run failed.

The invariant that removes the whole class of bug is small enough to assert
without Docker, and that is what this file does:

  * no `.env` / `.env.example` sits next to the wrapper, and the wrapper does
    not source one -- there is nothing left to be empty at the wrong moment
  * every connection flag the wrapper emits has a `${VAR:-default}` expansion
    as its value, so an unset environment cannot swallow the flag
  * the defaults it emits are *literals* of the right shape, not `$VAR`
    expansions: `"${FTP_HOST:-$SOMETHING_ELSE}"` would put the footgun back
  * the wrapper forwards `"$@"` and ends in `exec`, so it stays a wrapper
    rather than growing argument parsing of its own

The same rule is checked for the other two wrappers. `cmd/profiles/run.sh`
exports its configuration instead of building flags -- `cmd/profiles` reads the
variables itself and fails loudly on a missing one -- and `cmd/example/run.sh`
needs no configuration at all, because `cmd/example/main.mbt` already defaults
every variable it reads. A `.env` in front of a program that defaults its own
variables is indirection that can only restate them, so there must not be one.
"""

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
WRAPPER = ROOT / "cmd" / "ftp" / "run.sh"
PROFILES = ROOT / "cmd" / "profiles" / "run.sh"
EXAMPLE = ROOT / "cmd" / "example" / "run.sh"

# The flags the wrapper is allowed to pass, and the shape of value each needs.
# `--trust-pasv-ip` and friends take no value and are not in the list.
EXPECTED = {
    "--host": "127.0.0.1",
    "--port": "21",
    "--user": "test",
    "--pass": "test",
    "--timeout": "15000",
}

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def command_body(text):
    """The `moon run` invocation, with `\\`-continuations joined into one line.

    Anchored on the line *starting* with `exec moon run`, not on the first line
    that mentions `moon run`: the file's own comments name the command twice
    ("Build/run from the repo root so `moon run cmd/ftp` resolves the package"),
    and matching one of those would check a comment instead of the code.
    """
    joined = re.sub(r"\\\n\s*", " ", text)
    match = re.search(r"^\s*exec moon run cmd/ftp.*$", joined, re.M)
    return match.group(0) if match else ""


print("cmd/ftp wrapper self-test")

text = WRAPPER.read_text()
profiles = PROFILES.read_text()

check("cmd/ftp/run.sh exists", WRAPPER.is_file())
check("cmd/profiles/run.sh exists", PROFILES.is_file())
check("cmd/example/run.sh exists", EXAMPLE.is_file())

# --- no configuration file next to either wrapper --------------------------
for directory in (WRAPPER.parent, PROFILES.parent, EXAMPLE.parent):
    check(f"{directory.name} has no .env.example",
          not (directory / ".env.example").exists())
    check(f"{directory.name} has no .env", not (directory / ".env").exists())
check("cmd/ftp/run.sh does not source a .env",
      not re.search(r'^\s*\.\s+"\$SCRIPT_DIR/\.env"', text, re.M),
      "sourcing a file the script itself creates is the empty-value window")
check("cmd/profiles/run.sh does not source a .env",
      not re.search(r'^\s*\.\s+"\$SCRIPT_DIR/\.env"', profiles, re.M))

example = EXAMPLE.read_text()
check("cmd/example/run.sh does not source a .env",
      not re.search(r'^\s*\.\s+"\$SCRIPT_DIR/\.env"', example, re.M))

# --- every flag value is a ${VAR:-default} ---------------------------------
body = command_body(text)
check("cmd/ftp/run.sh runs cmd/ftp", bool(body), "no `moon run cmd/ftp` found")

pairs = re.findall(r'(--[a-z-]+)\s+("[^"]*"|\S+)', body)
seen = {}
for flag, value in pairs:
    seen[flag] = value

for flag, default in EXPECTED.items():
    value = seen.get(flag)
    pattern = r'^\W*\$\{[A-Z_]+:-' + re.escape(default) + r'\}\W*$'
    check(f"{flag} gets a ${{VAR:-{default}}} value",
          bool(value) and re.match(pattern, value) is not None,
          f"got {value!r}")

check("no flag is passed without a value",
      not re.search(r"(--[a-z-]+)(?=\s*(?:--|$))", body),
      "a bare flag takes the next argument with it")

check("cmd/ftp/run.sh forwards its arguments",
      '"$@"' in body, "explicit argv must reach the CLI")

# `exec` so the wrapper's exit status is the CLI's own.
check("cmd/ftp/run.sh ends in exec", "exec moon run cmd/ftp" in body)

# --- the profiles wrapper exports instead of building flags ----------------
for name, default in (("FTP_TEST_HOST", "127.0.0.1"), ("FTP_TEST_PORT", "21"),
                      ("FTP_TEST_USER", "test"), ("FTP_TEST_PASS", "test")):
    pattern = r'export ' + name + r'="\$\{' + name + r':-' + re.escape(default) + r'\}"'
    check(f"cmd/profiles/run.sh defaults {name}", re.search(pattern, profiles)
          is not None)

check("cmd/profiles/run.sh runs cmd/profiles",
      "moon run cmd/profiles" in profiles)
check("cmd/example/run.sh runs cmd/example",
      "moon run cmd/example" in example)
check("cmd/example/run.sh ends in exec", "exec moon run cmd/example" in example)

if failures:
    print("\ncmd/ftp wrapper self-test FAILED:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("cmd/ftp wrapper self-test: all checks passed")
