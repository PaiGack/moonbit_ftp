// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Package: `PaiGack/ftp/core` — pure values and parsers, no IO.

// Property tests over hostile input.
//
// Every listing line and every control-channel token this module parses comes
// from a server, i.e. from a peer the client does not control. The parsers are
// hand-written byte scanners full of offsets, `unsafe_get` and slicing, so the
// contract they have to keep is a *total* one: for any input, return a value
// or raise `FtpError` -- never panic, never read past the end, never loop.
//
// The input is a `String` whose characters are biased towards the bytes that
// make byte slicing go wrong: ASCII (the separators `; = - : ( ) / . ,` and
// digits, which every grammar keys on) three times out of four, and arbitrary
// Unicode scalar values the rest -- which is where a byte offset can land
// inside a multi-byte sequence. `@quickcheck`'s built-in `String` generator
// applies exactly that bias, so no custom `Arbitrary` impl is needed: the
// orphan rule would require that impl to live in `quickcheck`, not here.
//
// Sizes are small on purpose: the bugs these parsers can have are off-by-one
// and boundary reads, not quadratic blowups, and a short line reaches them
// just as well as a long one.

///|
/// A reference instant, fixed so the six-month rule cannot make a property
/// depend on when the suite runs.
fn fuzz_now() -> @time.ZonedDateTime {
  @core.new_datetime(2024, 6, 15, 12, 0, @time.utc_zone) catch {
    _ => @core.epoch
  }
}

///|
/// `parse_list_line` is total over arbitrary text: it either reports which
/// grammar matched or raises, and never panics. The four parsers underneath
/// are reached through it, so this covers them all with one property.
test "parse_list_line is total over arbitrary input" {
  @quickcheck.check(
    fn(line : String) -> Bool {
      try {
        let (entry, _) = @core.parse_list_line(line, fuzz_now())
        // A parsed name can never be longer than the line it came from.
        entry.name.length() <= line.length()
      } catch {
        _ => true
      }
    },
    count=1000,
    max_size=40,
    seed=20261113,
  )
}

///|
/// Each parser on its own, including the ones `parse_list_line` only reaches
/// after the earlier grammar declines, plus the helpers that take a raw offset
/// (`parse_ls_time(line, 0, now)`, `find_date_start_pub`). Surviving the call
/// is the property: an uncaught panic fails the test.
test "every list parser is total over arbitrary input" {
  @quickcheck.check(
    fn(line : String) -> Bool {
      let now = fuzz_now()
      ignore(@core.parse_rfc3659_line(line) catch { _ => None })
      ignore(@core.parse_ls_line(line, now) catch { _ => None })
      ignore(@core.parse_dos_dir_line(line, now) catch { _ => None })
      ignore(@core.parse_hostedftp_line(line, now) catch { _ => None })
      ignore(@core.parse_ls_time(line, 0, now) catch { _ => None })
      ignore(@core.parse_list_date_field(line, 0))
      ignore(@core.find_date_start_pub(line, 0))
      ignore(@core.parse_month(line))
      ignore(@core.join(line, line))
      ignore(@core.join_all([line, line]))
      ignore(@core.parse_code(line))
      ignore(@core.is_continuation(line))
      true
    },
    count=1000,
    max_size=40,
    seed=20261114,
  )
}

///|
/// `set_size` feeds both the `LIST` size column and `SIZE` replies. A wrapped
/// size is a wrong file length nobody can notice, so the property is that it
/// either yields a value or raises -- and that a clean decimal never fails.
test "set_size is total and keeps clean decimals exact" {
  @quickcheck.check(
    fn(text : String) -> Bool {
      let ok = try {
        ignore(@core.set_size(text))
        true
      } catch {
        _ => true
      }
      let decimal = Some(@core.set_size("123456789")) catch { _ => None }
      ok && decimal == Some(123456789UL)
    },
    count=1000,
    max_size=40,
    seed=20261115,
  )
}
