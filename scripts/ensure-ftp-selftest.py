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
import re
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

# 6. Every plaintext client needs a re-check *directly in front of it*, not one
#    somewhere earlier in the file.
#
#    The run this gate exists for failed four steps in a row -- `cmd/ftp`,
#    `cmd/profiles`, the FTPS smoke test and then `plain` -- because the
#    re-check sat in front of `plain` alone, so the three steps before it died
#    on a container nobody had looked at yet. A single guard after
#    `cmd/example` fixes *those* three steps but not the shape: `cmd/example`
#    and `cmd/ftp` failed on adjacent lines in `cnb-cgc-1k4qajlu6`, so the
#    container died inside the window between two consecutive clients. A guard
#    is only worth as much as the window it covers, and the only window that
#    cannot be missed is the one immediately before the client.
#
#    So the assertion is not "a guard appears once" -- a bare `ci.find` would
#    be satisfied by the `plain` guard alone, or by one guard before the first
#    client, and leave the rest bare. It is "the statement immediately
#    preceding each guarded client is a guard". `cmd/ftps/run.sh` (explicit) is
#    left out on purpose: it talks to the *FTPS* container, and its own
#    starter gates that one.
#
#    `cmd/profiles` gets a *per-profile* guard, not one for the step, since one
#    guarded step still contains the window between its four sessions. In
#    `cnb-ake-1k4qn4ukc` the guard passed, three profiles finished, and the
#    fourth dialled into a container that was already gone -- reported as
#    `profile no-epsv: ReaderClosed`, i.e. as a profile result. The check below
#    therefore wants the profile list, every name from the binary's own
#    `profiles()`, each one guarded on the line immediately before it.
# 7. And the wrapper itself, which is what covers the window *inside* a client.
#
#    A guard between steps cannot see a container that dies while a client is
#    running: in `cnb-cne-1k4sv7m6r` the guard in front of `no-epsv` passed and
#    the container was gone before the profile's fourth command. `run_guarded`
#    is the answer, and it is only correct if the retry is *conditional* on the
#    server actually being gone. The four cases below are the ones a real
#    container cannot distinguish, because there the container is usually up:
#
#      healthy            -> one attempt, no restart, no retry
#      dies, recovers     -> restart, then one retry that passes
#      fails, server up   -> one attempt only: a real failure must not be
#                            papered over by an identical second attempt
#      dies, stays dead   -> restart, one retry, then a real failure
#
#    The wrapper is extracted from `ci.sh` rather than re-implemented, so this
#    tests the code CI actually runs.
ci_text = (ROOT / "scripts" / "ci.sh").read_text()
wrapper = re.search(r"^run_guarded\(\) \{.*?^\}$", ci_text, re.S | re.M)
check("ci.sh defines run_guarded", wrapper is not None, "run_guarded() not found")


def run_guarded_case(attempts_before_ok, ensure_ok):
    """Drive `run_guarded` with a stub client and a stub `ensure-ftp.sh`."""
    scratch = Path(tempfile.mkdtemp())
    scripts = scratch / "scripts"
    scripts.mkdir()
    log = scratch / "log"
    log.write_text("")

    # `ensure-ftp.sh` records that it ran and answers per `ensure_ok`.
    write_executable(
        scripts / "ensure-ftp.sh",
        "#!/usr/bin/env bash\n"
        f'echo ENSURE >> "{log}"\n'
        f'[ "{int(bool(ensure_ok))}" = 1 ]\n',
    )

    # The client appends one line per attempt and fails until it has been run
    # `attempts_before_ok` times -- the shape of "died once, then fine".
    write_executable(
        scratch / "client.sh",
        "#!/usr/bin/env bash\n"
        f'n=$(grep -c "^client " "{log}")\n'
        f'echo "client $((n + 1))" >> "{log}"\n'
        f'[ "{int(attempts_before_ok)}" -le "$((n + 1))" ]\n',
    )

    # The wrapper under test, plus the `step` helper and the `status` variable
    # it writes to. `trap cleanup EXIT` is deliberately not carried over: this
    # is about the retry, not the container teardown.
    driver = scratch / "driver.sh"
    driver.write_text(
        "#!/usr/bin/env bash\n"
        "set -uo pipefail\n"
        f'SCRIPT_DIR="{scripts}"\n'
        f'LOG="{log}"\n'
        "status=0\n"
        "step() { :; }\n"
        + (wrapper.group(0) if wrapper else "")
        + f'\nrun_guarded "{scratch}/client.sh" arg\n'
        'echo "status=$status" >&2\n'
        # The wrapper records the failure in `status`; the driver has to turn
        # that back into an exit code, or "the step failed" would be invisible
        # to the caller -- which is exactly what `ci.sh` gets from `run`.
        'exit "$status"\n',
    )

    done = subprocess.run(
        ["bash", str(driver)], capture_output=True, text=True,
        env={**os.environ, "LOG": str(log)},
    )
    lines = log.read_text().splitlines()
    counts = {
        "client": sum(1 for line in lines if line.startswith("client ")),
        "ensure": sum(1 for line in lines if line == "ENSURE"),
    }
    shutil.rmtree(scratch, ignore_errors=True)
    return done, counts


done, counts = run_guarded_case(attempts_before_ok=1, ensure_ok=True)
check("a healthy client is run exactly once",
      counts["client"] == 1, str(counts))
check("a healthy client does not restart the container",
      counts["ensure"] == 0, str(counts))
