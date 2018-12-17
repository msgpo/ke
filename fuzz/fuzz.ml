type 'a action =
  | Push of 'a * 'a action
  | Pop of 'a action
  | Empty

exception Invalid

external identity : 'a -> 'a = "%identity"

let valid a =
  let rec go k = function
    | Empty -> k 0
    | Push (_, a) -> go (fun len -> k (succ len)) a
    | Pop a -> go (function 0 -> raise Invalid | n -> k (pred n)) a
  in go identity a

let push x a = Push (x, a)
let empty = Empty
let pop a = Pop a

let () = assert (valid empty = 0)
let () = assert (valid (push 0 empty) = 1)
let () = assert (valid (push 1 (push 0 empty)) = 2)
let () = assert (valid (pop (push 0 empty)) = 0)
let () = assert (match valid (pop empty) with _ -> false | exception Invalid -> true)

module Peano = struct
  type zero = Zero
  type 'a succ = Succ
end

module Refl = struct
  type ('a, 'b) t = Refl : ('a, 'a) t
end

module Value = struct
  type 'a value =
    | Zero : Peano.zero value
    | Succ : 'a value -> 'a Peano.succ value
  type t = V : 'a value -> t

  let of_int n =
    let rec go k = function
      | 0 -> k (V Zero)
      | n -> go (fun (V n) -> k (V (Succ n))) (pred n) in
    if n < 0
    then Fmt.invalid_arg "Value.of_int"
    else go identity n

  let to_int v =
    let rec go : type a. (int -> 'r) -> a value -> 'r = fun k -> function
    | Zero -> k 0
    | Succ x -> go (fun v -> k (succ v)) x in
    go identity v

  let () = assert (to_int Zero = 0)
  let () = assert (to_int (Succ Zero) = 1)
  let () = assert (to_int (Succ (Succ Zero)) = 2)

  let pp : t Fmt.t = fun ppf (V v) -> Fmt.int ppf (to_int v)

  let is_zero : type a. a value -> (a, Peano.zero) Refl.t option = function
    | Zero -> Some Refl.Refl
    | Succ _ -> None

  type 'a is_not_zero = Is_not_zero : ('a, _ Peano.succ) Refl.t -> 'a is_not_zero

  let is_not_zero : type a. a value -> a is_not_zero option = function
    | Zero -> None
    | Succ _ -> Some (Is_not_zero Refl.Refl)
end

