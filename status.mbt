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
/// The numeric values are kept identical to upstream `status.go`. Several
/// distinct constants intentionally share the same numeric value (the RFCs
/// overload the code), which is fine because they are plain `Int` constants.
/// The *names* are this file's own spelling, not upstream's: upstream has one
/// `StatusFileActionIgnored` for 450, where this file carries both
/// `status_file_action_not_taken` and `status_action_not_taken`, because the
/// two are read in different places and renaming either call site for a
/// constant the client only compares by value would only hide which is which.
/// Nothing here is matched by name across the module boundary, so a spelling
/// difference cannot become a behaviour difference.
pub let status_restart_marker_answer : Int32 = 110

///|
pub let status_restart_marker_reply : Int32 = 120

///|
pub let status_data_conn_already_in_use : Int32 = 125

///|
/// `221 Service closing control connection.` — the answer to `QUIT`.
pub let status_closing_control_connection : Int32 = 221

///|
pub let status_closing_data_connection : Int32 = 226

///|
pub let status_auth_ok : Int32 = 234

///|
pub let status_file_action_ok : Int32 = 250

///|
pub let status_dir_create : Int32 = 257

///|
pub let status_user_logged_in_proceed : Int32 = 230

///|
pub let status_username_ok_need_password : Int32 = 331

///|
pub let status_file_action_pending_further_info : Int32 = 350

///|
pub let status_service_ready_for_new_user : Int32 = 220

///|
pub let status_session_opened_data_connection : Int32 = 225

///|
pub let status_data_connection_open_no_transfer : Int32 = 200

///|
pub let status_cmd_ok : Int32 = 200

///|
pub let status_cmd_not_implemented_superfluous : Int32 = 202

///|
pub let status_system_status : Int32 = 211

///|
pub let status_dir_status : Int32 = 212

///|
pub let status_file_status : Int32 = 213

///|
pub let status_help_message : Int32 = 214

///|
pub let status_name_status : Int32 = 215

///|
pub let status_service_ready_soon : Int32 = 120

///|
pub let status_data_connection_already_open : Int32 = 125

///|
pub let status_enter_passive_mode : Int32 = 227

///|
pub let status_enter_extended_passive_mode : Int32 = 229

///|
pub let status_entering_passive_mode_from_ip : Int32 = 227

///|
pub let status_enter_port : Int32 = 200

///|
pub let status_enter_extended_port : Int32 = 200

///|
pub let status_username_ok : Int32 = 331

///|
pub let status_need_account_for_login : Int32 = 332

///|
pub let status_file_action_not_taken : Int32 = 450

///|
pub let status_file_action_aborted : Int32 = 550

///|
pub let status_restart_marker_not_understood : Int32 = 501

///|
pub let status_service_unavailable : Int32 = 421

///|
pub let status_cannot_open_data_connection : Int32 = 425

///|
pub let status_transfer_aborted : Int32 = 426

///|
pub let status_file_action_aborted_local_error : Int32 = 451

///|
pub let status_syntax_error_unknown_cmd : Int32 = 500

///|
pub let status_syntax_error_unknown_params : Int32 = 501

///|
pub let status_not_implemented : Int32 = 502

///|
pub let status_not_implemented_for_param : Int32 = 504

///|
pub let status_not_logged_in : Int32 = 530

///|
pub let status_need_account : Int32 = 532

///|
pub let status_request_denied : Int32 = 550

///|
pub let status_page_type_unknown : Int32 = 551

///|
pub let status_exceeded_storage_allocation : Int32 = 552

///|
/// The second spelling of 450. See the note in the file header: upstream
/// calls this one `StatusFileActionIgnored`.
pub let status_action_not_taken : Int32 = 450

///|
pub let status_bad_filename : Int32 = 553

///|
/// The human readable text for every known status code.
///
/// The wording follows the RFC rather than upstream `status.go`: where upstream
/// trimmed a sentence down (`226` as "Closing data connection." versus its
/// "Closing data connection. Requested file action successful."), the RFC
/// wording is kept, so the text a user reads is the one the code means. No
/// localization on purpose.
pub fn status_text(code : Int32) -> String {
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
pub fn is_positive_completion(code : Int32) -> Bool {
  code >= 200 && code < 300
}

///|
/// Whether the code is a 1xx "positive intermediate" reply.
pub fn is_positive_intermediate(code : Int32) -> Bool {
  code >= 100 && code < 200
}

///|
/// Default timeout used when dialing a server, in milliseconds
/// (upstream `ftp.DefaultDialTimeout`, 30s).
pub let default_dial_timeout_ms : Int32 = 30 * 1000
