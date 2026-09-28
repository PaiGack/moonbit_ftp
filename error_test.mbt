// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "every ftp error variant can be built and pattern matched" {
  let server : Error = @ftp.FtpError::ServerError(code=550, msg="no such file")
  match server {
    @ftp.FtpError::ServerError(code~, msg~) => {
      assert_eq(code, 550)
      assert_eq(msg, "no such file")
    }
    _ => fail("expected ServerError")
  }
  let invalid : Error = @ftp.FtpError::InvalidCommand(arg="a\r\nb")
  match invalid {
    @ftp.FtpError::InvalidCommand(arg~) => assert_eq(arg, "a\r\nb")
    _ => fail("expected InvalidCommand")
  }
  let line : Error = @ftp.FtpError::UnsupportedListLine(line="garbage")
  match line {
    @ftp.FtpError::UnsupportedListLine(line~) => assert_eq(line, "garbage")
    _ => fail("expected UnsupportedListLine")
  }
  let date : Error = @ftp.FtpError::UnsupportedListDate(field="Foo 10")
  match date {
    @ftp.FtpError::UnsupportedListDate(field~) => assert_eq(field, "Foo 10")
    _ => fail("expected UnsupportedListDate")
  }
  let parse : Error = @ftp.FtpError::ParseError(msg="bad epsv")
  match parse {
    @ftp.FtpError::ParseError(msg~) => assert_eq(msg, "bad epsv")
    _ => fail("expected ParseError")
  }
}

///|
test "join_errors collapses the trivial cases" {
  assert_true(@ftp.join_errors([]) is None)
  let single = @ftp.join_errors([@ftp.FtpError::ParseError(msg="one")])
  match single {
    Some(@ftp.FtpError::ParseError(msg~)) => assert_eq(msg, "one")
    _ => fail("expected the single error to bubble up unwrapped")
  }
  let many = @ftp.join_errors([
    @ftp.FtpError::ParseError(msg="one"),
    @ftp.FtpError::ParseError(msg="two"),
  ])
  match many {
    Some(@ftp.FtpErrors::MultipleErrors(errors~)) =>
      assert_eq(errors.length(), 2)
    _ => fail("expected MultipleErrors")
  }
}

///|
test "flatten_errors exposes every aggregated error" {
  let aggregate : Error = @ftp.FtpErrors::MultipleErrors(errors=[
    @ftp.FtpError::ParseError(msg="one"),
    @ftp.FtpError::ParseError(msg="two"),
  ])
  assert_eq(@ftp.flatten_errors(aggregate).length(), 2)
  assert_eq(
    @ftp.flatten_errors(@ftp.FtpError::ParseError(msg="one")).length(),
    1,
  )
}
