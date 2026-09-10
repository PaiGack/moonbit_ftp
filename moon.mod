// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "PaiGack/ftp"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/PaiGack/moonbit_ftp"

license = "Apache-2.0"

keywords = [ "ftp", "network", "client", "protocol", "async" ]

// FTP 需要真实网络栈（TCP + TLS），wasm/wasm-gc 后端无法提供，故声明为 native。

preferred_target = "native"

description = "A pure MoonBit FTP client library ported from jlaffaye/ftp, supporting passive mode, MLSD/LIST parsing, resume and FTPS."
