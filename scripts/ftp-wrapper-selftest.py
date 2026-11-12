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
  * the wrapper emits **no** connection flag at all. `cmd/ftp/main.mbt` reads
    `FTP_HOST` / `FTP_PORT` / `FTP_USER` / `FTP_PASS` / `FTP_TIMEOUT` as
    defaults, so the environment the wrapper inherits is already the endpoint;
    a `--host "$FTP_HOST"` here would be a second, worse copy of that reader,
    and its failure mode (an unset variable swallowing the next argv entry) is
    the one this whole section exists to remove
  * the wrapper forwards `"$@"` and ends in `exec`, so it stays a wrapper
    rather than growing argument parsing of its own

An earlier revision of this file asserted the *opposite* -- that every emitted
flag value was a `${VAR:-literal}` expansion -- which is the shape `AGENTS.md`
argues against ("A wrapper must default the endpoint in the environment, never
build `--flag <value>` pairs from it"). The wrapper and `AGENTS.md` had drifted
apart and this gate was pinning the wrong side, so a correct wrapper would have
failed it.

The same rule is checked for the other two wrappers. `cmd/profiles/run.sh`
exports its configuration instead of building flags -- `cmd/profiles` reads the
variables itself and fails loudly on a missing one -- and `cmd/example/run.sh`
needs no configuration at all, because `cmd/example/main.mbt` already defaults
every variable it reads. A `.env` in front of a program that defaults its own
variables is indirection that can only restate them, so there must not be one.

That last point is why "the wrapper owns no configuration" was, on its own,
the wrong contract: a setting that is neither forwarded nor defaulted anywhere
is simply absent in CI. `cmd/ftp/run.sh` inherited-only once, and nothing
exported a connection setting between `start-ftp.sh` and the wrapper, so the
CLI fell through to its built-in `anonymous` default:

    ===== cmd/ftp/run.sh =====
    error: login failed: PaiGack/ftp.FtpError.ServerError

while `cmd/example` and `cmd/profiles` -- which default `test`/`test`
themselves -- passed against the same container. So the wrapper now sets the
same `FTP_TEST_*` defaults `cmd/profiles/run.sh` does and exports them, and the
checks below pin that: the four names default to the container's credentials,
and the names the binary reads agree with the ones the wrapper exports, in
`cmd/ftp/main.mbt` and in the other two clients. A rename on either side of
that pair is exactly the silent `anonymous` login again.
"""

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
WRAPPER = ROOT / "cmd" / "ftp" / "run.sh"
PROFILES = ROOT / "cmd" / "profiles" / "run.sh"
EXAMPLE = ROOT / "cmd" / "example" / "run.sh"

# The connection flags the wrapper must *not* emit: `cmd/ftp/main.mbt` reads
# each of these from the environment itself. Kept as names rather than
# name/default pairs because there is no default for the wrapper to get right.
FORBIDDEN_FLAGS = ("--host", "--port", "--user", "--pass", "--timeout")

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

# --- the wrapper emits no connection flag at all ---------------------------
body = command_body(text)
check("cmd/ftp/run.sh runs cmd/ftp", bool(body), "no `moon run cmd/ftp` found")

# `cmd/ftp/main.mbt`'s own reader is the single place the endpoint is turned
# into a value, so the wrapper must not repeat it. This is checked on the
# joined command line, not on the file: the comments above name
# `--host "$FTP_HOST"` on purpose, to explain why it is not there any more.
# Only what follows the `--` separator reaches the CLI; `--target native` in
# front of it belongs to `moon run`, and asserting on the whole line would make
# this gate fail on the runner's own invocation.
forwarded = body.split(" -- ", 1)[1] if " -- " in body else ""
emitted = re.findall(r"(--[a-z-]+)", forwarded)
for flag in FORBIDDEN_FLAGS:
    check(f"cmd/ftp/run.sh does not emit {flag}", flag not in emitted,
          "the CLI reads this from the environment; building it here is the "
          "bug this file exists to catch")

check("cmd/ftp/run.sh emits no flags at all",
      not emitted, f"emitted: {emitted}")

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

# --- the wrapper defaults the endpoint instead of only inheriting it -------
# The credentials `scripts/start-ftp.sh` gives the container. This file spells
# them out rather than importing them from `start-ftp.sh`, so the two have to
# be kept in agreement by a failure rather than by a convention.
CONTAINER_DEFAULTS = (("FTP_TEST_HOST", "127.0.0.1"), ("FTP_TEST_PORT", "21"),
                      ("FTP_TEST_USER", "test"), ("FTP_TEST_PASS", "test"))

for name, default in CONTAINER_DEFAULTS:
    pattern = (r'export ' + name + r'="\$\{' + name + r':-' + re.escape(default)
               + r'\}"')
    check(f"cmd/ftp/run.sh defaults {name}", re.search(pattern, text) is not None,
          "inheriting without a default means CI runs as `anonymous`")

# `start-ftp.sh` is the authority for what the container actually accepts. The
# user and password are `:=` defaults there; the control port is the literal
# `PORT=21`, because it is not meant to be overridden.
start_ftp = (ROOT / "scripts" / "start-ftp.sh").read_text()
PORT_PATTERN = re.compile(r"^PORT=(\d+)$", re.M)
port_match = PORT_PATTERN.search(start_ftp)
check("scripts/start-ftp.sh publishes the container on a fixed port",
      port_match is not None)
check("cmd/ftp/run.sh defaults the port start-ftp.sh publishes",
      port_match is not None and port_match.group(1) == "21",
      "FTP_TEST_PORT must be the port the container listens on")
for name, default in CONTAINER_DEFAULTS:
    if name in ("FTP_TEST_HOST", "FTP_TEST_PORT"):
        continue  # the address and port above cover these
    variable = "FTP_" + name.removeprefix("FTP_TEST_")
    check(f"scripts/start-ftp.sh gives the container {variable}={default}",
          re.search(r'^: "\$\{' + variable + r':=' + re.escape(default)
                    + r'\}"$', start_ftp, re.M) is not None,
          "the wrapper's default must be a credential the container accepts")

# The other side of the same pair: the binary has to read the name the wrapper
# exports. Reading only the unprefixed spelling is what made the exported
# value invisible in the first place.
cli = (ROOT / "cmd" / "ftp" / "main.mbt").read_text()
for name, _ in CONTAINER_DEFAULTS:
    check(f"cmd/ftp/main.mbt reads {name}", f'"{name}"' in cli)

# And the two clients beside it read the same spellings, so one exported
# environment configures all three instead of each having a private name.
example_main = (ROOT / "cmd" / "example" / "main.mbt").read_text()
profiles_main = (ROOT / "cmd" / "profiles" / "main.mbt").read_text()
for name, _ in CONTAINER_DEFAULTS:
    check(f"cmd/example/main.mbt reads {name}", f'"{name}"' in example_main)
    check(f"cmd/profiles/main.mbt reads {name}", f'"{name}"' in profiles_main)

if failures:
    print("\ncmd/ftp wrapper self-test FAILED:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("cmd/ftp wrapper self-test: all checks passed")
