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

open Sexplib.Conv
open Rresult.R
open Util

let version_banner = "SSH-2.0-awa_ssh_0.1"

type t = {
  client_version : string option;      (* Without crlf *)
  server_version : string;             (* Without crlf *)
  client_kex : Cstruct.t option;       (* Last KEXINIT received *)
  server_kex : Cstruct.t;              (* Last KEXINIT sent by us *)
  neg_kex : Kex.negotiation option;    (* Negotiated KEX *)
  host_key : Nocrypto.Rsa.priv;        (* Server host key *)
  session_id : Cstruct.t option;       (* First calculated H *)
  keys_ctos : Kex.keys option;         (* Client to server (input) keys *)
  keys_stoc : Kex.keys option;         (* Server to cleint (output) keys *)
  new_keys_ctos : Kex.keys option;     (* Install when we receive NEWKEYS *)
  new_keys_stoc : Kex.keys option;     (* Install after we send NEWKEYS *)
}

let make host_key =
  let banner_buf = Printf.sprintf "%s\r\n" version_banner |> Cstruct.of_string in
  let kex = Kex.make_pkt () in
  let server_kex = Ssh.encode_kex_pkt kex in
  let t = { client_version = None;
            server_version = version_banner;
            server_kex;
            client_kex = None;
            neg_kex = None;
            host_key;
            session_id = None;
            keys_ctos = None;
            keys_stoc = None;
            new_keys_ctos = None;
            new_keys_stoc = None; }
  in
  t, banner_buf, server_kex

let input_msg t msgbuf =
  let open Ssh in
  let open Nocrypto in
  Decode.decode_message msgbuf >>= function
  | Ssh_msg_kexinit kex ->
    Decode.decode_kex_pkt t.server_kex >>= fun (server_kex, _) ->
    Kex.negotiate ~s:server_kex ~c:kex
    >>= fun neg ->
    ok ({ t with client_kex = Some msgbuf; neg_kex = Some neg }, [])

  | Ssh_msg_kexdh_init e ->
    guard_some t.neg_kex "No negotiated kex" >>= fun neg ->
    guard_some t.client_version "No client version" >>= fun v_c ->
    guard_none t.new_keys_stoc "Already got new_keys_stoc" >>= fun () ->
    guard_none t.new_keys_ctos "Already got new_keys_ctos" >>= fun () ->
    guard_some t.client_kex "No client kex" >>= fun i_c ->
    let v_c = Cstruct.of_string v_c in
    let v_s = Cstruct.of_string t.server_version in
    let i_s = t.server_kex in
    let pub_host_key = Rsa.pub_of_priv t.host_key in
    let k_s = Buf.encode_key pub_host_key in
    Kex.(Dh.generate neg.kex_algorithm e) >>= fun (y, f, k) ->
    let h = Kex.Dh.compute_hash ~v_c ~v_s ~i_c ~i_s ~k_s ~e ~f ~k in
    let signature = Rsa.PKCS1.sig_encode t.host_key h in
    let session_id = match t.session_id with None -> h | Some x -> x in
    let new_keys_ctos, new_keys_stoc =
      Kex.Dh.derive_keys k h session_id (Kex.keylen_needed neg)
    in
    ok ({t with session_id = Some session_id;
                new_keys_ctos = Some new_keys_ctos;
                new_keys_stoc = Some new_keys_stoc; },
        [ Ssh_msg_kexdh_reply (pub_host_key, f, signature);
          Ssh_msg_newkeys ])

  | Ssh_msg_newkeys ->
    guard_some t.new_keys_ctos "No new_keys_ctos" >>= fun new_keys_ctos ->
    ok ({ t with keys_ctos = Some new_keys_ctos;
                 new_keys_ctos = None },
        [])

  | _ -> error "unhandled stuff"

let output_msg t msg =
  let open Ssh in
  match msg with
  | Ssh_msg_newkeys ->
    guard_some t.new_keys_stoc "Expected new keys" >>= fun new_keys_stoc ->
    ok { t with keys_stoc = Some new_keys_stoc;
                new_keys_stoc = None }

  | _ -> ok t
