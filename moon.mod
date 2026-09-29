// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "PaiGack/ftp"

version = "0.5.0"

readme = "README.mbt.md"

repository = "https://github.com/PaiGack/moonbit_ftp"

license = "Apache-2.0"

keywords = [ "ftp", "network", "client", "protocol", "async" ]

// FTP 需要真实网络栈（TCP + TLS），wasm/wasm-gc 后端无法提供，故声明为 native。

preferred_target = "native"

description = "FTP/FTPS client library for MoonBit with passive EPSV/PASV data connections, MLSD/LIST parsing, resume, directory tree walking, and explicit/implicit TLS."

import {
  "moonbitlang/async@0.21.3",
  "moonbitlang/x@0.5.4",
}