module Stack = struct
  type ('a, 'l) action =
    | Push : 'a * ('a, 'l) action -> ('a, 'l Peano.succ) action
    | Pop : ('a, 'l Peano.succ) action -> ('a, 'l) action
    | Empty : ('a, Peano.zero) action
  type 'a t = V : ('a, 'l) action -> 'a t

  let rec pp : type l. 'a Fmt.t -> ('a, l) action Fmt.t = fun pp_elt ppf -> function
    | Push (v, a) -> Fmt.pf ppf "@[<1>(Push %a)]" Fmt.(Dump.pair pp_elt (pp pp_elt)) (v, a)
    | Pop a -> Fmt.pf ppf "@[<1>(Pop %a)]" (pp pp_elt) a
    | Empty -> Fmt.pf ppf "Empty"

  let rec length : type a l. (a, l) action -> l Value.value = function
    | Empty -> Value.Zero
    | Pop a -> (match length a with Value.Succ x -> x)
    | Push (_, a) -> Value.Succ (length a)

  let is_empty : type l. ('a, l) action -> (l, Peano.zero) Refl.t option = function
    | Empty -> Some Refl.Refl
    | Push _ -> None
    | Pop a -> match length a with
      | Value.Succ Value.Zero -> Some Refl.Refl
      | Value.Succ _ -> None

  type 'a is_not_empty = Is_not_empty : ('a, _ Peano.succ) Refl.t -> 'a is_not_empty

  let is_not_empty : type l. ('a , l) action -> l is_not_empty option = function
    | Empty -> None
    | Push _ -> Some (Is_not_empty Refl.Refl)
    | Pop a -> match length a with
      | Value.Succ Value.Zero -> None
      | Value.Succ (Value.Succ _) -> Some (Is_not_empty Refl.Refl)
end

open Crowbar

[@@@warning "-32"]

let generate =
  let value = map [ range 30 ] Value.of_int in
  fix @@ fun m ->
  dynamic_bind (choose [ const `Push ; const `Pop ; const `Empty ]) @@ function
  | `Empty -> const Stack.(V Empty)
  | `Push -> map [ m; value ] (fun (Stack.V a) v -> Stack.(V (Push (v, a))))
  | `Pop ->
    map [ m ] @@ fun (Stack.V a) ->
    match Stack.is_not_empty a with
    | Some (Stack.Is_not_empty Refl.Refl) -> Stack.V (Stack.Pop a)
    | None -> bad_test () (* XXX(dinosaure): I use, GADT only for this case. *)

let generate =
  let value = map [ range 30 ] Value.of_int in
  let go (Stack.V a) =
    map [ choose [ const `Push ; const `Pop ; const `Empty ]; value ] @@ fun c v -> match c with
    | `Empty -> Stack.(V a)
    | `Push -> let open Stack in V (Push (v, a))
    | `Pop ->
      match Stack.is_not_empty a with
      | Some (Stack.Is_not_empty Refl.Refl) -> Stack.(V (Pop a))
      | None -> bad_test () in
  let rec loop acc = function
    | 0 -> const acc
    | n -> dynamic_bind (go acc) (fun acc -> loop acc (pred n)) in
  loop (V Stack.Empty) 100

(* XXX(dinosaure): [Stdlib.Queue] is oracle. *)

module Compare = struct
  exception Not_equal

  let mke q mke =
    let q' = Queue.copy q in
    try Ke.Mke.iter (fun x -> let x' = Queue.pop q' in if x <> x' then raise Not_equal) mke ; true
    with Not_equal | Queue.Empty -> false

  let fke q fke =
    let q' = Queue.copy q in
    try Ke.Fke.iter (fun x -> let x' = Queue.pop q' in if x <> x' then raise Not_equal) fke ; true
    with Not_equal | Queue.Empty -> false
end

let iter iter pp_name pp_elt ppf v =
  let is_first = ref true in
  let pp_elt v =
    if !is_first then (is_first := false) else Fmt.pf ppf "@ ";
    Fmt.pf ppf "@[%a@]" pp_elt v
  in
  Fmt.pf ppf "@[<1>(%a@ " pp_name v;
  iter pp_elt v;
  Fmt.pf ppf ")@]"

let pp_fke pp_elt = iter Ke.Fke.iter (Fmt.always "fke") pp_elt
let pp_mke pp_elt = iter Ke.Mke.iter (Fmt.always "mke") pp_elt

let mke_of_action a =
  let q = Ke.Mke.create ~capacity:(Value.to_int (Stack.length a)) () in
  let rec go : type l. (Value.t, l) Stack.action -> unit = function
    | Stack.Empty -> ()
    | Stack.Push (Value.V v, a) -> go a ; Ke.Mke.push q (Value.to_int v)
    | Stack.Pop a -> go a ; ignore @@ Ke.Mke.pop_exn q in
  go a ; q

let queue_of_action a =
  let q = Queue.create () in
  let rec go : type l. (Value.t, l) Stack.action -> unit = function
    | Stack.Empty -> ()
    | Stack.Push (Value.V v, a) -> go a ; Queue.push (Value.to_int v) q
    | Stack.Pop a -> go a ; ignore @@ Queue.pop q in
  go a ; q

let fke_of_action a =
  let rec go : type l. (int Ke.Fke.t -> 'r) -> (Value.t, l) Stack.action -> 'r = fun k -> function
    | Stack.Empty -> k Ke.Fke.empty
    | Stack.Push (Value.V v, a) -> go (fun q -> let q = Ke.Fke.push q (Value.to_int v) in k q ) a
    | Stack.Pop a -> go (fun q -> let _, q = Ke.Fke.pop_exn q in k q) a in
  go identity a

let () =
  add_test ~name:"queue" [ generate ] @@ fun (Stack.V a) ->
  let fke = fke_of_action a in
  let mke = mke_of_action a in
  let queue = queue_of_action a in

  if not (Compare.mke queue mke)
  then failf "%a <> %a" Fmt.(Dump.queue int) queue (pp_mke Fmt.int) mke ;
  if not (Compare.fke queue fke)
  then failf "%a <> %a" Fmt.(Dump.queue int) queue (pp_fke Fmt.int) fke
