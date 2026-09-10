// Copyright 2026 PaiGack
// Licensed under the Apache License, Version 2.0.
// Ported from jlaffaye/ftp (ISC License), see LICENSE-THIRD-PARTY.

// Layer: pure logic — no IO, no `moonbitlang/async` dependency.

// RFC 959 / RFC 2228 / RFC 2428 / RFC 3659 status codes and the constants
// the client shares with them.
//
// This file merges `status` and `consts`: both are plain protocol constants
// (status codes and the dial timeout), they never changed apart, and keeping
// them together makes the "where do I find the protocol constants" question
// have one answer.

///|
/// RFC 959 / RFC 2228 / RFC 2428 / RFC 3659 status codes.
///
/// Values are kept byte-for-byte identical to upstream `status.go`. Several
/// distinct constants intentionally share the same numeric value (the RFCs
/// overload the code), which is fine because they are plain `Int` constants.
pub let status_restart_marker_answer : Int = 110

///|
pub let status_restart_marker_reply : Int = 120

///|
pub let status_data_conn_already_in_use : Int = 125

///|
/// `221 Service closing control connection.` — the answer to `QUIT`.
pub let status_closing_control_connection : Int = 221

///|
pub let status_closing_data_connection : Int = 226

///|
pub let status_auth_ok : Int = 234

///|
pub let status_file_action_ok : Int = 250

///|
pub let status_dir_create : Int = 257

///|
pub let status_user_logged_in_proceed : Int = 230

///|
pub let status_username_ok_need_password : Int = 331

///|
pub let status_file_action_pending_further_info : Int = 350

///|
pub let status_service_ready_for_new_user : Int = 220

///|
pub let status_session_opened_data_connection : Int = 225

///|
pub let status_data_connection_open_no_transfer : Int = 200

///|
pub let status_cmd_ok : Int = 200

///|
pub let status_cmd_not_implemented_superfluous : Int = 202

///|
pub let status_system_status : Int = 211

///|
pub let status_dir_status : Int = 212

///|
pub let status_file_status : Int = 213

///|
pub let status_help_message : Int = 214

///|
pub let status_name_status : Int = 215

///|
pub let status_service_ready_soon : Int = 120

///|
pub let status_data_connection_already_open : Int = 125

///|
pub let status_enter_passive_mode : Int = 227

///|
pub let status_enter_extended_passive_mode : Int = 229

///|
pub let status_entering_passive_mode_from_ip : Int = 227

///|
pub let status_enter_port : Int = 200

///|
pub let status_enter_extended_port : Int = 200

///|
pub let status_username_ok : Int = 331

///|
pub let status_need_account_for_login : Int = 332

///|
pub let status_file_action_not_taken : Int = 450

///|
pub let status_file_action_aborted : Int = 550

///|
pub let status_restart_marker_not_understood : Int = 501

///|
pub let status_service_unavailable : Int = 421

///|
pub let status_cannot_open_data_connection : Int = 425

///|
pub let status_transfer_aborted : Int = 426

///|
pub let status_file_action_aborted_local_error : Int = 451

///|
pub let status_syntax_error_unknown_cmd : Int = 500

///|
pub let status_syntax_error_unknown_params : Int = 501

///|
pub let status_not_implemented : Int = 502

///|
pub let status_not_implemented_for_param : Int = 504

///|
pub let status_not_logged_in : Int = 530

///|
pub let status_need_account : Int = 532

///|
pub let status_request_denied : Int = 550

///|
pub let status_page_type_unknown : Int = 551

///|
pub let status_exceeded_storage_allocation : Int = 552

///|
pub let status_action_not_taken : Int = 450

///|
pub let status_bad_filename : Int = 553

///|
/// The human readable text for every known status code, copied from
/// upstream `status.go` (no localization on purpose).
pub fn status_text(code : Int) -> String {
  match code {
    110 => "Restart marker reply."
    120 => "Service ready in 2 minutes."
    125 => "Data connection already open, transfer starting."
    150 => "File status okay, about to open data connection."
    200 => "Command okay."
    202 => "Command not implemented, superfluous at this site."
    211 => "System status."
    212 => "Directory status."
    213 => "File status."
    214 => "Help message."
    215 => "NAME system type."
    220 => "Service ready for new user."
    221 => "Service closing control connection."
    225 => "Data connection open, no transfer in progress."
    226 => "Closing data connection."
    227 => "Entering Passive Mode."
    229 => "Entering Extended Passive Mode."
    230 => "User logged in, proceed."
    234 => "Authentication successful."
    250 => "Requested file action okay, completed."
    257 => "PATHNAME created."
    331 => "Username okay, need password."
    332 => "Need account for login."
    350 => "Requested file action pending further information."
    421 => "Service not available, closing control connection."
    425 => "Can't open data connection."
    426 => "Connection closed, transfer aborted."
    430 => "Invalid username or password."
    450 => "Requested file action not taken."
    451 => "Requested action aborted, local error in processing."
    452 => "Requested action not taken, insufficient storage space."
    500 => "Syntax error, command unrecognized."
    501 => "Syntax error in parameters or arguments."
    502 => "Command not implemented."
    503 => "Bad sequence of commands."
    504 => "Command not implemented for that parameter."
    530 => "Not logged in."
    532 => "Need account for storing files."
    550 => "Requested action not taken."
    551 => "Requested action aborted, page type unknown."
    552 => "Requested file action aborted, exceeded storage allocation."
    553 => "Requested action not taken, file name not allowed."
    _ => "Unknown status code: \{code}"
  }
}

///|
/// Whether the code is a 2xx "positive completion" reply.
pub fn is_positive_completion(code : Int) -> Bool {
  code >= 200 && code < 300
}

///|
/// Whether the code is a 1xx "positive intermediate" reply.
pub fn is_positive_intermediate(code : Int) -> Bool {
  code >= 100 && code < 200
}

///|
/// Default timeout used when dialing a server, in milliseconds
/// (upstream `ftp.DefaultDialTimeout`, 30s).
pub let default_dial_timeout_ms : Int = 30 * 1000
