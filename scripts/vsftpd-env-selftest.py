#!/usr/bin/env python3
"""Check that `scripts/start-ftp.sh` passes every variable the image needs.

Usage: vsftpd-env-selftest.py REPO_ROOT

`jmoyer/vsftpd`'s entrypoint (`/usr/sbin/run-vsftpd.sh`) appends one directive
per environment variable to `/etc/vsftpd/vsftpd.conf`, interpolating the value
straight in. vsftpd refuses to start when any *non-string* directive has an
empty value (`parseconf.c`: `missing value in config file for: <name>`, exit
2), and that message goes to fd 0 -- which inside a container is not the log
stream. So forgetting one variable does not produce an error message anywhere;
it produces a server that serves one handshake and is then gone.

That is exactly how this broke CI once: the five variables below were dropped
from the `docker run` and four unrelated client steps failed with
`Connection refused`. Nothing in the repo caught it, because every other test
starts *after* the container is assumed to be healthy.

So assert the invariant directly, with no Docker:

  * all ten interpolated variables are passed with a non-empty value
  * the entrypoint's own list is what defines "all ten"

The variable list is the contract, so it is written out here rather than
inferred: `PASV_ADDRESS`, `PASV_MAX_PORT`, `PASV_MIN_PORT`, `PASV_ADDR_RESOLVE`,
`PASV_ENABLE`, `FILE_OPEN_MODE`, `LOCAL_UMASK`, `XFERLOG_STD_FORMAT`,
`PASV_PROMISCUOUS`, `PORT_PROMISCUOUS`.
"""

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
START = ROOT / "scripts" / "start-ftp.sh"

# Every variable `/usr/sbin/run-vsftpd.sh` interpolates into vsftpd.conf.
# An empty value for any of them is a container that exits 2 with the reason
# on fd 0, i.e. a silent death.
REQUIRED = (
    "PASV_ADDRESS",
    "PASV_MIN_PORT",
    "PASV_MAX_PORT",
    "PASV_ADDR_RESOLVE",
    "PASV_ENABLE",
    "FILE_OPEN_MODE",
    "LOCAL_UMASK",
    "XFERLOG_STD_FORMAT",
    "PASV_PROMISCUOUS",
    "PORT_PROMISCUOUS",
)

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


print("vsftpd entrypoint env self-test")

text = START.read_text()

# The `docker run` invocation, up to the image name, is where every value lives.
docker_run = re.search(r"docker run\b(.*?)\n\s*\"\$FTP_IMAGE\"", text, re.S)
check("start-ftp.sh has a docker run for the FTP image", docker_run is not None)

if docker_run:
    body = docker_run.group(1)
    # `-e NAME=literal`, `-e NAME="$VAR"` and the fatal `-e NAME=` all reduce to
    # the same shape once the quotes are gone, which is the point: the check is
    # about an *empty* right-hand side, not about how it was written.
    passed = {
        m.group(1): m.group(2)
        for m in re.finditer(r'-e\s+([A-Z_]+)=([^\s]*)', body.replace('"', ""))
    }
    for name in REQUIRED:
        value = passed.get(name)
        check(
            f"start-ftp.sh passes {name} with a value",
            bool(value),
            f"got {value!r}",
        )
    # The failure mode is a *missing* variable, so check nothing extra is
    # silently depending on the image's own defaults either.
    check(
        "start-ftp.sh passes no empty -e value",
        all(bool(v) for v in passed.values()),
        f"empty: {[k for k, v in passed.items() if not v]}",
    )

# `--rm` deletes a container that dies, which is what made the fd-0 message
# unrecoverable. Without it `docker logs` still has the body to inspect. Only
# the docker invocation matters, so a comment mentioning the flag is fine.
check(
    "start-ftp.sh does not pass --rm to docker run",
    docker_run is not None
    and not re.search(r"^\s*--rm\s*\\?$", docker_run.group(1), re.M),
    "a died container must stay inspectable",
)

if failures:
    print(f"\nvsftpd entrypoint env self-test FAILED: {len(failures)}", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("vsftpd entrypoint env self-test: all checks passed")
