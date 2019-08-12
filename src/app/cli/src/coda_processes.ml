[%%import
"../../../config.mlh"]

open Core
open Async

let init () = Parallel.init_master ()

type ports = {communication_port:int;discovery_port:int;libp2p_port:int}

let net_configs n =
  let ports = List.init n ~f:(fun i ->
    let base = 23000 + (i * 3) in {communication_port= base; discovery_port= base+1; libp2p_port= base+2}) in
  let ips =
    List.init n ~f:(fun i ->
        Unix.Inet_addr.of_string @@ sprintf "127.0.0.%d" (i + 10) )
  in
  let addrs_and_ports_list =
    List.map2_exn ports ips
      ~f:(fun {communication_port;discovery_port;libp2p_port} ip ->
        Kademlia.Node_addrs_and_ports.
          {external_ip= ip; bind_ip= ip; discovery_port; communication_port; libp2p_port } )
  in
  let all_peers =
    List.map addrs_and_ports_list
      ~f:Kademlia.Node_addrs_and_ports.to_discovery_host_and_port
  in
  let peers =
    List.init n ~f:(fun i -> List.take all_peers i @ List.drop all_peers (i + 1)
    )
  in
  (addrs_and_ports_list, peers)

let offset =
  lazy
    Core.Time.(
      diff (now ())
        ( Consensus.Constants.genesis_state_timestamp
        |> Coda_base.Block_time.to_time ))

let local_configs ?proposal_interval ?(proposers = Fn.const None)
    ?(is_archive_node = Fn.const false) n ~acceptable_delay ~program_dir
    ~snark_worker_public_keys ~work_selection_method ~trace_dir
    ~max_concurrent_connections =
  let addrs_and_ports_list, peers = net_configs n in
  let peers = [] :: List.drop peers 1 in
  let args = List.zip_exn addrs_and_ports_list peers in
  let configs =
    List.mapi args ~f:(fun i (addrs_and_ports, peers) ->
        let public_key =
          Option.map snark_worker_public_keys ~f:(fun keys ->
              List.nth_exn keys i )
        in
        let snark_worker_config =
          Option.bind public_key ~f:(fun public_key ->
              Option.bind public_key ~f:(fun public_key ->
                  Some
                    { Coda_worker.Snark_worker_config.public_key
                    ; port= 20000 + i } ) )
        in
        Coda_process.local_config ?proposal_interval ~addrs_and_ports ~peers
          ~snark_worker_config ~program_dir ~acceptable_delay
          ~proposer:(proposers i) ~work_selection_method ~trace_dir
          ~is_archive_node:(is_archive_node i) ~offset:(Lazy.force offset)
          ~max_concurrent_connections () )
  in
  configs

let stabalize_and_start_or_timeout ?(timeout_ms = 2000.) nodes =
  let ready () =
    let check_ready node =
      let%map peers = Coda_process.peers_exn node in
      List.length peers = List.length nodes - 1
    in
    let rec go () =
      if%bind Deferred.List.for_all nodes ~f:check_ready then return ()
      else go ()
    in
    go ()
  in
  match%bind
    Deferred.any
      [ (after (Time.Span.of_ms timeout_ms) >>= fun () -> return `Timeout)
      ; (ready () >>= fun () -> return `Ready) ]
  with
  | `Timeout ->
      failwith @@ sprintf "Nodes couldn't initialize within %f ms" timeout_ms
  | `Ready ->
      Deferred.List.iter nodes ~f:(fun node -> Coda_process.start_exn node)

let spawn_local_processes_exn ?(first_delay = 0.0) configs =
  match configs with
  | [] ->
      failwith "Configs should be non-empty"
  | first :: rest ->
      let%bind first_created = Coda_process.spawn_exn first in
      let%bind () = after (Time.Span.of_sec first_delay) in
      let%bind rest_created =
        Deferred.List.all
          (List.map rest ~f:(fun c -> Coda_process.spawn_exn c))
      in
      let all_created = first_created :: rest_created in
      let%map () = stabalize_and_start_or_timeout all_created in
      all_created
