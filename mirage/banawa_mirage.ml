open Lwt.Infix

let src = Logs.Src.create "banawa.mirage" ~doc:"Banawá mirage"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (F : Mirage_flow.S) (T : Mirage_time.S) (M : Mirage_clock.MCLOCK) = struct

  module FLOW = F
  module MCLOCK = M

  type error  = [ `Msg of string
                | `Read of F.error
                | `Write of F.write_error ]
  type write_error = [ Mirage_flow.write_error | error ]

  let pp_error ppf = function
    | `Msg e -> Fmt.string ppf e
    | `Read e -> F.pp_error ppf e
    | `Write e -> F.pp_write_error ppf e

  let pp_write_error ppf = function
    | #Mirage_flow.write_error as e -> Mirage_flow.pp_write_error ppf e
    | #error as e -> pp_error ppf e

  type flow = {
    flow : FLOW.flow ;
    mutable state : [ `Active of Banawa.Client.t | `Eof | `Error of error ]
  }

  let write_flow t buf =
    FLOW.write t.flow buf >>= function
    | Ok () -> Lwt.return (Ok ())
    | Error w ->
      Log.warn (fun m -> m "error %a while writing" F.pp_write_error w);
      t.state <- `Error (`Write w) ; Lwt.return (Error (`Write w))

  let writev_flow t bufs =
    Lwt_list.fold_left_s (fun r d ->
        match r with
        | Error e -> Lwt.return (Error e)
        | Ok () -> write_flow t d)
      (Ok ()) bufs

  let now () =
    Mtime.of_uint64_ns (M.elapsed_ns ())

  let read_react t =
    match t.state with
    | `Eof | `Error _ -> Lwt.return (Error ())
    | `Active _ ->
      FLOW.read t.flow >>= function
      | Error e ->
        Log.warn (fun m -> m "error %a while reading" F.pp_error e);
        t.state <- `Error (`Read e);
        Lwt.return (Error ())
      | Ok `Eof -> t.state <- `Eof ; Lwt.return (Error ())
      | Ok (`Data data) ->
        match t.state with
        | `Active ssh ->
            begin match Banawa.Client.incoming ssh (now ()) data with
            | Error msg ->
              Log.warn (fun m -> m "error %s while processing data" msg);
              t.state <- `Error (`Msg msg);
              Lwt.return (Error ())
            | Ok (ssh', out, events) ->
              let state' = if List.mem `Disconnected events then `Eof else `Active ssh' in
              t.state <- state';
              writev_flow t out >>= fun _ ->
              Lwt.return (Ok events)
          end
        | _ -> Lwt.return (Error ())

  let rec drain_handshake t =
    read_react t >>= function
    | Ok es ->
      begin match t.state, List.filter (function `Established _ -> true | _ -> false) es with
        | `Eof, _ -> Lwt.return (Error (`Msg "disconnected"))
        | `Error e, _ -> Lwt.return (Error e)
        | `Active _, [ `Established id ] -> Lwt.return (Ok id)
        | `Active _, _ -> drain_handshake t
      end
    | Error () -> match t.state with
      | `Error e -> Lwt.return (Error e)
      | `Eof -> Lwt.return (Error (`Msg "disconnected"))
      | `Active _ -> assert false

  let rec read t =
    read_react t >>= function
    | Ok events ->
      let r = List.fold_left (fun acc e ->
          match acc, e with
          | `Data d, `Channel_data (_, more) -> `Data (Cstruct.append d more)
            (* TODO verify that received on same channel! *)
          | `Data d, _ -> `Data d
          | `Nothing, `Channel_data (_, data) -> `Data data
          | `Nothing, `Channel_eof _ -> `Eof
          | `Nothing, `Disconnected -> `Eof
          | a, `Channel_stderr (id, data) ->
            Log.warn (fun m -> m "%ld stderr %s" id (Cstruct.to_string data));
            a
          | a, _ -> a)
          `Nothing events
      in
      begin match r with
        | `Nothing -> read t
        | `Data _ | `Eof as r -> Lwt.return (Ok r)
      end
    | Error () -> match t.state with
      | `Error e -> Lwt.return (Error e)
      | `Eof -> Lwt.return (Ok `Eof)
      | `Active _ -> assert false

  let close t =
    (* TODO ssh session teardown (send some protocol messages) *)
    FLOW.close t.flow >|= fun () ->
    t.state <- `Eof

  let writev t bufs =
    let open Lwt_result.Infix in
    match t.state with
    | `Active ssh ->
      Lwt_list.fold_left_s (fun r data ->
          match r with
          | Error e -> Lwt.return (Error e)
          | Ok ssh ->
            match Banawa.Client.outgoing_data ssh data with
            | Ok (ssh', datas) ->
              t.state <- `Active ssh';
              writev_flow t datas >|= fun () ->
              ssh'
            | Error msg ->
              t.state <- `Error (`Msg msg) ;
              Lwt.return (Error (`Msg msg)))
        (Ok ssh) bufs >|= fun _ -> ()
    | `Eof -> Lwt.return (Error `Closed)
    | `Error e -> Lwt.return (Error (e :> write_error))

  let write t buf = writev t [buf]

  let client_of_flow ?authenticator ~user auth req flow =
    let open Lwt_result.Infix in
    let client, msgs = Banawa.Client.make ?authenticator ~user auth in
    let t = {
      flow   = flow ;
      state  = `Active client ;
    } in
    writev_flow t msgs >>= fun () ->
    drain_handshake t >>= fun id ->
    (* TODO that's a bit hardcoded... *)
    let ssh = match t.state with `Active t -> t | _ -> assert false in
    (match Banawa.Client.outgoing_request ssh ~id req with
     | Error msg -> t.state <- `Error (`Msg msg) ; Lwt.return (Error (`Msg msg))
     | Ok (ssh', data) -> t.state <- `Active ssh' ; write_flow t data) >|= fun () ->
    t

(* copy from banawa_lwt.ml and unix references removed in favor to FLOW *)
  type nexus_msg =
    | Rekey
    | Net_eof
    | Net_io of Cstruct.t
    | Sshout of (int32 * Cstruct.t)
    | Ssherr of (int32 * Cstruct.t)

  type channel = {
    cmd         : string option;
    id          : int32;
    sshin_mbox  : Cstruct.t Mirage_flow.or_eof Lwt_mvar.t;
    exec_thread : unit Lwt.t;
  }

  type request =
    | Pty_req of { width : int32; height : int32; max_width : int32; max_height : int32; term : string }
    | Pty_set of { width : int32; height : int32; max_width : int32; max_height : int32 }
    | Set_env of { key : string; value : string }
    | Channel of { cmd : string
                 ; ic : unit -> Cstruct.t Mirage_flow.or_eof Lwt.t
                 ; oc : Cstruct.t -> unit Lwt.t
                 ; ec : Cstruct.t -> unit Lwt.t }
     | Shell  of { ic : unit -> Cstruct.t Mirage_flow.or_eof Lwt.t
                 ; oc : Cstruct.t -> unit Lwt.t
                 ; ec : Cstruct.t -> unit Lwt.t }

  type exec_callback = username:string -> request -> unit Lwt.t

  type t = {
    exec_callback  : exec_callback;       (* callback to run on exec *)
    channels       : channel list;        (* Opened channels *)
    nexus_mbox     : nexus_msg Lwt_mvar.t;(* Nexus mailbox *)
  }

  let wrapr = function
    | Ok x -> Lwt.return x
    | Error e -> invalid_arg e

  let send_msg flow server msg =
    wrapr (Banawa.Server.output_msg server msg)
    >>= fun (server, msg_buf) ->
    FLOW.write flow msg_buf >>= function
      | Ok () -> Lwt.return server
      | Error w ->
        Log.err (fun m -> m "error %a while writing" FLOW.pp_write_error w);
        Lwt.return server

  let rec send_msgs fd server = function
    | msg :: msgs ->
      send_msg fd server msg
      >>= fun server ->
      send_msgs fd server msgs
    | [] -> Lwt.return server

  let net_read flow =
    FLOW.read flow >>= function
    | Error e ->
      Log.err (fun m -> m "read error %a" FLOW.pp_error e);
      Lwt.return Net_eof
    | Ok `Eof ->
      Lwt.return Net_eof
    | Ok (`Data data) ->
      let n = Cstruct.length data in
      assert (n >= 0); (* handle exception ! ! *)
      let () = assert (n > 0) in          (* XXX *)
      Lwt.return (Net_io data)

  let sshin_eof c =
    Lwt_mvar.put c.sshin_mbox `Eof

  let sshin_data c data =
    Lwt_mvar.put c.sshin_mbox (`Data data)

  let lookup_channel t id =
    List.find_opt (fun c -> id = c.id) t.channels

  let rekey_promise server =
    match server.Banawa.Server.key_eol with
    | None -> []
    | Some mtime ->
      [ T.sleep_ns (Mtime.to_uint64_ns mtime) >>= fun () -> Lwt.return Rekey ]

  let rec nexus t fd server input_buffer pending_promises =
    wrapr (Banawa.Server.pop_msg2 server input_buffer)
    >>= fun (server, msg, input_buffer) ->
    match msg with
    | None -> (* No SSH msg *)
      (* We will listen from two incomming messages sources, from the net interface with
       * 'net_read', and from the ssh server with 'Lwt_mvar.take'. To let the promises
       * to be resolved, we use Lwt.choose to not add another of these until we know
       * that it was fulfiled.
      *)
      Lwt.nchoose_split pending_promises >>= fun (nexus_msg_fulfiled, pending_promises) ->
      (* We need to keep track of the "not fulfiled" promises and only Lwt.nchoose_split
       * allows us to have this information. This function also gives us a list of
       * "already fulfiled" promises. Here we consume this list and add the relevant new
       * promises to watch.
       *)
      let rec loop t fd server input_buffer fulfiled_promises pending_promises =
        match fulfiled_promises with
        | [] -> nexus t fd server input_buffer pending_promises
        (* Here we have the timeout fulfiled, we can let the net_read + Lwt_mvar.take continue *)
        | Rekey :: remaining_fulfiled_promises ->
          (match Banawa.Server.maybe_rekey server (now ()) with
          | None -> loop t fd server input_buffer remaining_fulfiled_promises pending_promises
          | Some (server, kexinit) ->
            send_msg fd server kexinit
            >>= fun server ->
            loop t fd server input_buffer remaining_fulfiled_promises (pending_promises @ rekey_promise server)
          )
        (* Here we have the net_read tells us to stop the communication... *)
        | Net_eof :: _ -> Lwt.return t
        (* Here we have the net_read fulfiled, we can let the timeout + Lwt_mvar.take continue and add a new net_read *)
        | Net_io buf :: remaining_fulfiled_promises ->
          loop t fd server (Banawa.Util.cs_join input_buffer buf) remaining_fulfiled_promises (List.append pending_promises [net_read fd])
        (* Here we have the Lwt_mvar.take fulfiled, we can let the timeout + net_read continue and add a new Lwt_mvar.take *)
        | Sshout (id, buf) :: remaining_fulfiled_promises
        | Ssherr (id, buf) :: remaining_fulfiled_promises ->
          wrapr (Banawa.Server.output_channel_data server id buf)
          >>= fun (server, msgs) ->
          send_msgs fd server msgs >>= fun server ->
          loop t fd server input_buffer remaining_fulfiled_promises (List.append pending_promises [ Lwt_mvar.take t.nexus_mbox ])
      in
      loop t fd server input_buffer nexus_msg_fulfiled pending_promises
    (* In all of the following we have the Lwt_mvar.take fulfiled, we can let the timeout + net_read continue
     * and add a new Lwt_mvar.take *)
    | Some msg -> (* SSH msg *)
      wrapr (Banawa.Server.input_msg server msg (now ()))
      >>= fun (server, replies, event) ->
      send_msgs fd server replies
      >>= fun server ->
      match event with
      | None -> nexus t fd server input_buffer (List.append pending_promises [ Lwt_mvar.take t.nexus_mbox ])
      | Some Banawa.Server.Pty (term, width, height, max_width, max_height, _modes) ->
        let username = Option.get (Banawa.Auth.username_of_auth_state server.Banawa.Server.auth_state) in
        t.exec_callback ~username (Pty_req { width; height; max_width; max_height; term; }) >>= fun () ->
        nexus t fd server input_buffer pending_promises
      | Some Banawa.Server.Pty_set (width, height, max_width, max_height) ->
        let username = Option.get (Banawa.Auth.username_of_auth_state server.Banawa.Server.auth_state) in
        t.exec_callback ~username (Pty_set { width; height; max_width; max_height }) >>= fun () ->
        nexus t fd server input_buffer pending_promises
      | Some Banawa.Server.Set_env (key, value) ->
        let username = Option.get (Banawa.Auth.username_of_auth_state server.Banawa.Server.auth_state) in
        t.exec_callback ~username (Set_env { key; value; }) >>= fun () ->
        nexus t fd server input_buffer pending_promises
      | Some Banawa.Server.Disconnected _ ->
        Lwt_list.iter_p sshin_eof t.channels
        >>= fun () -> Lwt.return t
      | Some Banawa.Server.Channel_eof id ->
        (match lookup_channel t id with
         | Some c -> sshin_eof c >>= fun () -> Lwt.return t
         | None -> Lwt.return t)
      | Some Banawa.Server.Channel_data (id, data) ->
        (match lookup_channel t id with
         | Some c -> sshin_data c data
         | None -> Lwt.return_unit)
        >>= fun () ->
        nexus t fd server input_buffer (List.append pending_promises [ Lwt_mvar.take t.nexus_mbox ])
      | Some Banawa.Server.Channel_subsystem (id, cmd) (* same as exec *)
      | Some Banawa.Server.Channel_exec (id, cmd) ->
        (* Create an input box *)
        let sshin_mbox = Lwt_mvar.create_empty () in
        (* Create a callback for each mbox *)
        let ic () = Lwt_mvar.take sshin_mbox in
        let oc id buf = Lwt_mvar.put t.nexus_mbox (Sshout (id, buf)) in
        let ec id buf = Lwt_mvar.put t.nexus_mbox (Ssherr (id, buf)) in
        let username = Option.get (Banawa.Auth.username_of_auth_state server.Banawa.Server.auth_state) in
        (* Create the execution thread *)
        let exec_thread = t.exec_callback ~username (Channel { cmd; ic; oc= oc id; ec= ec id; }) in
        let c = { cmd= Some cmd; id; sshin_mbox; exec_thread } in
        let t = { t with channels = c :: t.channels } in
        nexus t fd server input_buffer (List.append pending_promises [ Lwt_mvar.take t.nexus_mbox ])
      | Some (Banawa.Server.Start_shell id) ->
        let sshin_mbox = Lwt_mvar.create_empty () in
        (* Create a callback for each mbox *)
        let ic () = Lwt_mvar.take sshin_mbox in
        let oc id buf = Lwt_mvar.put t.nexus_mbox (Sshout (id, buf)) in
        let ec id buf = Lwt_mvar.put t.nexus_mbox (Ssherr (id, buf)) in
        let username = Option.get (Banawa.Auth.username_of_auth_state server.Banawa.Server.auth_state) in
        (* Create the execution thread *)
        let exec_thread = t.exec_callback ~username (Shell { ic; oc= oc id; ec= ec id; }) in
        let c = { cmd= None; id; sshin_mbox; exec_thread } in
        let t = { t with channels = c :: t.channels } in
        nexus t fd server input_buffer (List.append pending_promises [ Lwt_mvar.take t.nexus_mbox ])

  let spawn_server ?stop server msgs fd exec_callback =
    let t = { exec_callback;
              channels = [];
              nexus_mbox = Lwt_mvar.create_empty ()
            }
    in
    let open Lwt.Syntax in
    let* switched_off =
      let thread, u = Lwt.wait () in
      Lwt_switch.add_hook_or_exec stop (fun () ->
        Lwt.wakeup_later u Net_eof;
        Lwt_list.iter_p sshin_eof t.channels) >|= fun () -> thread in
    send_msgs fd server msgs >>= fun server ->
    (* the ssh communication will start with 'net_read' and can only add a 'Lwt.take' promise when
     * one Banawa.Server.Channel_{exec,subsystem} is received
     *)
    nexus t fd server (Cstruct.create 0) ([ switched_off; net_read fd ] @ rekey_promise server)

end
