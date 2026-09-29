#!/usr/bin/env python3
"""Check that the two containers do not share a writable fixture directory.

Usage: fixture-isolation-selftest.py REPO_ROOT

`start-ftps.sh` and `start-ftp.sh` used to bind-mount the same host directory
(`testdata/ftp/fixture`) as their FTP root. That is not safe with these two
images: `bfren/ftps` chowns `/files` to its own user at init (`11-user.nu`,
`FTPS_VSFTPD_UID` = 1000 by default), and because `/files` is a bind mount that
recursive chown rewrites the *host* tree. `jmoyer/vsftpd` maps its virtual user
to the image's `ftp` (uid 100), so after the FTPS container had started, the
plaintext container could no longer write its own root and `STOR` came back
`550`.

That is a *script* invariant, not a client one, and it is invisible until the
two containers have actually run in sequence. So assert it directly, with no
Docker:

  * each starter mounts its own private copy, and the two copies differ
  * neither copy is the checked-in `testdata/ftp/fixture`
  * each starter rebuilds its copy from the shared fixture
  * each `stop-*.sh` removes its copy again, so it cannot outlive the run
  * both copies are gitignored
"""

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
FTPS = ROOT / "scripts" / "ftps" / "start-ftps.sh"
PLAIN = ROOT / "scripts" / "start-ftp.sh"
STOP_FTPS = ROOT / "scripts" / "ftps" / "stop-ftps.sh"
STOP_PLAIN = ROOT / "scripts" / "stop-ftp.sh"
SHARED = ROOT / "testdata" / "ftp" / "fixture"

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def assignments(text, variable):
    """Every `VARIABLE="$ROOT/..."` value in `text`, resolved, in order."""
    return [
        (ROOT / m).resolve()
        for m in re.findall(rf'^\s*{variable}="\$ROOT/([^"]+)"', text, re.M)
    ]


def mount_target(text, variable):
    m = re.search(rf'-v "\${variable}:([^"]+)"', text)
    return m.group(1) if m else None


print("fixture isolation self-test")

ftps_text = FTPS.read_text()
plain_text = PLAIN.read_text()
stop_ftps_text = STOP_FTPS.read_text()
stop_plain_text = STOP_PLAIN.read_text()

# Each starter names where it copies from ...
ftps_src = assignments(ftps_text, "SOURCE_FIXTURE")
plain_src = assignments(plain_text, "SOURCE_FIXTURE")
check(
    "start-ftps.sh copies from the shared fixture",
    ftps_src == [SHARED],
    f"expected [{SHARED}], got {ftps_src}",
)
check(
    "start-ftp.sh copies from the shared fixture",
    plain_src == [SHARED],
    f"expected [{SHARED}], got {plain_src}",
)

# ... and where it mounts its own copy.
ftps_dirs = assignments(ftps_text, "FIXTURE")
plain_dirs = assignments(plain_text, "FIXTURE")
check("start-ftps.sh assigns FIXTURE", bool(ftps_dirs))
check("start-ftp.sh assigns FIXTURE", bool(plain_dirs))
check(
    "start-ftps.sh mounts $FIXTURE",
    mount_target(ftps_text, "FIXTURE") is not None,
)
check(
    "start-ftp.sh mounts $FIXTURE",
    mount_target(plain_text, "FIXTURE") is not None,
)

if ftps_dirs and plain_dirs:
    ftps_dir, plain_dir = ftps_dirs[-1], plain_dirs[-1]
    check(
        "the FTPS container does not mount the shared fixture",
        ftps_dir != SHARED,
        f"still mounting {SHARED}",
    )
    check(
        "the plaintext container does not mount the shared fixture",
        plain_dir != SHARED,
        f"still mounting {SHARED}",
    )
    check(
        "the two containers mount different directories",
        ftps_dir != plain_dir,
        f"both mount {ftps_dir}",
    )
    for label, directory in (("FTPS", ftps_dir), ("plaintext", plain_dir)):
        check(
            f"the {label} copy is scratch, next to the worktree",
            directory.parent == ROOT,
            f"unexpected path {directory}",
        )

for label, text, variable, directory in (
    ("start-ftps.sh", ftps_text, "SOURCE_FIXTURE", ftps_dirs[-1] if ftps_dirs else None),
    ("start-ftp.sh", plain_text, "SOURCE_FIXTURE", plain_dirs[-1] if plain_dirs else None),
):
    check(
        f"{label} rebuilds its copy from the source",
        f'cp -R "${variable}/." "$FIXTURE/"' in text,
    )
    check(
        f"{label} clears a stale copy first",
        'rm -rf "$FIXTURE"' in text,
    )

check(
    "stop-ftps.sh removes the FTPS copy",
    ftps_dirs and f'rm -rf "$ROOT/{ftps_dirs[-1].relative_to(ROOT)}"' in stop_ftps_text,
)
check(
    "stop-ftp.sh removes the plaintext copy",
    plain_dirs
    and f'rm -rf "$ROOT/{plain_dirs[-1].relative_to(ROOT)}"' in stop_plain_text,
)

gitignore = (ROOT / ".gitignore").read_text()
for label, directory in (("FTPS", ftps_dirs[-1] if ftps_dirs else None),
                         ("plaintext", plain_dirs[-1] if plain_dirs else None)):
    check(
        f"the {label} copy is gitignored",
        directory is not None
        and f"{directory.relative_to(ROOT)}/" in gitignore,
    )

if failures:
    print(f"\nfixture isolation self-test FAILED: {len(failures)}", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("fixture isolation self-test: all checks passed")
