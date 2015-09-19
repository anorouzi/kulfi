open Core.Std
open Frenetic_Network
open Net      
open Kulfi_Types
open Kulfi_Routing
open Kulfi_Traffic
open Simulate_Exps
open Simulate_Demands
open RunningStat
open ExperimentalData 
open AutoTimer
       

let solver_to_string (s:solver_type) : string =
  match s with 
  | Mcf -> "mcf" 
  | Vlb -> "vlb" 
  | Ecmp -> "ecmp"
  | Spf -> "spf" 
  | Ak -> "ak"
  | Smcf -> "smcf"
  | Raeke -> "raeke" 
	      
let select_algorithm solver = match solver with
  | Mcf -> Kulfi_Routing.Mcf.solve
  | Vlb -> Kulfi_Routing.Vlb.solve
  | Ecmp -> Kulfi_Routing.Ecmp.solve
  | Spf -> Kulfi_Routing.Spf.solve
  | Ak -> Kulfi_Routing.Ak.solve
  | Smcf -> Kulfi_Routing.SemiMcf.solve
  | Raeke -> Kulfi_Routing.Raeke.solve

let congestion_of_paths (s:scheme) (t:topology) (d:demands) : (float EdgeMap.t) =
  let sent_on_each_edge = 
    SrcDstMap.fold
      s
      ~init:EdgeMap.empty
      ~f:(fun ~key:(src,dst) ~data:paths acc ->
          PathMap.fold
	    paths
            ~init:acc
            ~f:(fun ~key:path ~data:prob acc ->
                List.fold_left
		  path
                  ~init:acc
                  ~f:(fun acc e ->
                      let demand =
                        match SrcDstMap.find d (src,dst) with
                        | None -> 0.0
                        | Some x -> x in
		      Printf.printf "demand=%f\n" demand;
		      Printf.printf "prob=%f\n" prob;
                      match EdgeMap.find acc e with
                      | None -> EdgeMap.add ~key:e ~data:(demand *. prob) acc
                      | Some x ->  EdgeMap.add ~key:e ~data:((demand *. prob) +. x) acc)))
  in
  EdgeMap.fold
    ~init:EdgeMap.empty
    ~f:(fun ~key:e ~data:amount_sent acc ->
        Printf.printf "%f / %f \n" amount_sent (capacity_of_edge t e);
        EdgeMap.add ~key:e ~data:(amount_sent /. (capacity_of_edge t e)) acc) sent_on_each_edge 
    
    
(*  assume that flow is fractionally split in the proportions indicated by the probabilities. *)
let get_congestion (s:scheme) (t:topology) (d:demands) : float =
  let congestions = (congestion_of_paths s t d) in
  EdgeMap.fold ~init:Float.nan ~f:(fun ~key:e ~data:a acc -> Float.max_inan a acc) congestions

               
(* TODO(rjs): Do we count paths that have 0 flow ? *)    
let get_churn (old_scheme:scheme) (new_scheme:scheme) : float =
  let get_path_sets (s:scheme) : PathSet.t =
    SrcDstMap.fold
      ~init:PathSet.empty
      ~f:(fun ~key:_
	      ~data:d acc ->
	  PathMap.fold
	    ~init:acc
	    ~f:(fun ~key:p ~data:_ acc ->	  
		PathSet.add acc p ) d) s in
  let set1 = get_path_sets old_scheme in
  let set2 = get_path_sets new_scheme in
  let union = PathSet.union set1 set2 in
  let inter = PathSet.inter set1 set2 in
  Float.of_int (PathSet.length (PathSet.diff union inter))

let get_num_paths (s:scheme) : float =
  let count = SrcDstMap.fold
		~init:0
		~f:(fun ~key:_ ~data:d acc ->
		    acc + (PathMap.length d))
		s in    
  Float.of_int count 


let initial_scheme init_str topo aic ahm pic phm : scheme =
  match init_str with
  | None -> SrcDstMap.empty
  | Some "mcf" ->
     let _ = next_demand aic ahm in 
     let d = next_demand pic phm in 
     Kulfi_Routing.Mcf.solve topo d SrcDstMap.empty
  | Some "vlb" ->
     let _ = next_demand aic ahm in 
     let d = next_demand pic phm in 
     Kulfi_Routing.Vlb.solve topo d SrcDstMap.empty
  | Some "raeke" ->
     let _ = next_demand aic ahm in 
     let d = next_demand pic phm in 
     Kulfi_Routing.Raeke.solve topo d SrcDstMap.empty
  | Some _ -> failwith  "Unrecognized initialization scheme"

			
