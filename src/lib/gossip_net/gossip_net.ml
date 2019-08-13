[%%import
"../../config.mlh"]

open Core
open Async
open Pipe_lib
open Network_peer
open Kademlia
open O1trace
module Membership = Membership.Haskell

type ('q, 'r) dispatch =
  Versioned_rpc.Connection_with_menu.t -> 'q -> 'r Deferred.Or_error.t

module type Message_intf = sig
  type msg [@@deriving to_yojson]

  include
    Versioned_rpc.Both_convert.One_way.S
    with type callee_msg := msg
     and type caller_msg := msg

  val summary : msg -> string
end

module type Config_intf = sig
  type t =
    { timeout: Time.Span.t
    ; target_peer_count: int
    ; initial_peers: Host_and_port.t list
    ; addrs_and_ports: Kademlia.Node_addrs_and_ports.t
    ; conf_dir: string
    ; logger: Logger.t
    ; trust_system: Trust_system.t
    ; enable_libp2p: bool
    ; disable_haskell: bool
    ; max_concurrent_connections: int option }
  [@@deriving make]
end

module type S = sig
  type msg

  type ban_notification = {banned_peer: Peer.t; banned_until: Time.t}

  module Connection_with_state : sig
    type t = Banned | Allowed of Rpc.Connection.t Ivar.t
  end

  module Config : Config_intf

  type t =
    {
      config: Config.t
    ; broadcast_writer: msg Linear_pipe.Writer.t
    ; received_reader: msg Envelope.Incoming.t Strict_pipe.Reader.t
    ; peers: Peer.Hash_set.t
    ; peers_by_ip: (Unix.Inet_addr.t, Peer.t list) Hashtbl.t
    ; disconnected_peers: Peer.Hash_set.t
    ; ban_notification_reader: ban_notification Linear_pipe.Reader.t
    ; ban_notification_writer: ban_notification Linear_pipe.Writer.t
    ; mutable haskell_membership: Membership.t option
    ; mutable libp2p_membership: Coda_net2.net option
    ; connections:
        ( Unix.Inet_addr.t
        , (Uuid.t, Connection_with_state.t) Hashtbl.t )
        Hashtbl.t
    ; first_connect: unit Ivar.t }


  val create :
    Config.t -> Host_and_port.t Rpc.Implementation.t list -> t Deferred.t

  val received : t -> msg Envelope.Incoming.t Strict_pipe.Reader.t

  val broadcast : t -> msg Linear_pipe.Writer.t

  val broadcast_all :
    t -> msg -> (unit -> [`Done | `Continue] Deferred.t) Staged.t

  val random_peers : t -> int -> Peer.t list

  val random_peers_except : t -> int -> except:Peer.Hash_set.t -> Peer.t list

  val peers : t -> Peer.t list

  val initial_peers : t -> Host_and_port.t list

  val ban_notification_reader : t -> ban_notification Linear_pipe.Reader.t

  val query_peer :
    t -> Peer.t -> ('q, 'r) dispatch -> 'q -> 'r Or_error.t Deferred.t

  val query_random_peers :
    t -> int -> ('q, 'r) dispatch -> 'q -> 'r Or_error.t Deferred.t List.t
end

