// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.

// The status code table and the reply-code predicates.
//
// `status.mbt` is pure and its whole surface is two functions over the RFC 959
// table, so the only thing worth pinning is that *every* code answers with the
// upstream text: a typo in the table is exactly the kind of bug that only shows
// up in a user's error message, and no other test can see it.

///|
test "status text for known codes" {
  assert_eq(@ftp.status_text(220), "Service ready for new user.")
  assert_eq(@ftp.status_text(430), "Invalid username or password.")
  assert_eq(@ftp.status_text(226), "Closing data connection.")
}

///|
test "status text for unknown codes uses the fixed format" {
  assert_eq(@ftp.status_text(0), "Unknown status code: 0")
  assert_eq(@ftp.status_text(999), "Unknown status code: 999")
}

///|
test "positive completion and intermediate predicates" {
  assert_true(@ftp.is_positive_completion(200))
  assert_true(@ftp.is_positive_completion(250))
  assert_false(@ftp.is_positive_completion(150))
  assert_false(@ftp.is_positive_completion(350))
  assert_true(@ftp.is_positive_intermediate(150))
  assert_false(@ftp.is_positive_intermediate(226))
}

///|
/// The whole table, one line per case. Copied from upstream `status.go`; a
/// wrong string here means a user reads the wrong error message.
test "every documented status code has its upstream text" {
  let cases : Array[(Int, String)] = [
    (110, "Restart marker reply."),
    (120, "Service ready in 2 minutes."),
    (125, "Data connection already open, transfer starting."),
    (150, "File status okay, about to open data connection."),
    (200, "Command okay."),
    (202, "Command not implemented, superfluous at this site."),
    (211, "System status."),
    (212, "Directory status."),
    (213, "File status."),
    (214, "Help message."),
    (215, "NAME system type."),
    (220, "Service ready for new user."),
    (221, "Service closing control connection."),
    (225, "Data connection open, no transfer in progress."),
    (226, "Closing data connection."),
    (227, "Entering Passive Mode."),
    (229, "Entering Extended Passive Mode."),
    (230, "User logged in, proceed."),
    (234, "Authentication successful."),
    (250, "Requested file action okay, completed."),
    (257, "PATHNAME created."),
    (331, "Username okay, need password."),
    (332, "Need account for login."),
    (350, "Requested file action pending further information."),
    (421, "Service not available, closing control connection."),
    (425, "Can't open data connection."),
    (426, "Connection closed, transfer aborted."),
    (430, "Invalid username or password."),
    (450, "Requested file action not taken."),
    (451, "Requested action aborted, local error in processing."),
    (452, "Requested action not taken, insufficient storage space."),
    (500, "Syntax error, command unrecognized."),
    (501, "Syntax error in parameters or arguments."),
    (502, "Command not implemented."),
    (503, "Bad sequence of commands."),
    (504, "Command not implemented for that parameter."),
    (530, "Not logged in."),
    (532, "Need account for storing files."),
    (550, "Requested action not taken."),
    (551, "Requested action aborted, page type unknown."),
    (552, "Requested file action aborted, exceeded storage allocation."),
    (553, "Requested action not taken, file name not allowed."),
  ]
  for pair in cases {
    let (code, text) = pair
    assert_eq(@ftp.status_text(code), text)
  }
}

///|
/// The predicates must be exact at both boundaries: `200` is the first
/// completion and `300` is out; `100` is the first intermediate and `200` is
/// out. All four edges are load bearing — `cmd_data_conn_from` accepts a
/// transfer reply with `is_positive_intermediate`, and getting the lower edge
/// wrong is what made it reject every real transfer once.
test "the reply code predicates exclude both boundaries of the next class" {
  assert_true(@ftp.is_positive_intermediate(100))
  assert_true(@ftp.is_positive_intermediate(199))
  assert_false(@ftp.is_positive_intermediate(200))
  assert_true(@ftp.is_positive_completion(200))
  assert_true(@ftp.is_positive_completion(299))
  assert_false(@ftp.is_positive_completion(300))
  // 3xx / 4xx / 5xx are neither, which is what makes a failure bubble up.
  assert_false(@ftp.is_positive_completion(350))
  assert_false(@ftp.is_positive_completion(450))
  assert_false(@ftp.is_positive_completion(550))
  assert_false(@ftp.is_positive_intermediate(550))
}