check("a healthy client leaves the status at zero",
      done.returncode == 0, done.stderr.strip())

done, counts = run_guarded_case(attempts_before_ok=2, ensure_ok=True)
check("a client that dies mid-run is retried once",
      counts["client"] == 2, str(counts))
check("the retry is preceded by a restart",
      counts["ensure"] == 1, str(counts))
check("a retry that passes leaves the status at zero",
      done.returncode == 0, done.stderr.strip())

done, counts = run_guarded_case(attempts_before_ok=99, ensure_ok=False)
check("a real failure is not retried when the server is still up",
      counts["client"] == 1, str(counts))
check("a real failure still fails the step",
      done.returncode != 0, done.stderr.strip())

done, counts = run_guarded_case(attempts_before_ok=99, ensure_ok=True)
check("a client that dies and stays dead is retried exactly once",
      counts["client"] == 2, str(counts))
check("a retry that also fails fails the step",
      done.returncode != 0, done.stderr.strip())


ci = (ROOT / "scripts" / "ci.sh").read_text()
# `\`-continuations joined, so a wrapped invocation is still one statement.
#
# Both wrappers count. `run_guarded` is the form that covers a window *inside* a
# client -- it re-checks the container when the client fails and re-runs it once
# -- and `run` is still accepted for a step that has nothing to retry. What must
# not happen is a client invoked with neither.
statements = [
    line.strip()
    for line in re.sub(r"\\\n\s*", " ", ci).splitlines()
    if line.strip().startswith("run ") or line.strip().startswith("run_guarded ")
]
# `run_guarded` is not matched by `startswith("run ")` -- it is a longer name --
# so the two are collected in one pass rather than filtered twice.
guard = 'run "$SCRIPT_DIR/ensure-ftp.sh"'
guarded_wrapper = "run_guarded "


def as_invocation(statement):
    """Normalise a statement to the `run ...` invocation it performs.

    `run_guarded "$client" args` runs the same command as `run "$client" args`,
    so the lookups below can be written against the invocation they care about
    rather than against whichever of the two wrappers a step happens to use.
    """
    if statement.startswith(guarded_wrapper):
        return "run " + statement[len(guarded_wrapper):].strip()
    return statement

# `run_guarded "$client" args...` is one statement; recover the invocation it
# stands for so the assertions below stay about the client, not the wrapper.
def invocation(statement):
    """The client invocation a `run_guarded` statement stands for."""
    inner = statement[len(guarded_wrapper):].strip()
    return "run " + inner


single_clients = {
    'run "$ROOT/cmd/ftp/run.sh"': "cmd/ftp/run.sh",
    'run "$ROOT/cmd/ftps/run.sh" plain': "cmd/ftps/run.sh plain",
}
for statement, name in single_clients.items():
    normalised = [as_invocation(each) for each in statements]
    index = normalised.index(statement) if statement in normalised else -1
    check(f"ci.sh calls every step the ordering check needs ({name})",
          index != -1, f"{statement!r} not found")
    # Either directly preceded by a guard, or wrapped in the retrying form that
    # carries its own guard. Both close the window between steps; only the
    # wrapper closes the one inside a client.
    covered = index > 0 and (
        statements[index - 1] == guard
        or statements[index - 1].startswith(guarded_wrapper)
    )
    check(f"ci.sh re-checks the container immediately before {name}",
          covered,
          f"preceded by {statements[index - 1]!r}" if index > 0 else "missing")
    check(f"ci.sh retries {name} when the server dies mid-run",
          index >= 0 and statements[index].startswith(guarded_wrapper),
          f"{statements[index]!r} is not guarded by the retrying wrapper"
          if index >= 0 else "missing")

# The profile names come from `cmd/profiles/main.mbt`, so a name added there
# without a line here is a profile CI never runs -- silently.
profiles_mbt = (ROOT / "cmd" / "profiles" / "main.mbt").read_text()
match = re.search(r"fn profiles\(\) -> Array\[String\] \{\s*\[(.*?)\]",
                  profiles_mbt, re.S)
check("cmd/profiles/main.mbt declares its profile list",
      match is not None, "profiles() not found")
if match:
    expected = re.findall(r'"([^"]+)"', match.group(1))
    guarded = set()
    for index, statement in enumerate(statements):
        if "cmd/profiles/run.sh" not in statement:
            continue
        name = statement.split('"')[-1].strip()
        # The guard test below is about the invocation this statement performs,
        # so it has to see through the retrying wrapper.
        guarded.add(name)
        covered = index > 0 and (
            statements[index - 1] == guard
            or statements[index - 1].startswith(guarded_wrapper)
        )
        check("ci.sh re-checks the container immediately before "
              "cmd/profiles/run.sh " + name,
              covered,
              ("preceded by " + repr(statements[index - 1])) if index > 0 else "missing")
        check("ci.sh retries cmd/profiles/run.sh " + name
              + " when the server dies mid-run",
              statement.startswith(guarded_wrapper),
              repr(statement))
    for name in expected:
        check(f"ci.sh runs profile {name} behind its own re-check",
              name in guarded, f"not invoked: {sorted(guarded)}")
    check("ci.sh runs no profile the binary does not know",
          guarded <= set(expected), f"extra: {sorted(guarded - set(expected))}")

if failures:
    print(f"\nensure-ftp.sh self-test FAILED: {len(failures)}", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("ensure-ftp.sh self-test: all checks passed")
