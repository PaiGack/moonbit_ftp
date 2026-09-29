// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "entry type to_string matches the Go spelling" {
  assert_eq(@ftp.EntryType::File.to_string(), "file")
  assert_eq(@ftp.EntryType::Folder.to_string(), "folder")
  assert_eq(@ftp.EntryType::Link.to_string(), "link")
}

///|
test "transfer type renders as the TYPE argument" {
  assert_eq(@ftp.TransferType::Binary.to_string(), "I")
  assert_eq(@ftp.TransferType::ASCII.to_string(), "A")
}

///|
test "make_entry defaults to an empty target, zero size and the epoch" {
  let entry = @ftp.make_entry("lo", @ftp.EntryType::File)
  assert_eq(entry.name, "lo")
  assert_eq(entry.target, "")
  assert_eq(entry.type_, @ftp.EntryType::File)
  assert_eq(entry.size, 0UL)
  assert_eq(entry.time.to_unix_second(), 0L)
}

///|
test "entry setters let parsers fill an entry in" {
  let entry = @ftp.make_entry("", @ftp.EntryType::File)
  entry.set_name("pub")
  entry.set_type(@ftp.EntryType::Folder)
  entry.set_size(42UL)
  entry.set_target("usr/bin")
  assert_eq(entry.name, "pub")
  assert_eq(entry.type_, @ftp.EntryType::Folder)
  assert_eq(entry.size, 42UL)
  assert_eq(entry.target, "usr/bin")
}

///|
test "entry constructors cover all three entry types" {
  let folder = @ftp.make_folder("pub")
  assert_eq(folder.type_, @ftp.EntryType::Folder)
  let link = @ftp.make_link("bin", "usr/bin")
  assert_eq(link.type_, @ftp.EntryType::Link)
  assert_eq(link.target, "usr/bin")
  let file = @ftp.make_entry("message.ftp", @ftp.EntryType::File)
  assert_eq(file.type_, @ftp.EntryType::File)
}

///|
/// `TransferType::from_string` is the inverse of `to_string`, and it is what a
/// caller round-tripping a `TYPE` argument back into the enum relies on.
test "transfer type parses back from its TYPE argument" {
  assert_true(
    @ftp.TransferType::from_string("I") is Some(@ftp.TransferType::Binary),
  )
  assert_true(
    @ftp.TransferType::from_string("A") is Some(@ftp.TransferType::ASCII),
  )
  // Case insensitive, because servers echo the uppercase form and callers
  // should not have to care.
  assert_true(
    @ftp.TransferType::from_string("i") is Some(@ftp.TransferType::Binary),
  )
  assert_true(
    @ftp.TransferType::from_string("a") is Some(@ftp.TransferType::ASCII),
  )
}

///|
test "transfer type rejects anything that is not a TYPE code" {
  assert_true(@ftp.TransferType::from_string("") is None)
  assert_true(@ftp.TransferType::from_string("E") is None)
  assert_true(@ftp.TransferType::from_string("binary") is None)
  assert_true(@ftp.TransferType::from_string("A ") is None)
}

///|
/// `argument` is the spelling that reads better at a call site; it must agree
/// with `to_string`, which is what actually goes on the wire.
test "transfer type argument is its wire spelling" {
  assert_eq(@ftp.TransferType::Binary.argument(), "I")
  assert_eq(@ftp.TransferType::ASCII.argument(), "A")
  assert_eq(
    @ftp.TransferType::Binary.argument(),
    @ftp.TransferType::Binary.to_string(),
  )
}

///|
/// The shared `epoch` constant is what an entry gets when a listing carries no
/// usable timestamp; it must be Unix second zero in UTC.
test "epoch is the unix epoch in UTC" {
  assert_eq(@ftp.epoch.to_unix_second(), 0L)
  assert_eq(@ftp.epoch.year(), 1970)
  assert_eq(@ftp.epoch.month(), 1)
  assert_eq(@ftp.epoch.day(), 1)
}
