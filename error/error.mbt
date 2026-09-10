// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// Error type for every failure that is produced by the FTP protocol layer
/// itself (as opposed to failures raised by the underlying IO stack, which
/// bubble up untouched so callers can still inspect the OS error).
pub(all) suberror FtpError {
  /// The server answered with a status code we did not expect.
  ServerError(code~ : Int, msg~ : String)
  /// A command argument contains `\r` or `\n` and was refused before any
  /// byte reached the socket (command injection guard).
  InvalidCommand(arg~ : String)
  /// A `LIST` line could not be recognised by any of the four parsers.
  UnsupportedListLine(line~ : String)
  /// A date field inside a `LIST` line has an unrecognised shape.
  UnsupportedListDate(field~ : String)
  /// Generic parsing failure, carries the underlying reason.
  ParseError(msg~ : String)
} derive(@debug.Debug)

///|
/// Aggregation of several failures that happened during one logical
/// operation. This mirrors Go's `errors.Join`: the upstream implementation
/// deliberately keeps *every* error (transfer + close + status read) instead
/// of returning as soon as the first one shows up.
pub(all) suberror FtpErrors {
  /// All errors of a single operation, in the order they occurred.
  MultipleErrors(errors~ : Array[Error])
} derive(@debug.Debug)

///|
/// Build an aggregated error, collapsing the trivial cases so callers do not
/// have to care about them:
/// - no error at all -> `None`
/// - exactly one error -> that error itself
/// - otherwise -> `FtpErrors::MultipleErrors`
pub fn join_errors(errors : Array[Error]) -> Error? {
  match errors {
    [] => None
    [e] => Some(e)
    _ => Some(FtpErrors::MultipleErrors(errors~))
  }
}

///|
/// Return every error carried by an aggregate, or the error itself when it is
/// not an aggregate. Useful for tests and for re-raising partial failures.
pub fn flatten_errors(err : Error) -> Array[Error] {
  match err {
    FtpErrors::MultipleErrors(errors~) => errors
    _ => [err]
  }
}