///|
/// The exported constants must keep the numeric values the protocol uses:
/// several names intentionally share one code (the RFCs overload them), and
/// the duplicates are the part most likely to be "cleaned up" by mistake.
test "the exported status constants keep their numeric values" {
  assert_eq(@ftp.status_restart_marker_answer, 110)
  assert_eq(@ftp.status_restart_marker_reply, 120)
  assert_eq(@ftp.status_data_conn_already_in_use, 125)
  assert_eq(@ftp.status_closing_control_connection, 221)
  assert_eq(@ftp.status_closing_data_connection, 226)
  assert_eq(@ftp.status_auth_ok, 234)
  assert_eq(@ftp.status_file_action_ok, 250)
  assert_eq(@ftp.status_dir_create, 257)
  assert_eq(@ftp.status_user_logged_in_proceed, 230)
  assert_eq(@ftp.status_username_ok_need_password, 331)
  assert_eq(@ftp.status_file_action_pending_further_info, 350)
  assert_eq(@ftp.status_service_ready_for_new_user, 220)
  assert_eq(@ftp.status_session_opened_data_connection, 225)
  assert_eq(@ftp.status_data_connection_open_no_transfer, 200)
  assert_eq(@ftp.status_cmd_ok, 200)
  assert_eq(@ftp.status_cmd_not_implemented_superfluous, 202)
  assert_eq(@ftp.status_system_status, 211)
  assert_eq(@ftp.status_dir_status, 212)
  assert_eq(@ftp.status_file_status, 213)
  assert_eq(@ftp.status_help_message, 214)
  assert_eq(@ftp.status_name_status, 215)
  assert_eq(@ftp.status_service_ready_soon, 120)
  assert_eq(@ftp.status_data_connection_already_open, 125)
  assert_eq(@ftp.status_enter_passive_mode, 227)
  assert_eq(@ftp.status_enter_extended_passive_mode, 229)
  assert_eq(@ftp.status_entering_passive_mode_from_ip, 227)
  assert_eq(@ftp.status_enter_port, 200)
  assert_eq(@ftp.status_enter_extended_port, 200)
  assert_eq(@ftp.status_username_ok, 331)
  assert_eq(@ftp.status_need_account_for_login, 332)
  assert_eq(@ftp.status_file_action_not_taken, 450)
  assert_eq(@ftp.status_file_action_aborted, 550)
  assert_eq(@ftp.status_restart_marker_not_understood, 501)
  assert_eq(@ftp.status_service_unavailable, 421)
  assert_eq(@ftp.status_cannot_open_data_connection, 425)
  assert_eq(@ftp.status_transfer_aborted, 426)
  assert_eq(@ftp.status_file_action_aborted_local_error, 451)
  assert_eq(@ftp.status_syntax_error_unknown_cmd, 500)
  assert_eq(@ftp.status_syntax_error_unknown_params, 501)
  assert_eq(@ftp.status_not_implemented, 502)
  assert_eq(@ftp.status_not_implemented_for_param, 504)
  assert_eq(@ftp.status_not_logged_in, 530)
  assert_eq(@ftp.status_need_account, 532)
  assert_eq(@ftp.status_request_denied, 550)
  assert_eq(@ftp.status_page_type_unknown, 551)
  assert_eq(@ftp.status_exceeded_storage_allocation, 552)
  assert_eq(@ftp.status_action_not_taken, 450)
  assert_eq(@ftp.status_bad_filename, 553)
}

///|
/// The default dial timeout is upstream's 30 seconds, the value `dial` uses
/// when the caller passes nothing.
test "the default dial timeout is thirty seconds" {
  assert_eq(@ftp.default_dial_timeout_ms, 30000)
}
