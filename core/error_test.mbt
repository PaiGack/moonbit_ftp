// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "every ftp error variant can be built and pattern matched" {
  let server : Error = @core.FtpError::ServerError(code=550, msg="no such file")
  match server {
    @core.FtpError::ServerError(code~, msg~) => {
      assert_eq(code, 550)
      assert_eq(msg, "no such file")
    }
    _ => fail("expected ServerError")
  }
  let invalid : Error = @core.FtpError::InvalidCommand(arg="a\r\nb")
  match invalid {
    @core.FtpError::InvalidCommand(arg~) => assert_eq(arg, "a\r\nb")
    _ => fail("expected InvalidCommand")
  }
  let line : Error = @core.FtpError::UnsupportedListLine(line="garbage")
  match line {
    @core.FtpError::UnsupportedListLine(line~) => assert_eq(line, "garbage")
    _ => fail("expected UnsupportedListLine")
  }
  let date : Error = @core.FtpError::UnsupportedListDate(field="Foo 10")
  match date {
    @core.FtpError::UnsupportedListDate(field~) => assert_eq(field, "Foo 10")
    _ => fail("expected UnsupportedListDate")
  }
  let parse : Error = @core.FtpError::ParseError(msg="bad epsv")
  match parse {
    @core.FtpError::ParseError(msg~) => assert_eq(msg, "bad epsv")
    _ => fail("expected ParseError")
  }
}

///|
test "join_errors collapses the trivial cases" {
  assert_true(@core.join_errors([]) is None)
  let single = @core.join_errors([@core.FtpError::ParseError(msg="one")])
  match single {
    Some(@core.FtpError::ParseError(msg~)) => assert_eq(msg, "one")
    _ => fail("expected the single error to bubble up unwrapped")
  }
  let many = @core.join_errors([
    @core.FtpError::ParseError(msg="one"),
    @core.FtpError::ParseError(msg="two"),
  ])
  match many {
    Some(@core.FtpErrors::MultipleErrors(errors~)) =>
      assert_eq(errors.length(), 2)
    _ => fail("expected MultipleErrors")
  }
}

///|
test "flatten_errors exposes every aggregated error" {
  let aggregate : Error = @core.FtpErrors::MultipleErrors(errors=[
    @core.FtpError::ParseError(msg="one"),
    @core.FtpError::ParseError(msg="two"),
  ])
  assert_eq(@core.flatten_errors(aggregate).length(), 2)
  assert_eq(
    @core.flatten_errors(@core.FtpError::ParseError(msg="one")).length(),
    1,
  )
}
