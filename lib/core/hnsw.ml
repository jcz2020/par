(* HNSW — Hierarchical Navigable Small World graph for ANN search.
   Reference: Malkov & Yashunin, TPAMI 2020, Algorithms 1-4. *)

(* === Distance functions === *)

let normalize (vec : Float.Array.t) : Float.Array.t =
  let n = Float.Array.length vec in
  let norm_sq = ref 0.0 in
  for i = 0 to n - 1 do
    let v = Float.Array.get vec i in
    norm_sq := !norm_sq +. v *. v
  done;
  let s = sqrt !norm_sq in
  if s < 1e-10 then Float.Array.make n 0.0
  else
    let r = Float.Array.create n in
    for i = 0 to n - 1 do
      Float.Array.set r i (Float.Array.get vec i /. s)
    done;
    r

let cosine_distance (a : Float.Array.t) (b : Float.Array.t) : float =
  let n = Float.Array.length a in
  let dot = ref 0.0 in
  for i = 0 to n - 1 do
    dot := !dot +. Float.Array.get a i *. Float.Array.get b i
  done;
  1.0 -. !dot

let l2_distance (a : Float.Array.t) (b : Float.Array.t) : float =
  let n = Float.Array.length a in
  let sum = ref 0.0 in
  for i = 0 to n - 1 do
    let d = Float.Array.get a i -. Float.Array.get b i in
    sum := !sum +. d *. d
  done;
  sqrt !sum

(* === Binary heap (priority queue) === *)

module Heap = struct
  type t = {
    mutable data : (float * int) array;
    mutable size : int;
    better : float -> float -> bool;
  }

  let create_min () =
    { data = Array.make 16 (0.0, 0); size = 0; better = (<) }

  let create_max () =
    { data = Array.make 16 (0.0, 0); size = 0; better = (>) }

  let push h (d, idx) =
    if h.size = Array.length h.data then begin
      let nd = Array.make (h.size * 2) (0.0, 0) in
      Array.blit h.data 0 nd 0 h.size;
      h.data <- nd
    end;
    let i = ref h.size in
    h.size <- h.size + 1;
    let cont = ref true in
    while !cont && !i > 0 do
      let p = (!i - 1) / 2 in
      if h.better d (fst h.data.(p)) then begin
        h.data.(!i) <- h.data.(p);
        i := p
      end else
        cont := false
    done;
    h.data.(!i) <- (d, idx)

  let pop h =
    if h.size = 0 then None
    else begin
      let r = h.data.(0) in
      h.size <- h.size - 1;
      h.data.(0) <- h.data.(h.size);
      let i = ref 0 in
      let go = ref true in
      while !go do
        let l = 2 * !i + 1 and ri = 2 * !i + 2 in
        let b = ref !i in
        if l < h.size && h.better (fst h.data.(l)) (fst h.data.(!b)) then b := l;
        if ri < h.size && h.better (fst h.data.(ri)) (fst h.data.(!b)) then b := ri;
        if !b <> !i then begin
          let tmp = h.data.(!i) in
          h.data.(!i) <- h.data.(!b);
          h.data.(!b) <- tmp;
          i := !b
        end else
          go := false
      done;
      Some r
    end

  let peek h = if h.size = 0 then None else Some h.data.(0)
  let length h = h.size
end

(* === Core types === *)

type distance_metric = [`Cosine | `L2]

type node = {
  id : string;
  vector : Float.Array.t;
  normalized : Float.Array.t;
  max_layer : int;
  edges : (int, int list) Hashtbl.t;
} [@@warning "-69"]

type t = {
  dimension : int;
  m : int;
  m_max0 : int;
  ef_construction : int;
  ef_search : int;
  metric : distance_metric;
  nodes : (int, node) Hashtbl.t;
  id_to_index : (string, int) Hashtbl.t;
  index_to_id : (int, string) Hashtbl.t;
  mutable entry_point : int option;
  mutable max_level : int;
  mutable next_index : int;
  deleted : (int, unit) Hashtbl.t;
}

(* === Internal helpers === *)

let get_neighbors t idx layer =
  match Hashtbl.find_opt t.nodes idx with
  | None -> []
  | Some node ->
    (match Hashtbl.find_opt node.edges layer with
     | Some ns -> ns
     | None -> [])

let dist_nodes t i1 i2 =
  let n1 = Hashtbl.find t.nodes i1 in
  let n2 = Hashtbl.find t.nodes i2 in
  match t.metric with
  | `Cosine -> cosine_distance n1.normalized n2.normalized
  | `L2 -> l2_distance n1.vector n2.vector

let dist_vec t ~qv ~qn idx =
  let n = Hashtbl.find t.nodes idx in
  match t.metric with
  | `Cosine -> cosine_distance qn n.normalized
  | `L2 -> l2_distance qv n.vector

