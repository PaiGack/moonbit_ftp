# .ide/Dockerfile

FROM cnbcool/default-dev-env:latest

# `openssl` is used by the FTPS test path: `scripts/ftps/gen-cert.sh` mints the
# throwaway CA + leaf on every run, and `scripts/ftps/probe-ftps.sh` drives the
# `AUTH TLS` readiness handshake with `s_client`. `python3` stays because
# `scripts/probe-ftp.py` probes the plaintext container.
RUN apt-get update && apt-get install -y \
      gcc libc6-dev libssl-dev strace python3 openssl

# The MoonBit toolchain.
#
# `install/unix.sh` with no version installs `latest`, and a dated version is
# not fetchable in this environment (`binaries/<version>/...` answers 403/404;
# only `latest` and `nightly` resolve), so the image cannot pin it here.
#
# That matters because `latest` moved backwards once: on 2026-10-13 a rebuilt
# image carried `moon 0.1.20260920`, older than the `0.1.20261012` that had
# passed twenty minutes earlier, and the pipeline failed from `moon fmt
# --check` down with "The type Int32 is undefined" 187 times, naming sources
# that had not changed. Since the version cannot be pinned at build time, the
# surface is checked at run time instead: `scripts/moon-toolchain.sh` is the
# first step of `scripts/ci.sh` and fails in one message about the toolchain.
RUN curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash \
     && "$HOME/.moon/bin/moon" version \
     && code-server --install-extension moonbit.moonbit-lang

RUN curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash

RUN curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash


RUN wget https://go.dev/dl/go1.27.1.linux-amd64.tar.gz \
     && rm -rf /usr/local/go && tar -C /usr/local -xzf go1.27.1.linux-amd64.tar.gz \
     && rm -rf go1.27.1.linux-amd64.tar.gz

ENV PATH="$PATH:/root/.local/bin:/usr/local/go/bin:/root/.moon/bin" \
     GOPROXY=https://goproxy.cn,direct

RUN go install golang.org/x/tools/gopls@latest \
     && go install honnef.co/go/tools/cmd/staticcheck@latest \
     && go install github.com/go-delve/delve/cmd/dlv@latest

ENV workspace="/workspace"

RUN code-server --install-extension tamasfe.even-better-toml \
     && code-server --install-extension usernamehw.errorlens \
     && code-server --install-extension chanhx.crabviz \
     && code-server --install-extension golang.Go \
     && code-server --install-extension Anthropic.claude-code
