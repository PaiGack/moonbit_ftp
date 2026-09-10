// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "entry type to_string matches the Go spelling" {
  assert_eq(EntryType::File.to_string(), "file")
  assert_eq(EntryType::Folder.to_string(), "folder")
  assert_eq(EntryType::Link.to_string(), "link")
}

///|
test "transfer type renders as the TYPE argument" {
  assert_eq(TransferType::Binary.to_string(), "I")
  assert_eq(TransferType::ASCII.to_string(), "A")
}

///|
test "make_entry defaults to an empty target, zero size and the epoch" {
  let entry = make_entry("lo", EntryType::File)
  assert_eq(entry.name, "lo")
  assert_eq(entry.target, "")
  assert_eq(entry.type_, EntryType::File)
  assert_eq(entry.size, 0UL)
  assert_eq(entry.time.to_unix_second(), 0L)
}

///|
test "entry setters let parsers fill an entry in" {
  let entry = make_entry("", EntryType::File)
  entry.set_name("pub")
  entry.set_type(EntryType::Folder)
  entry.set_size(42UL)
  entry.set_target("usr/bin")
  assert_eq(entry.name, "pub")
  assert_eq(entry.type_, EntryType::Folder)
  assert_eq(entry.size, 42UL)
  assert_eq(entry.target, "usr/bin")
}

///|
test "entry constructors cover all three entry types" {
  let folder = make_folder("pub")
  assert_eq(folder.type_, EntryType::Folder)
  let link = make_link("bin", "usr/bin")
  assert_eq(link.type_, EntryType::Link)
  assert_eq(link.target, "usr/bin")
  let file = make_entry("message.ftp", EntryType::File)
  assert_eq(file.type_, EntryType::File)
}
