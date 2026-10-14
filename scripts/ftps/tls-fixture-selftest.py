#!/usr/bin/env python3
"""Mint the TLS fixture `moon test` needs, and prove it is really on disk.

Usage: tls-fixture-selftest.py REPO_ROOT [GEN_CERT]

`scripts/ci.sh` calls `gen-cert.sh` before `moon test`, and the whitebox test
"stor_from drives the handshake for a zero byte TLS upload"
(`transfer_wbtest.mbt`) needs the leaf it writes: its server end is a real
`@tls.Tls::server_from_pair`, which only accepts a certificate *by file path*.
The directory is gitignored, so a run that forgets the step has no certificate
at all -- and the test then fails with

    transfer_wbtest.mbt:386 FAILED: stor_from: Cancelled

which is what the async runtime reports when the task group's server task dies
and takes the caller down with it. The real cause (a missing file) never
appears, so the zero-byte TLS handshake -- the one behaviour docs/porting.md
1.4 item 7 promises -- reads as a library bug. Two things are needed and this
file checks both:

  * `gen-cert.sh` is invoked before `moon test` in `scripts/ci.sh`, with the
    gitignored `testdata/ftp/tls` directory the tests name
  * the fixture it writes is actually usable: a private key and a certificate
    in one PEM, which is the only shape `Tls::server_from_pair` accepts

The second check is what makes the gate about the *fixture* rather than about
`ci.sh`'s step order: it regenerates the pair into a scratch directory and
loads it the same way OpenSSL does when the test hands it to the TLS stack.
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
GEN_CERT = Path(sys.argv[2]) if len(sys.argv) > 2 else \
    ROOT / "scripts" / "ftps" / "gen-cert.sh"
FIXTURE = ROOT / "testdata" / "ftp" / "tls" / "vsftpd.pem"
CI = ROOT / "scripts" / "ci.sh"

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def main():
    print("TLS fixture self-test")

    # --- the fixture directory is named the way the tests name it ----------
    check("scripts/ci.sh exists", CI.is_file())
    text = CI.read_text() if CI.is_file() else ""

    # `gen-cert.sh` takes the output directory as its only argument, and the
    # tests read a hardcoded relative path, so the two have to agree.
    check("scripts/ci.sh runs gen-cert.sh before moon test",
          "gen-cert.sh" in text and
          text.index("gen-cert.sh") < text.index("run moon test"),
          "the fixture must exist before the zero-byte TLS test runs")
    check("scripts/ci.sh points gen-cert.sh at testdata/ftp/tls",
          "testdata/ftp/tls" in text,
          "the tests read testdata/ftp/tls/vsftpd.pem by relative path")

    # --- the fixture it writes is a usable key + certificate pair ----------
    scratch = Path(__file__).parent / ".fixture-scratch"
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    try:
        subprocess.run(["bash", str(GEN_CERT), str(scratch)],
                       check=True, capture_output=True)
        pem = scratch / "vsftpd.pem"
        check("gen-cert.sh writes vsftpd.pem", pem.is_file())
        check("gen-cert.sh writes a ca.pem next to it",
              (scratch / "ca.pem").is_file())

        body = pem.read_text() if pem.is_file() else ""
        # `Tls::server_from_pair` loads the key and the certificate from two
        # paths; the fixture points both at this one file, so it has to carry
        # both halves.
        check("vsftpd.pem carries a private key",
              "-----BEGIN PRIVATE KEY-----" in body or
              "-----BEGIN RSA PRIVATE KEY-----" in body)
        check("vsftpd.pem carries a certificate",
              "-----BEGIN CERTIFICATE-----" in body)

        # And the pair has to actually load, which is the only check that
        # catches a PEM OpenSSL rejects (a key that does not match the
        # certificate, say) rather than one that merely looks right.
        if pem.is_file() and (scratch / "ca.pem").is_file():
            verify = subprocess.run(
                ["openssl", "verify", "-CAfile", str(scratch / "ca.pem"),
                 str(pem)],
                capture_output=True, text=True,
            )
            check("the leaf chains to the CA gen-cert.sh wrote",
                  verify.returncode == 0,
                  (verify.stdout + verify.stderr).strip())

        # The address the test dials is 127.0.0.1, and every modern stack --
        # MoonBit's included -- ignores `commonName`, so a leaf without that
        # SAN fails verification no matter how the client is pointed at it.
        san = subprocess.run(
            ["openssl", "x509", "-in", str(pem), "-noout", "-ext",
             "subjectAltName"],
            capture_output=True, text=True,
        )
        check("the leaf carries a 127.0.0.1 SAN",
              "IP Address:127.0.0.1" in san.stdout,
              (san.stdout + san.stderr).strip())
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # --- the checked-in tree is not what the tests read --------------------
    # A committed certificate would rot and would still be a *real* fixture
    # the gate cannot regenerate, so the directory has to stay gitignored.
    ignored = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "-q",
         "testdata/ftp/tls/vsftpd.pem"],
        capture_output=True,
    )
    check("testdata/ftp/tls stays gitignored", ignored.returncode == 0)

    if failures:
        print("\nTLS fixture self-test FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("TLS fixture self-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