module Make (Message : Message_intf) : S with type msg := Message.msg = struct
  type ban_notification = {banned_peer: Peer.t; banned_until: Time.t}

  module Connection_with_state = struct
    type t = Banned | Allowed of Rpc.Connection.t Ivar.t

    let value_map ~when_allowed ~when_banned t =
      match t with Allowed c -> when_allowed c | _ -> when_banned
  end

  module Config = struct
    type t =
      { timeout: Time.Span.t
      ; target_peer_count: int
      ; initial_peers: Host_and_port.t list
      ; addrs_and_ports: Kademlia.Node_addrs_and_ports.t
      ; conf_dir: string
      ; logger: Logger.t
      ; trust_system: Trust_system.t
      ; enable_libp2p: bool
      ; disable_haskell: bool
      ; max_concurrent_connections: int option }
    [@@deriving make]
  end

  type t =
    {
      config: Config.t
    ; broadcast_writer: Message.msg Linear_pipe.Writer.t
    ; received_reader: Message.msg Envelope.Incoming.t Strict_pipe.Reader.t
    ; peers: Peer.Hash_set.t
    ; peers_by_ip: (Unix.Inet_addr.t, Peer.t list) Hashtbl.t
    ; disconnected_peers: Peer.Hash_set.t
    ; ban_notification_reader: ban_notification Linear_pipe.Reader.t
    ; ban_notification_writer: ban_notification Linear_pipe.Writer.t
    ; mutable haskell_membership: Membership.t option
    ; mutable libp2p_membership: Coda_net2.net option
    ; connections:
        ( Unix.Inet_addr.t
        , (Uuid.t, Connection_with_state.t) Hashtbl.t )
        Hashtbl.t
    ; first_connect: unit Ivar.t }

  (* OPTIMIZATION: use fast n choose k implementation - see python or old flow code *)
  let random_sublist xs n = List.take (List.permute xs) n

  (* clear disconnect set if peer set is at least this large *)
  let disconnect_clear_threshold = 3

  let to_where_to_connect (t : t) (peer : Peer.t) =
    Tcp.Where_to_connect.of_host_and_port
      ~bind_to_address:t.config.addrs_and_ports.bind_ip
    @@ { Host_and_port.host= Unix.Inet_addr.to_string peer.host
       ; port= peer.communication_port }

  (* remove peer from set of peers and peers_by_ip

     there are issues with this simple approach, because
     Kademlia is not informed when peers are removed, so:

     - the node may not be informed when a peer reconnects, so the
        peer won't be re-added to the peer set
     - Kademlia may propagate information about the removed peers
        other nodes
  *)
  let remove_peer t peer =
    Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
      !"Removing peer from peer set: %s"
      (Peer.to_string peer)
      ~metadata:[("peer", Peer.to_yojson peer)] ;
    Coda_metrics.(Gauge.dec_one Network.peers) ;
    Hash_set.remove t.peers peer ;
    Hashtbl.update t.peers_by_ip peer.host ~f:(function
      | None ->
          failwith "Peer to remove doesn't appear in peers_by_ip"
      | Some ip_peers ->
          List.filter ip_peers ~f:(fun ip_peer -> not (Peer.equal ip_peer peer)) )

  let mark_peer_disconnected t peer =
    remove_peer t peer ;
    Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
      !"Moving peer to disconnected peer set : %{sexp: Peer.t}"
      peer ;
    Hash_set.add t.disconnected_peers peer

  let add_peer t peer =
    Coda_metrics.(Gauge.inc_one Network.peers) ;
    Hash_set.add t.peers peer ;
    Hashtbl.add_multi t.peers_by_ip ~key:peer.host ~data:peer ;
    if
      Int.equal (Hash_set.length t.peers)
        disconnect_clear_threshold
    then Hash_set.clear t.disconnected_peers
    else Hash_set.remove t.disconnected_peers peer

  let haskell_missing = "old membership is enabled but the t.haskell_membership is None"

  let record_peer_events t =
    let open Peer.Event in
    trace_task "peer events" (fun () ->
      match t.config.disable_haskell with
      | false ->
        Linear_pipe.iter_unordered ~max_concurrency:64
          (Membership.changes (Option.value_exn ~message:haskell_missing t.haskell_membership)) ~f:(function
          | Connect peers ->
              Ivar.fill_if_empty t.first_connect () ;
              Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
                !"Connected to some peers [%s]"
                (Peer.pretty_list peers) ;
              List.iter peers ~f:(add_peer t);
              Deferred.unit
          | Disconnect peers ->
              Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
                "Some peers disconnected: %s" (Peer.pretty_list peers) ;
              List.iter peers ~f:(mark_peer_disconnected t) ;
              Deferred.unit )
        |> ignore
       | true -> () )

  let restart_kademlia t addl_peers =
    Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
      "Restarting Kademlia" ;
    match t.config.disable_haskell with
    | false -> (let%bind () = Membership.stop (Option.value_exn ~message:haskell_missing t.haskell_membership) in
    let%map new_membership =
      let initial_peers =
        List.dedup_and_sort ~compare:Host_and_port.compare
        @@ t.config.initial_peers @ addl_peers
      in
      Membership.connect ~node_addrs_and_ports:t.config.addrs_and_ports ~initial_peers
        ~conf_dir:t.config.conf_dir ~logger:t.config.logger ~trust_system:t.config.trust_system
    in
    match new_membership with
    | Ok membership ->
        t.haskell_membership <- Some membership ;
        record_peer_events t
    | Error _ ->
        failwith "Could not restart Kademlia")
    | true -> Deferred.unit

  let unmark_all_disconnected_peers t =
    Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
      !"Clearing disconnected peer set : %{sexp: Peer.t list}"
      (Hash_set.to_list t.disconnected_peers) ;
    let disconnected_peers =
      List.map
        (Hash_set.to_list t.disconnected_peers)
        ~f:Peer.to_communications_host_and_port
    in
    Hash_set.clear t.disconnected_peers ;
    restart_kademlia t disconnected_peers

  let is_unix_errno errno unix_errno =
    Int.equal (Unix.Error.compare errno unix_errno) 0

  (* see if we can connect to a disconnected peer, every so often *)
  let retry_disconnected_peer t =
    let rec loop () =
      let%bind () = Async.after (Time.Span.of_sec 30.0) in
      let%bind () =
        if
          Hash_set.is_empty t.peers
          && not (Hash_set.is_empty t.disconnected_peers)
        then
          let peer =
            List.random_element_exn (Hash_set.to_list t.disconnected_peers)
          in
          Deferred.ignore
            (Rpc.Connection.with_client (to_where_to_connect t peer)
               (fun conn ->
                 match%bind Versioned_rpc.Connection_with_menu.create conn with
                 | Ok _conn' ->
                     Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
                       !"Reconnected to a random disconnected peer: %{sexp: \
                         Peer.t}"
                       peer ;
                     unmark_all_disconnected_peers t
                 | Error _ ->
                     return () ))
        else return ()
      in
      loop ()
    in
    loop ()

  let try_call_rpc t (peer : Peer.t) dispatch query =
    let call () =
      Rpc.Connection.with_client (to_where_to_connect t peer) (fun conn ->
          Versioned_rpc.Connection_with_menu.create conn
          >>=? fun conn' -> dispatch conn' query )
      >>= function
      | Ok (Ok result) ->
          (* call succeeded, result is valid *)
          let%map () =
            if Hash_set.mem t.disconnected_peers peer then (
              (* optimistically, mark all disconnected peers as peers *)
              Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
                !"On RPC call, reconnected to a disconnected peer: %{sexp: \
                  Peer.t}"
                peer ;
              unmark_all_disconnected_peers t )
            else return ()
          in
          Ok result
      | Ok (Error err) -> (
          (* call succeeded, result is an error *)
          Logger.error t.config.logger ~module_:__MODULE__ ~location:__LOC__
            "RPC call error: $error, same error in machine format: \
             $machine_error"
            ~metadata:
              [ ("error", `String (Error.to_string_hum err))
              ; ("machine_error", `String (Error.to_string_mach err)) ] ;
          match (Error.to_exn err, Error.sexp_of_t err) with
          | ( _
            , Sexp.List
                [ Sexp.Atom "src/connection.ml.Handshake_error.Handshake_error"
                ; _ ] ) ->
              let%map () =
                Trust_system.(
                  record t.config.trust_system t.config.logger peer.host
                    Actions.
                      (Outgoing_connection_error, Some ("handshake error", [])))
              in
              remove_peer t peer ; Error err
          | ( _
            , Sexp.List
                [ Sexp.List
                    [ Sexp.Atom "rpc_error"
                    ; Sexp.List [Sexp.Atom "Connection_closed"; _] ]
                ; _connection_description
                ; _rpc_tag
                ; _rpc_version ] ) ->
              let%map () =
                Trust_system.(
                  record t.config.trust_system t.config.logger peer.host
                    Actions.
                      ( Outgoing_connection_error
                      , Some ("Closed connection", []) ))
              in
              remove_peer t peer ; Error err
          | _ ->
              let%map () =
                Trust_system.(
                  record t.config.trust_system t.config.logger peer.host
                    Actions.
                      ( Violated_protocol
                      , Some
                          ( "RPC call failed, reason: $exn"
                          , [("exn", `String (Error.to_string_hum err))] ) ))
              in
              remove_peer t peer ; Error err )
      | Error monitor_exn -> (
          (* call itself failed *)
          (* TODO: learn what other exceptions are raised here *)
          let exn = Monitor.extract_exn monitor_exn in
          match exn with
          | Unix.Unix_error (errno, _, _)
            when is_unix_errno errno Unix.ECONNREFUSED ->
              let%map () =
                Trust_system.(
                  record t.config.trust_system t.config.logger peer.host
                    Actions.
                      ( Outgoing_connection_error
                      , Some ("Connection refused", []) ))
              in
              mark_peer_disconnected t peer ;
              Or_error.of_exn exn
          | _ ->
              Logger.error t.config.logger ~module_:__MODULE__ ~location:__LOC__
                "RPC call raised an exception: $exn"
                ~metadata:[("exn", `String (Exn.to_string exn))] ;
              return (Or_error.of_exn exn) )
    in
    match Hashtbl.find t.connections peer.host with
    | None ->
        call ()
    | Some conn_map ->
        if
          Option.is_some t.config.max_concurrent_connections
          && Hashtbl.length conn_map
             >= Option.value_exn t.config.max_concurrent_connections
        then
          Deferred.return
            (Or_error.errorf
               !"Not connecting to peer %s. Number of open connections to the \
                 peer equals the limit %d.\n"
               (Peer.to_string peer)
               (Option.value_exn t.config.max_concurrent_connections))
        else call ()

  let broadcast_selected t peers msg =
    let send peer =
      try_call_rpc t peer
        (fun conn m -> return (Message.dispatch_multi conn m))
        msg
    in
    trace_event "broadcasting message" ;
    Deferred.List.iter ~how:`Parallel peers ~f:(fun peer ->
        match%map send peer with
        | Ok () ->
            ()
        | Error e ->
            Logger.error t.config.logger ~module_:__MODULE__ ~location:__LOC__
              "Broadcasting message $message_summary to $peer failed: $error"
              ~metadata:
                [ ("error", `String (Error.to_string_hum e))
                ; ("message_summary", `String (Message.summary msg))
                ; ("message", Message.msg_to_yojson msg)
                ; ("peer", Peer.to_yojson peer) ] )

  let broadcast_random t n msg =
    (* don't use disconnected peers here; because this function is called
       repeatedly in the broadcast loop, that will quickly lead to a ban,
       so we don't be able to re-connect to that peer
     *)
    let selected_peers = random_sublist (Hash_set.to_list t.peers) n in
    broadcast_selected t selected_peers msg

  let send_ban_notification t banned_peer banned_until =
    Linear_pipe.write_without_pushback t.ban_notification_writer
      {banned_peer; banned_until}

  let create (config : Config.t)
      (implementation_list : Host_and_port.t Rpc.Implementation.t list) =
    let t_for_restarting = ref None in
    trace_task "gossip net" (fun () ->
        let fail m =
          failwith
            (Printf.sprintf "Failed to connect to Kademlia process: %s\n" m)
        in
        let restart_counter = ref 0 in
        let rec handle_exn e =
          incr restart_counter ;
          if !restart_counter > 5 then
            failwithf
              "Already restarted Kademlia subprocess 5 times, dying with \
               exception %s"
              (Exn.to_string e) () ;
          match Monitor.extract_exn e with
          | Kademlia.Membership.Child_died ->
              let t = Option.value_exn !t_for_restarting in
              let peers =
                List.map (Hash_set.to_list t.peers)
                  ~f:Peer.to_communications_host_and_port
              in
              ( match%map
                  Monitor.try_with ~extract_exn:true
                    (fun () ->
                      let%bind () = after Time.Span.second in
                      restart_kademlia t peers )
                    ~rest:(`Call handle_exn)
                with
              | Error Kademlia.Membership.Child_died ->
                  handle_exn Kademlia.Membership.Child_died
              | Ok () ->
                  ()
              | Error e ->
                  failwithf "Unhandled Membership.connect exception: %s"
                    (Exn.to_string e) () )
              |> don't_wait_for
          | _ ->
              failwithf "Unhandled Membership.connect exception: %s"
                (Exn.to_string e) ()
        in
        let%bind membership =
          if not config.disable_haskell then
          (match%map
            Monitor.try_with
              (fun () ->
                trace_task "membership" (fun () ->
                    Membership.connect ~initial_peers:config.initial_peers
                      ~node_addrs_and_ports:config.addrs_and_ports
                      ~conf_dir:config.conf_dir ~logger:config.logger
                      ~trust_system:config.trust_system ) )
              ~rest:(`Call handle_exn)
          with
          | Ok (Ok membership) ->
              Some membership
          | Ok (Error e) ->
              fail (Error.to_string_hum e)
          | Error e ->
              fail (Exn.to_string e)) else Deferred.return None
        in
        let first_connect = Ivar.create () in
        let broadcast_reader, broadcast_writer = Linear_pipe.create () in
        let received_reader, received_writer =
          Strict_pipe.create ~name:"received gossip messages"
            (Buffered (`Capacity 64, `Overflow Crash))
        in
        let ban_notification_reader, ban_notification_writer =
          Linear_pipe.create ()
        in
        let t =
          { config
          ; broadcast_writer
          ; received_reader
          ; peers= Peer.Hash_set.create ()
          ; peers_by_ip= Hashtbl.create (module Unix.Inet_addr)
          ; disconnected_peers= Peer.Hash_set.create ()
          ; ban_notification_reader
          ; ban_notification_writer
          ; haskell_membership= membership
          ; libp2p_membership= None
          ; connections= Hashtbl.create (module Unix.Inet_addr)
          ; first_connect }
        in
        t_for_restarting := Some t ;
        don't_wait_for
          (Strict_pipe.Reader.iter (Trust_system.ban_pipe config.trust_system)
             ~f:(fun (addr, banned_until) ->
               (* all peers at banned IP *)
               let peers =
                 Option.value_map
                   (Hashtbl.find t.peers_by_ip addr)
                   ~default:[] ~f:Fn.id
               in
               List.iter peers ~f:(fun peer ->
                   send_ban_notification t peer banned_until ) ;
               match Hashtbl.find t.connections addr with
               | None ->
                   Deferred.unit
               | Some conn_tbl ->
                   Logger.debug t.config.logger ~module_:__MODULE__ ~location:__LOC__
                     !"Peer %s banned, disconnecting."
                     (Unix.Inet_addr.to_string addr) ;
                   let%map () =
                     Deferred.List.iter (Hashtbl.to_alist conn_tbl)
                       ~f:(fun (_, conn_state) ->
                         Connection_with_state.value_map conn_state
                           ~when_allowed:(fun conn_ivar ->
                             let%bind conn = Ivar.read conn_ivar in
                             Rpc.Connection.close conn )
                           ~when_banned:Deferred.unit )
                   in
                   Hashtbl.map_inplace conn_tbl ~f:(fun conn_state ->
                       Connection_with_state.value_map conn_state
                         ~when_allowed:(fun _ -> Connection_with_state.Banned)
                         ~when_banned:Banned ) )) ;
        don't_wait_for (retry_disconnected_peer t) ;
        trace_task "rebroadcasting messages" (fun () ->
            don't_wait_for
              (Linear_pipe.iter_unordered ~max_concurrency:64 broadcast_reader
                 ~f:(fun m ->
                   Logger.trace t.config.logger ~module_:__MODULE__ ~location:__LOC__
                     "broadcasting message" ;
                   broadcast_random t t.config.target_peer_count m )) ) ;
        let implementations =
          let implementations =
            Versioned_rpc.Menu.add
              ( Message.implement_multi
                  (fun client_host_and_port ~version:_ msg ->
                    (* wrap received message in envelope *)
                    Coda_metrics.(
                      Counter.inc_one Network.gossip_messages_received) ;
                    let sender =
                      Envelope.Sender.Remote
                        (Unix.Inet_addr.of_string
                           client_host_and_port.Host_and_port.host)
                    in
                    Strict_pipe.Writer.write received_writer
                      (Envelope.Incoming.wrap ~data:msg ~sender) )
              @ implementation_list )
          in
          let handle_unknown_rpc conn ~rpc_tag ~version =
            let inet_addr = Unix.Inet_addr.of_string conn.Host_and_port.host in
            Deferred.don't_wait_for
              Trust_system.(
                record t.config.trust_system t.config.logger inet_addr
                  Actions.
                    ( Violated_protocol
                    , Some
                        ( "Attempt to make unknown (fixed-version) RPC call \
                           \"$rpc\" with version $version"
                        , [("rpc", `String rpc_tag); ("version", `Int version)]
                        ) )) ;
            `Close_connection
          in
          Rpc.Implementations.create_exn ~implementations
            ~on_unknown_rpc:(`Call handle_unknown_rpc)
        in
        record_peer_events t ;
        let%map _ =
          Tcp.Server.create
            ~on_handler_error:
              (`Call
                (fun addr exn ->
                  Logger.error t.config.logger ~module_:__MODULE__ ~location:__LOC__
                    "Exception raised in gossip net TCP server handler when \
                     connected to address $address: $exn"
                    ~metadata:
                      [ ("exn", `String (Exn.to_string_mach exn))
                      ; ("address", `String (Socket.Address.to_string addr)) ] ;
                  raise exn ))
            Tcp.(
              Where_to_listen.bind_to
                (Bind_to_address.Address t.config.addrs_and_ports.bind_ip)
                (Bind_to_port.On_port t.config.addrs_and_ports.communication_port))
            (fun client reader writer ->
              let client_inet_addr = Socket.Address.Inet.addr client in
              let%bind () =
                Trust_system.(
                  record t.config.trust_system t.config.logger client_inet_addr
                    Actions.(Connected, None))
              in
              let conn_map =
                Option.value_map
                  ~default:(Hashtbl.create (module Uuid))
                  (Hashtbl.find t.connections client_inet_addr)
                  ~f:Fn.id
              in
              let is_client_banned =
                let peer_status =
                  Trust_system.Peer_trust.lookup t.config.trust_system
                    client_inet_addr
                in
                match peer_status.banned with
                | Banned_until _ ->
                    true
                | Unbanned ->
                    false
              in
              if is_client_banned then (
                Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
                  "Rejecting connection from banned peer %s"
                  (Socket.Address.Inet.to_string client) ;
                Deferred.unit )
              else if
                Option.is_some t.config.max_concurrent_connections
                && Hashtbl.length conn_map
                   >= Option.value_exn t.config.max_concurrent_connections
              then (
                Logger.error t.config.logger ~module_:__MODULE__ ~location:__LOC__
                  "Gossip net TCP server cannot open another connection. \
                   Number of open connections from client $client equals the \
                   limit $max_connections"
                  ~metadata:
                    [ ("client", `String (Socket.Address.Inet.to_string client))
                    ; ( "max_connections"
                      , `Int (Option.value_exn t.config.max_concurrent_connections) )
                    ] ;
                Deferred.unit )
              else
                let conn_id = Uuid_unix.create () in
                Hashtbl.add_exn conn_map ~key:conn_id
                  ~data:(Allowed (Ivar.create ())) ;
                Hashtbl.set t.connections ~key:client_inet_addr ~data:conn_map ;
                let%map () =
                  Rpc.Connection.server_with_close reader writer
                    ~implementations
                    ~connection_state:(fun conn ->
                      (* connection state is the client's IP and ephemeral port
                        when connecting to the server over TCP; the ephemeral
                        port is distinct from the client's discovery and
                        communication ports *)
                      Connection_with_state.value_map
                        (Hashtbl.find_exn conn_map conn_id)
                        ~when_allowed:(fun ivar -> Ivar.fill ivar conn)
                        ~when_banned:() ;
                      Hashtbl.set t.connections
                        ~key:(Socket.Address.Inet.addr client)
                        ~data:conn_map ;
                      Socket.Address.Inet.to_host_and_port client )
                    ~on_handshake_error:
                      (`Call
                        (fun exn ->
                          Trust_system.(
                            record t.config.trust_system t.config.logger client_inet_addr
                              Actions.
                                ( Incoming_connection_error
                                , Some
                                    ( "Handshake error: $exn"
                                    , [("exn", `String (Exn.to_string exn))] )
                                )) ))
                in
                let conn_map =
                  Hashtbl.find_exn t.connections client_inet_addr
                in
                Hashtbl.remove conn_map conn_id ;
                if Hashtbl.is_empty conn_map then
                  Hashtbl.remove t.connections client_inet_addr
                else
                  Hashtbl.set t.connections ~key:client_inet_addr
                    ~data:conn_map )
        in
        t )

  let received t = t.received_reader

  let broadcast t = t.broadcast_writer

  let peers t = Hash_set.to_list t.peers

  let initial_peers t = t.config.initial_peers

  let ban_notification_reader t = t.ban_notification_reader

  let broadcast_all t msg =
    let to_broadcast = ref (List.permute (Hash_set.to_list t.peers)) in
    stage (fun () ->
        let selected = List.take !to_broadcast t.config.target_peer_count in
        to_broadcast := List.drop !to_broadcast t.config.target_peer_count ;
        let%map () = broadcast_selected t selected msg in
        if List.length !to_broadcast = 0 then `Done else `Continue )

  let random_peers t n =
    (* choose disconnected peers if no other peers available *)
    let peers =
      if Hash_set.is_empty t.peers then t.disconnected_peers else t.peers
    in
    random_sublist (Hash_set.to_list peers) n

  let random_peers_except t n ~(except : Peer.Hash_set.t) =
    (* choose disconnected peers if no other peers available *)
    let new_peers =
      let open Hash_set in
      let diff_peers = diff t.peers except in
      if is_empty diff_peers then diff t.disconnected_peers except
      else diff_peers
    in
    random_sublist (Hash_set.to_list new_peers) n

  let query_peer t (peer : Peer.t) rpc query =
    Logger.trace t.config.logger ~module_:__MODULE__ ~location:__LOC__
      !"Querying peer %s" (Peer.to_string peer) ;
    try_call_rpc t peer rpc query

  let query_random_peers t n rpc query =
    let peers = random_peers t n in
    Logger.trace t.config.logger ~module_:__MODULE__ ~location:__LOC__
      !"Querying random peers: %s"
      (Peer.pretty_list peers) ;
    List.map peers ~f:(fun peer -> query_peer t peer rpc query)
end
