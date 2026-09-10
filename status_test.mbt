// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

///|
test "status text for known codes" {
  assert_eq(status_text(220), "Service ready for new user.")
  assert_eq(status_text(430), "Invalid username or password.")
  assert_eq(status_text(226), "Closing data connection.")
}

///|
test "status text for unknown codes uses the fixed format" {
  assert_eq(status_text(0), "Unknown status code: 0")
  assert_eq(status_text(999), "Unknown status code: 999")
}

///|
test "positive completion and intermediate predicates" {
  assert_true(is_positive_completion(200))
  assert_true(is_positive_completion(250))
  assert_false(is_positive_completion(150))
  assert_false(is_positive_completion(350))
  assert_true(is_positive_intermediate(150))
  assert_false(is_positive_intermediate(226))
}
