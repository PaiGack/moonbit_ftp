// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
//
// White box tests: the fields of `Entry` are only assignable from inside the
// package, which is exactly how the parsers fill in a partially known entry.

///|
test "white box: entry fields can be assigned in place" {
  let entry : Entry = {
    name: "",
    target: "",
    type_: EntryType::File,
    size: 0UL,
    time: @time.ZonedDateTime::from_unix_second(0, zone=@time.utc_zone),
  }
  entry.name = "welcome.msg"
  entry.target = "usr/bin"
  entry.type_ = EntryType::Link
  entry.size = 951UL
  assert_eq(entry.name, "welcome.msg")
  assert_eq(entry.target, "usr/bin")
  assert_eq(entry.type_, EntryType::Link)
  assert_eq(entry.size, 951UL)
}

///|
test "white box: white box scope also sees the enum constructors" {
  let entry = make_entry("lo", EntryType::File)
  entry.type_ = EntryType::Folder
  entry.name = "pub"
  assert_eq(entry.type_.to_string(), "folder")
  assert_eq(TransferType::Binary.to_string(), "I")
  assert_eq(TransferType::ASCII.to_string(), "A")
  assert_eq(entry.name, "pub")
}
