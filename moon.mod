// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "PaiGack/ftp"

version = "0.2.5"

readme = "README.mbt.md"

repository = "https://github.com/PaiGack/moonbit_ftp"

license = "Apache-2.0"

keywords = [ "ftp", "network", "client", "protocol", "async" ]

// 纯 FTP 走的是 `moonbitlang/async` 的 socket 抽象，wasm/wasm-gc 后端能提供；
// wasm 档未验证的只有 FTPS —— 主机侧 TLS（trust store、证书校验）在 wasm 上没有实现。
// 这行只是 `moon build` / `moon test` 的默认目标，不是能力声明。

preferred_target = "native"

description = "FTP/FTPS client library for MoonBit with passive EPSV/PASV data connections, MLSD/LIST parsing, resume, directory tree walking, and explicit/implicit TLS."

import {
  "moonbitlang/async@0.21.3",
  "moonbitlang/x@0.5.4",
}