let max_edges t layer =
  if layer = 0 then t.m_max0 else t.m

let take_n lst n =
  let rec aux acc k = function
    | _ when k <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> aux (x :: acc) (k - 1) xs
  in
  aux [] n lst

(* === Algorithm 2: search-layer === *)

let search_layer t ~qv ~qn entries ef layer =
  if entries = [] then []
  else
    let visited = Hashtbl.create 64 in
    let cands = Heap.create_min () in
    let res = Heap.create_max () in
    List.iter (fun ep ->
      if not (Hashtbl.mem t.deleted ep) then begin
        let d = dist_vec t ~qv ~qn ep in
        Hashtbl.replace visited ep ();
        Heap.push cands (d, ep);
        Heap.push res (d, ep)
      end
    ) entries;
    let go = ref true in
    while !go && Heap.length cands > 0 do
      match Heap.pop cands with
      | None -> go := false
      | Some (cd, ci) ->
        let fd = match Heap.peek res with Some (d, _) -> d | None -> max_float in
        if cd > fd then go := false
        else
          List.iter (fun en ->
            if not (Hashtbl.mem visited en) && not (Hashtbl.mem t.deleted en) then begin
              Hashtbl.replace visited en ();
              let ed = dist_vec t ~qv ~qn en in
              let fd2 = match Heap.peek res with Some (d, _) -> d | None -> max_float in
              if ed < fd2 || Heap.length res < ef then begin
                Heap.push cands (ed, en);
                Heap.push res (ed, en);
                if Heap.length res > ef then ignore (Heap.pop res)
              end
            end
          ) (get_neighbors t ci layer)
    done;
    let rec drain acc =
      match Heap.pop res with
      | None -> acc
      | Some di -> drain (di :: acc)
    in
    drain []

(* === Algorithm 4: select-neighbors-heuristic === *)

let select_heuristic t _qi cands m _layer =
  if List.length cands <= m then List.map snd cands
  else
    let sorted = List.sort (fun (d1, _) (d2, _) -> compare d1 d2) cands in
    let result = ref [] in
    let rest = ref sorted in
    while List.length !result < m && !rest <> [] do
      match !rest with
      | [] -> ()
      | (ed, ei) :: tl ->
        rest := tl;
        let ok = ref true in
        List.iter (fun ri ->
          if !ok && dist_nodes t ei ri < ed then ok := false
        ) !result;
        if !ok then result := !result @ [ei]
    done;
    !result

(* === Public API === *)

