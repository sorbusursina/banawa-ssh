(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type credentials = Hostkey.pub list

module Db = Hashtbl.Make(struct type t = string let equal = String.equal let hash = Hashtbl.hash end)

type db = credentials Db.t

type state =
  | Preauth
  | Inprogress of (string * string * int)
  | Done of { username : string; service : string }

let username_of_auth_state = function
  | Preauth | Inprogress _ -> None
  | Done { username; _ } -> Some username

let make_credentials keys =
  if keys = [] then
    invalid_arg "keys must not be empty";
  keys

let lookup_key credentials key =
  List.find_opt (fun key' -> key = key' ) credentials

let to_hash name alg pubkey session_id service =
  let open Wire in
  put_cstring session_id (Dbuf.create ()) |>
  put_message_id Ssh.MSG_USERAUTH_REQUEST |>
  put_string name |>
  put_string service |>
  put_string "publickey" |>
  put_bool true |>
  put_string (Hostkey.alg_to_string alg) |>
  put_pubkey pubkey |>
  Dbuf.to_cstruct

let sign name alg key session_id service =
  let data = to_hash name alg (Hostkey.pub_of_priv key) session_id service in
  Hostkey.sign alg key data

let by_pubkey name alg pubkey session_id service signed =
    let unsigned = to_hash name alg pubkey session_id service in
    Hostkey.verify alg pubkey ~unsigned ~signed
