// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: IO — test-only helper, drives a scripted FTP server over a real
// loopback socket so the control layer is exercised end to end instead of
// against an in-memory stub.
//
// This is the MoonBit port of upstream `conn_test.go`'s `ftpMock`. W2 only
// needs the control channel; W3+ extend the same script with `EPSV` / `PASV`
// and a second listener, so the shape here is kept deliberately close to the
// Go original instead of being tailored to the first few assertions.

///|
/// One scripted exchange: the verb to match and the raw reply to write.
///
/// A `nil` reply means "read the command, answer nothing" — used by the
/// command-injection test, where the server must observe that the client
/// refused to write a single byte and therefore has no line to answer.
struct MockRule {
  verb : String
  reply : String?
}

///|
/// A scripted FTP server bound to a loopback port.
///
/// The server accepts exactly one connection (like upstream's mock) and runs
/// on a background task. Received command verbs are appended to `commands`,
/// The received command verbs are appended to `commands`, so a test can tell a
/// bare verb (`LIST`) from a verb with arguments (`LIST -a`) by looking at the
/// recorded line.
struct MockServer {
  server : @socket.TcpServer
  rules : Array[MockRule]
  fallback : String?
  commands : Array[String]
}

///|
/// Start a server on an ephemeral loopback port.
///
/// `rules` are matched by verb, first hit wins; a verb with no rule is
/// answered with `fallback` (a `nil` fallback leaves the client hanging, which
/// is what a test wants when it asserts a timeout or a silent refusal).
async fn MockServer::start(
  rules : Array[MockRule],
  fallback? : String? = None,
) -> MockServer {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  { server, rules, fallback, commands: [], }
}

///|
/// The address the client should dial.
fn MockServer::addr(self : MockServer) -> @socket.Addr {
  self.server.addr
}

///|
/// Serve one connection until the peer closes it.
///
/// Scripted replies are written verbatim, so the caller controls the CRLF
/// placement and therefore exactly how many lines each reply spans.
async fn MockServer::serve_one(self : MockServer) -> Unit {
  let (conn, _) = self.server.accept()
  defer conn.close()
  write_mock_reply(conn, Some("220 FTP Server ready."))
  while conn.read_until("\r\n") is Some(line) {
    let verb = match line.split(" ").next() {
      Some(verb) => verb.to_owned()
      None => line
    }
    self.commands.push(verb)
    match self.reply_for(verb) {
      Some(reply) => write_mock_reply(conn, Some(reply))
      None =>
        // No script for this verb: leave the peer waiting, and stop reading
        // rather than spin on a socket we will never answer.
        break
    }
  }
}

///|
/// The raw reply scripted for `verb`, if any.
fn MockServer::reply_for(self : MockServer, verb : String) -> String? {
  for rule in self.rules {
    if rule.verb == verb {
      return rule.reply
    }
  }
  self.fallback
}

///|
/// Write one scripted reply, then terminate the line with CRLF.
async fn write_mock_reply(conn : @socket.Tcp, reply : String?) -> Unit {
  match reply {
    Some(reply) => conn.write(reply + "\r\n")
    None => ()
  }
}

///|
/// The command verbs the server received, in order.
fn MockServer::commands(self : MockServer) -> Array[String] {
  self.commands.copy()
}

///|
/// Whether the server ever received a command line.
fn MockServer::saw_any_command(self : MockServer) -> Bool {
  self.commands.length() > 0
}

///|
/// Build a rule list from `[(verb, reply)]` pairs.
fn mock_rules(rules : Array[(String, String)]) -> Array[MockRule] {
  rules.map(pair => { verb: pair.0, reply: Some(pair.1), })
}
