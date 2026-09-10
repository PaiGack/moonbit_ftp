// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

///|
/// The kind of a remote directory entry, mirroring upstream
/// `ftp.EntryType`.
pub(all) enum EntryType {
  /// A regular file.
  File
  /// A directory.
  Folder
  /// A symbolic link.
  Link
} derive(Eq, @debug.Debug)

///|
/// Return the lowercase name of the entry type, matching the string form used
/// by the Go implementation (`file` / `folder` / `link`).
pub fn EntryType::to_string(self : EntryType) -> String {
  match self {
    File => "file"
    Folder => "folder"
    Link => "link"
  }
}

///|
/// A single remote directory entry.
///
/// Mirroring upstream `ftp.Entry`:
/// - `target` is empty for non-symlinks (Go zero value semantics),
/// - `time` carries an explicit timezone because `LIST` timestamps are
///   wall-clock time in the **server's** timezone.
pub struct Entry {
  /// File name without any leading path component.
  mut name : String
  /// Symbolic link target, empty string when the entry is not a link.
  mut target : String
  /// Kind of the entry.
  mut type_ : EntryType
  /// Size in bytes, `UInt64` because servers do report values above `Int64`.
  mut size : UInt64
  /// Parsed modification time, timezone included.
  mut time : @time.ZonedDateTime
} derive(@debug.Debug)

///|
/// Build an entry with the given name and type; the target defaults to the
/// empty string and the time to the epoch in UTC, both of which the parsers
/// overwrite when the server supplies the information.
pub fn make_entry(
  name : String,
  type_ : EntryType,
  time? : @time.ZonedDateTime,
) -> Entry {
  let timestamp = match time {
    Some(time) => time
    None => epoch
  }
  { name, target: "", type_, size: 0, time: timestamp, }
}

///|
/// The UNIX epoch, a convenient zero value for `Entry::time`.
///
/// `@time.ZonedDateTime::from_unix_second` raises, which is awkward in pure
/// parsers, so the fallback lives here where the failure path can be handled
/// exactly once.
pub let epoch : @time.ZonedDateTime = @time.ZonedDateTime::from_unix_second(
  0,
  zone=@time.utc_zone,
) catch {
  _ => panic()
}

///|
/// Replace the name of an entry in place.
pub fn Entry::set_name(self : Entry, name : String) -> Unit {
  self.name = name
}

///|
/// Replace the symlink target of an entry in place.
pub fn Entry::set_target(self : Entry, target : String) -> Unit {
  self.target = target
}

///|
/// Replace the kind of an entry in place.
pub fn Entry::set_type(self : Entry, type_ : EntryType) -> Unit {
  self.type_ = type_
}

///|
/// Replace the size of an entry in place.
pub fn Entry::set_size(self : Entry, size : UInt64) -> Unit {
  self.size = size
}

///|
/// Replace the modification time of an entry in place.
pub fn Entry::set_time(self : Entry, time : @time.ZonedDateTime) -> Unit {
  self.time = time
}

///|
/// Build a plain file entry, the most common shape.
pub fn make_file(name : String, time? : @time.ZonedDateTime) -> Entry {
  make_entry(name, EntryType::File, time?)
}

///|
/// Parse a `TYPE` command argument back into a `TransferType`, the inverse of
/// `TransferType::to_string`.
pub fn TransferType::from_string(value : String) -> TransferType? {
  match value.to_upper() {
    "I" => Some(Binary)
    "A" => Some(ASCII)
    _ => None
  }
}

///|
/// The FTP `TYPE` argument, an alias of `to_string` that reads better at the
/// call site.
pub fn TransferType::argument(self : TransferType) -> String {
  self.to_string()
}

///|
/// Build a folder entry, the shape used by the `walker` root marker.
pub fn make_folder(name : String, time? : @time.ZonedDateTime) -> Entry {
  make_entry(name, EntryType::Folder, time?)
}

///|
/// Build a link entry with the given target.
pub fn make_link(
  name : String,
  target : String,
  time? : @time.ZonedDateTime,
) -> Entry {
  let entry = make_entry(name, EntryType::Link, time?)
  entry.target = target
  entry
}

///|
/// The transfer type of the data connection, matching the FTP `TYPE` command
/// arguments.
pub(all) enum TransferType {
  /// `TYPE I`, binary transfer (also called image type).
  Binary
  /// `TYPE A`, ASCII transfer.
  ASCII
} derive(Eq, @debug.Debug)

///|
/// The argument string sent with the `TYPE` command.
pub fn TransferType::to_string(self : TransferType) -> String {
  match self {
    Binary => "I"
    ASCII => "A"
  }
}
