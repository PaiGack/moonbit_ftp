#!/usr/bin/env python3
"""Exercise `ensure-ftp.sh` with a stubbed `docker`, no Docker involved.

Usage: ensure-ftp-selftest.py REPO_ROOT

`scripts/ensure-ftp.sh` exists because the plaintext container can be gone by
the time the `plain` leg runs: on CNB's DinD, `cmd/ftps/run.sh plain` failed
with `dial 127.0.0.1:21: Connection refused` *after* `cmd/example`, `cmd/ftp`
and `cmd/profiles` had all passed against the same endpoint. The port was
reported, not the container, so it read like a client regression.

The script has three outcomes and all three matter:

  * the container is healthy           -> do nothing, exit 0
  * the container is gone              -> call `start-ftp.sh` once, then pass
  * the restart does not produce one   -> exit non-zero AND print the container
                                          log, because at that point the fault
                                          is the server

The failure modes are exactly the ones a real-container test cannot see: a
"healthy" path that restarts a working server (churning the fixture under a
concurrent client) and a "dead" path that silently returns 0 would both look
fine against Docker, where the container is usually up.

So the script under test is copied into a scratch directory next to stub
`probe-ftp.py` and `start-ftp.sh`, and driven with an ephemeral port. `docker`
is a stub on PATH that just answers `ps`.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
ENSURE = ROOT / "scripts" / "ensure-ftp.sh"

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def write_executable(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def run_case(ps_says_running, probe_answers, running_after_restart=True):
    """Drive `ensure-ftp.sh` once, returning (exit code, calls made).

    `probe_answers` is consumed one entry per `probe-ftp.py` call, and any call
    past the end answers `False`. Naming the sequence explicitly is what keeps
    the cases honest: whether the first probe happens at all depends on
    `docker ps`, so "one answer" and "two answers" are *not* the same scenario.

    `running_after_restart` is what `docker ps` says once `start-ftp.sh` has
    run -- a restart that comes up is the normal case, and the stub has to be
    able to model it or the post-restart liveness check can never pass.
    """
    scratch = Path(tempfile.mkdtemp())
    scripts = scratch / "scripts"
    scripts.mkdir()
    shutil.copy(ENSURE, scripts / "ensure-ftp.sh")

    state = scratch / "state"
    state.mkdir()

    # `docker ps -q --filter name=...` is the only call the script makes, and a
    # non-empty stdout is what "running" means. It answers from whether
    # `start-ftp.sh` has run, so a restart that comes up is observable.
    calls = state / "calls"
    start_calls = state / "start_calls"
    write_executable(
        scratch / "docker",
        "#!/usr/bin/env bash\n"
        f'echo "$@" >> "{calls}"\n'
        'case "$1" in\n'
        "  ps)\n"
        f'    if [ -f "{start_calls}" ]; then up={int(running_after_restart)};'
        f' else up={int(ps_says_running)}; fi\n'
        '    [ "$up" = 1 ] && echo "abc123"\n'
        "    ;;\n"
        f'  logs) echo "STUB CONTAINER LOG" ;;\n'
        "esac\n"
        "exit 0\n",
    )

    # The probe answers in order: the pre-check, then the post-restart check.
    # Two distinct answers is what makes "healthy -> do nothing" and "restart
    # then healthy" distinguishable from each other. It is a Python file
    # because `ensure-ftp.sh` runs it with `python3`, exactly as it does the
    # real `probe-ftp.py`.
    probe_calls = state / "probe_calls"
    (scripts / "probe-ftp.py").write_text(
        "import sys\n"
        f"answers = {[bool(a) for a in probe_answers]!r}\n"
        f"path = {str(probe_calls)!r}\n"
        "open(path, 'a').write('x\\n')\n"
        "n = len(open(path).read().splitlines())\n"
        "ok = answers[n - 1] if n <= len(answers) else False\n"
        "sys.exit(0 if ok else 1)\n"
    )

    write_executable(
        scripts / "start-ftp.sh",
        "#!/usr/bin/env bash\n"
        f'echo x >> "{start_calls}"\n'
        'echo "start-ftp.sh: stub ready"\n',
    )

    env = dict(os.environ)
    env["PATH"] = f"{scratch}:{env['PATH']}"
    env["FTP_PORT"] = "65535"
    env["RECHECK_TIMEOUT"] = "1"

    done = subprocess.run(
        ["bash", str(scripts / "ensure-ftp.sh")],
        capture_output=True,
        text=True,
        env=env,
    )

    def count(path):
        return len(path.read_text().splitlines()) if path.exists() else 0

    calls_made = {
        "start": count(start_calls),
        "probe": count(probe_calls),
        "ps": count(calls),
    }
    shutil.rmtree(scratch, ignore_errors=True)
    return done, calls_made


print("ensure-ftp.sh self-test")

# 1. Healthy: the whole point of the script is to be a no-op here. Restarting a
#    working server would rebuild its fixture copy underneath the client that is
#    about to use it, so `start-ftp.sh` must not run at all.
done, calls = run_case(ps_says_running=True, probe_answers=[True])
check("a healthy container is left alone", done.returncode == 0, done.stderr.strip())
check("a healthy container is not restarted", calls["start"] == 0, str(calls))
check("a healthy container is probed once", calls["probe"] == 1, str(calls))

# 2. Gone: `docker ps` is empty, so there is nothing to probe -- restart once and
#    re-check the result.
done, calls = run_case(ps_says_running=False, probe_answers=[True])
check("a stopped container is restarted", done.returncode == 0, done.stderr.strip())
check("a stopped container is restarted exactly once", calls["start"] == 1, str(calls))
check(
    "the restart is re-probed",
    calls["probe"] == 1,
    f"probe calls: {calls['probe']} (the pre-check must be skipped)",
)
check(
    "the restart is announced",
    "not running" in done.stderr,
    done.stderr.strip(),
)

# 3. Running but not answering: the port is published, vsftpd is not serving.
#    This is the shape a bare `docker ps` check would call healthy, so the probe
#    is what has to catch it -- and it is the pre-check that runs.
done, calls = run_case(ps_says_running=True, probe_answers=[False, True])
check("an unresponsive container is restarted", done.returncode == 0, done.stderr.strip())
check("an unresponsive container is restarted once", calls["start"] == 1, str(calls))
check("an unresponsive container is probed twice", calls["probe"] == 2, str(calls))
check(
    "the unresponsive case is announced",
    "did not answer" in done.stderr,
    done.stderr.strip(),
)

# 4. The restart does not help. The fault is the server now, so the script must
#    fail *and* say which container, with its log -- otherwise this is the same
#    port-only message that started all of this.
done, calls = run_case(
    ps_says_running=True, probe_answers=[False, False], running_after_restart=False
)
check("a failed restart fails the gate", done.returncode != 0, str(done.returncode))
check(
    "a failed restart names the container",
    "moonbit-ftp-example" in done.stderr,
    done.stderr.strip(),
)
check("a failed restart is re-checked", calls["start"] == 1, str(calls))
check(
    "a failed restart dumps the container log",
    "STUB CONTAINER LOG" in done.stderr,
    done.stderr.strip(),
)

# 5. `start-ftp.sh` itself failing (image pull, port in use) must propagate, not
#    be retried forever.
scratch = Path(tempfile.mkdtemp())
scripts = scratch / "scripts"
scripts.mkdir()
shutil.copy(ENSURE, scripts / "ensure-ftp.sh")
(state := scratch / "state").mkdir()
write_executable(
    scratch / "docker",
    "#!/usr/bin/env bash\ncase \"$1\" in ps) : ;; esac\nexit 0\n",
)
write_executable(scripts / "probe-ftp.py", "#!/usr/bin/env bash\nexit 1\n")
write_executable(scripts / "start-ftp.sh", "#!/usr/bin/env bash\nexit 1\n")
done = subprocess.run(
    ["bash", str(scripts / "ensure-ftp.sh")],
    capture_output=True,
    text=True,
    env={**os.environ, "PATH": f"{scratch}:{os.environ['PATH']}", "FTP_PORT": "65535"},
)
check("a starter that fails fails the gate", done.returncode != 0, str(done.returncode))
check(
    "a starter that fails says so",
    "could not be restarted" in done.stderr,
    done.stderr.strip(),
)
shutil.rmtree(scratch, ignore_errors=True)

if failures:
    print(f"\nensure-ftp.sh self-test FAILED: {len(failures)}", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("ensure-ftp.sh self-test: all checks passed")