let create ~dimension ?(m = 16) ?(ef_construction = 200) ?(ef_search = 50)
    ?(distance_metric = `Cosine) () =
  if dimension <= 0 then
    Result.Error (Types.Invalid_input (Printf.sprintf "HNSW: dimension must be > 0 (got %d)" dimension))
  else if m <= 0 then
    Result.Error (Types.Invalid_input (Printf.sprintf "HNSW: m must be > 0 (got %d)" m))
  else if ef_construction <= 0 then
    Result.Error (Types.Invalid_input (Printf.sprintf "HNSW: ef_construction must be > 0 (got %d)" ef_construction))
  else if ef_search <= 0 then
    Result.Error (Types.Invalid_input (Printf.sprintf "HNSW: ef_search must be > 0 (got %d)" ef_search))
  else
    Result.Ok {
      dimension; m; m_max0 = 2 * m;
      ef_construction; ef_search; metric = distance_metric;
      nodes = Hashtbl.create 256;
      id_to_index = Hashtbl.create 256;
      index_to_id = Hashtbl.create 256;
      entry_point = None; max_level = -1; next_index = 0;
      deleted = Hashtbl.create 16;
    }

(* Algorithm 1: INSERT *)
let insert t ~id vec =
  if Array.length vec <> t.dimension then
    Result.Error (Types.Invalid_input (Printf.sprintf
      "HNSW.insert: dimension mismatch (expected %d, got %d for id %s)"
      t.dimension (Array.length vec) id))
  else if Hashtbl.mem t.id_to_index id then
    Result.Error (Types.Invalid_input (Printf.sprintf "HNSW.insert: duplicate id '%s'" id))
  else begin
    let vfa = Float.Array.init (Array.length vec) (Array.get vec) in
    let vn = match t.metric with `Cosine -> normalize vfa | `L2 -> vfa in
    let level =
      let r = Random.float 1.0 in
      if r = 0.0 then 0
      else int_of_float (floor (-. log r /. log (float_of_int t.m)))
    in
    let idx = t.next_index in
    t.next_index <- t.next_index + 1;
    let node = { id; vector = vfa; normalized = vn; max_layer = level;
                 edges = Hashtbl.create 8 } in
    Hashtbl.replace t.nodes idx node;
    Hashtbl.replace t.id_to_index id idx;
    Hashtbl.replace t.index_to_id idx id;
    match t.entry_point with
    | None ->
      t.entry_point <- Some idx;
      t.max_level <- level;
      Result.Ok ()
    | Some ep ->
      (* Phase 1: greedy search from top layer to level+1 *)
      let curr = ref [ep] in
      for layer = t.max_level downto level + 1 do
        let r = search_layer t ~qv:vfa ~qn:vn !curr 1 layer in
        curr := List.map snd r
      done;
      (* Phase 2: from min(max_level, level) down to 0 *)
      for layer = min t.max_level level downto 0 do
        let cands = search_layer t ~qv:vfa ~qn:vn !curr t.ef_construction layer in
        let neighbors = select_heuristic t idx cands t.m layer in
        Hashtbl.replace node.edges layer neighbors;
        List.iter (fun ni ->
          let nn = Hashtbl.find t.nodes ni in
          let existing = (match Hashtbl.find_opt nn.edges layer with Some ns -> ns | None -> []) in
          let updated = idx :: existing in
          let mm = max_edges t layer in
          let pruned =
            if List.length updated > mm then
              let cs = List.map (fun i -> (dist_nodes t ni i, i)) updated in
              select_heuristic t ni cs mm layer
            else updated
          in
          Hashtbl.replace nn.edges layer pruned
        ) neighbors;
        curr := List.map snd cands
      done;
      if level > t.max_level then begin
        t.entry_point <- Some idx;
        t.max_level <- level
      end;
      Result.Ok ()
  end

let search t ~query ~k =
  if k <= 0 then []
  else if Array.length query <> t.dimension then
    invalid_arg (Printf.sprintf
      "HNSW.search: dimension mismatch (expected %d, got %d)"
      t.dimension (Array.length query))
  else match t.entry_point with
  | None -> []
  | Some ep ->
    let qfa = Float.Array.init (Array.length query) (Array.get query) in
    let qn = match t.metric with `Cosine -> normalize qfa | `L2 -> qfa in
    let curr = ref [ep] in
    for layer = t.max_level downto 1 do
      let r = search_layer t ~qv:qfa ~qn !curr 1 layer in
      curr := List.map snd r
    done;
    let results = search_layer t ~qv:qfa ~qn !curr t.ef_search 0 in
    let top = take_n results k in
    List.map (fun (d, i) -> (Hashtbl.find t.index_to_id i, d)) top

let delete t ~id =
  match Hashtbl.find_opt t.id_to_index id with
  | None -> Result.Error (Types.Invalid_input (Printf.sprintf "HNSW.delete: id '%s' not found" id))
  | Some idx ->
    Hashtbl.replace t.deleted idx ();
    let node = Hashtbl.find t.nodes idx in
    Hashtbl.iter (fun layer neighbors ->
      List.iter (fun ni ->
        let nn = Hashtbl.find t.nodes ni in
        let existing = (match Hashtbl.find_opt nn.edges layer with Some ns -> ns | None -> []) in
        Hashtbl.replace nn.edges layer (List.filter (fun x -> x <> idx) existing)
      ) neighbors
    ) node.edges;
    (match t.entry_point with
     | Some ep when ep = idx ->
       let best = ref None and bl = ref (-1) in
       Hashtbl.iter (fun i n ->
         if not (Hashtbl.mem t.deleted i) && n.max_layer > !bl then begin
           best := Some i; bl := n.max_layer
         end
       ) t.nodes;
       t.entry_point <- !best;
       t.max_level <- (match !best with Some _ -> !bl | None -> -1)
     | _ -> ());
    Result.Ok ()

let size t = Hashtbl.length t.nodes - Hashtbl.length t.deleted

let save t ~path =
  try
    let oc = open_out_bin path in
    output_string oc "HNSW";
    output_binary_int oc 1;
    Marshal.to_channel oc t [];
    close_out oc;
    Result.Ok ()
  with exn -> Result.Error (Types.Internal (Printf.sprintf "HNSW.save: %s" (Printexc.to_string exn)))

let load ~path =
  try
    let ic = open_in_bin path in
    let magic = really_input_string ic 4 in
    if magic <> "HNSW" then (close_in ic; Result.Error (Types.Internal "HNSW.load: bad magic"))
    else begin
      let ver = input_binary_int ic in
      if ver <> 1 then (close_in ic; Result.Error (Types.Internal (Printf.sprintf "HNSW.load: unsupported version %d" ver)))
      else begin
        let t : t = Marshal.from_channel ic in
        close_in ic; Result.Ok t
      end
    end
  with exn -> Result.Error (Types.Internal (Printf.sprintf "HNSW.load: %s" (Printexc.to_string exn)))

let close t =
  Hashtbl.clear t.nodes;
  Hashtbl.clear t.id_to_index;
  Hashtbl.clear t.index_to_id;
  Hashtbl.clear t.deleted;
  t.entry_point <- None;
  t.max_level <- -1