let simulate (spec_solvers:solver_type list)
	     (init_str:string option)
	     (topology_file:string)
	     (demand_file:string)
	     (predict_file:string)
	     (host_file:string)
	     (iterations:int) () : unit =

  (* Do some error checking on input *)

  let demand_lines_length = List.length (In_channel.read_lines demand_file) in
  let predict_lines_length = List.length (In_channel.read_lines predict_file) in 

  ignore (if (demand_lines_length < iterations) then failwith "Iterations greater than demand file length" else());
  ignore (if (predict_lines_length < iterations) then failwith "Iterations greater than predict file length" else());
  

  let topo = Parse.from_dotfile topology_file in
  let host_set = VertexSet.filter (Topology.vertexes topo)
				  ~f:(fun v ->
				      let label = Topology.vertex_to_label topo v in
				      Node.device label = Node.Host) in

  (* let hosts = Topology.VertexSet.elements host_set in *)

  Printf.printf "# hosts = %d\n" (Topology.VertexSet.length host_set);
  Printf.printf "# total vertices = %d\n" (Topology.num_vertexes topo);
  let at = make_auto_timer () in
  
  let time_data = make_data "Iteratives Vs Time" in
  let churn_data = make_data "Churn Vs Time" in
  let congestion_data = make_data "Congestion Vs Time" in
  let num_paths_data = make_data "Num. Paths Vs Time" in

  let rec range i j = if i >= j then [] else i :: (range (i+1) j) in
  let is = range 0 iterations in 


  List.iter
    spec_solvers
    ~f:(fun algorithm ->
	
	let solve = select_algorithm algorithm in
	
	let (actual_host_map, actual_ic) = open_demands demand_file host_file topo in
	let (predict_host_map, predict_ic) = open_demands predict_file host_file topo in

	(* we may need to initialize the scheme, and advance both traffic files *)
	let start_scheme = initial_scheme init_str topo
					  actual_ic actual_host_map
					  predict_ic predict_host_map in
	
	ignore (
	    List.fold_left
	      is (* 0..iterations *)
	      ~init:start_scheme
	      ~f:(fun scheme n ->
		  
		  (* get the next demand *)
		  let actual = next_demand actual_ic actual_host_map in
		  let predict = next_demand predict_ic predict_host_map in
		  
		  (* solve *)
		  start at;
		  let scheme' = solve topo predict scheme in 
		  stop at;
		  
		  (* record *)
		  let tm = (get_time_in_seconds at) in
		  let ch = (get_churn scheme' scheme) in
		  let cp = (get_congestion scheme' topo actual) in
		  let np = (get_num_paths scheme') in
	      	  
		  add_record time_data (solver_to_string algorithm) {iteration = n; time=tm; time_dev=0.0; };	     
		  add_record churn_data (solver_to_string algorithm) {iteration = n; churn=ch; churn_dev=0.0; };
		  add_record congestion_data (solver_to_string algorithm) {iteration = n; congestion=cp; congestion_dev=0.0; };
		  add_record num_paths_data (solver_to_string algorithm) {iteration = n; num_paths=np; num_paths_dev=0.0; };
		  
		  scheme') );
	
	(* start at beginning of demands for next algorithm *)
	close_demands actual_ic;
	close_demands predict_ic;

       );
  
  
  
  let dir = "./expData/" in

  to_file dir "ChurnVsIterations.dat" churn_data "# solver\titer\tchurn\tstddev" iter_vs_churn_to_string;
  to_file dir "CongestionVsIterations.dat" congestion_data "# solver\titer\tcongestion\tstddev" iter_vs_congestion_to_string;
  to_file dir "NumPathsVsIterations.dat" num_paths_data "# solver\titer\tnum_paths\tstddev" iter_vs_num_paths_to_string;
  to_file dir "TimeVsIterations.dat" time_data "# solver\titer\ttime\tstddev" iter_vs_time_to_string;  
  
  Printf.printf "%s" (to_string time_data "# solver\titer\ttime\tstddev" iter_vs_time_to_string);
  Printf.printf "%s" (to_string churn_data "# solver\titer\tchurn\tstddev" iter_vs_churn_to_string);
  Printf.printf "%s" (to_string congestion_data "# solver\titer\tcongestion\tstddev" iter_vs_congestion_to_string);
  Printf.printf "%s" (to_string num_paths_data "# solver\titer\tnum_paths\tstddev" iter_vs_num_paths_to_string)
		
		
let command =
  Command.basic
    ~summary:"Simulate run of routing strategies"
    Command.Spec.(
    empty
    +> flag "-mcf" no_arg ~doc:" run mcf"
    +> flag "-vlb" no_arg ~doc:" run vlb"
    +> flag "-ecmp" no_arg ~doc:" run ecmp"
    +> flag "-spf" no_arg ~doc:" run spf"
    +> flag "-ak" no_arg ~doc:" run ak"
    +> flag "-smcf" no_arg ~doc:" run semi mcf"
    +> flag "-raeke" no_arg ~doc:" run raeke"
    +> flag "-init" (optional string) ~doc:" solver to inititialize input scheme: [mcf|vlb|raeke]"
    +> anon ("topology-file" %: string)
    +> anon ("demand-file" %: string)
    +> anon ("predict-file" %: string)
    +> anon ("host-file" %: string)
    +> anon ("iterations" %: int)
  ) (fun (mcf:bool)
	 (vlb:bool)
	 (ecmp:bool)
	 (spf:bool)
	 (ak:bool)
	 (smcf:bool)
	 (raeke:bool)
	 (init_str:string option)
	 (topology_file:string)
	 (demand_file:string)
	 (predict_file:string)
	 (host_file:string)
	 (iterations:int) () ->
     let algorithms =
       List.filter_map
         ~f:(fun x -> x)
         [ if mcf then Some Mcf else None
         ; if vlb then Some Vlb else None
         ; if ecmp then Some Ecmp else None
         ; if spf then Some Spf else None
	 ; if ak then Some Ak else None
         ; if raeke then Some Raeke else None 
         ; if smcf then Some Smcf else None ] in 
     simulate algorithms init_str topology_file demand_file predict_file host_file iterations () )

let main = Command.run command
		       
let _ = main 

