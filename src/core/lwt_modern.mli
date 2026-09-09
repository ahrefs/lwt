(** lwt-modern is a new interface for Lwt.

Lwt has a serious historical bagage issue: there is an accumulation of functions introduced at different time under different stewardship following different conventions.

Lwt-modern presents a clean rewrite of the Lwt interface. The underlying concept of promise is kept as-is. Indeed, the type of promises is that of classic Lwt.

Lwt-modern provides:
  - new concepts (most notably /progress/) to present a better mental model of what the library does
  - a small amount of structure in the concurrency model (via /zones/).
  - a new cancellation mechanism
  - a separation of different parts of the interface into different namespaces

At first, lwt-modern is intended to be built on top of the existing Lwt implementation.
Later, lwt-modern is inteded to be the implementation on top of which the legacy interface is implemented.

*)

(**

# Promises and Progress.

/Promises/ are the values of type `Lwt.t`. They are just that: values. Well they are values which hold some state which can change during the lifetime of the program. The possible states and transitions are as follows:

```
             /------> resolved
  pending --|
             \------> rejected
```


/Progress/ is the computations, system calls, and synchronisation mechanisms which lead to promises resolving (or rejecting). Progress is driven by the scheduler and the rest of the Lwt machinery.

Promises and Progress are the two-sides of the same Lwt concurrency model. Lwt was originally presented as a thread library (from which we get the "t" of Lwt) focusing on the progress and the execution. It was later re-documented as a promise library focusing on the stateful placeholder. The truth is that both views apply. But the current documentation and API lacks the words to describe the duality and so it gets muddled into a long-winded explanations including implementation details (e.g., cancel, wakeup).

Lwt-modern mentions both promises and progress explicitly and endeavours to provide a mental model that is complete enough that functions can be documented without resorting to mentioning the implementation.

## A small example

Considering the following expression

```
let* () = Lwt_io.write Lwt_io.stdout "name?" in
let* name =
  Lwt.pick [
    Lwt_io.read_line Lwt_io.stdin;
    begin let* () = Lwt_unix.sleep 1. in Lwt.return "" end;
  ]
in
let dest = if name = "" then "World" else name in
Lwt_io.write Lwt_io.stdout ("Hello " ^ dest)
```

The expression evaluates immediately to a pending Promise. But also, the expression immediately triggers some side-effects which eventually lead to the promise resolution: the expression sets the Progress for the Promise in motion.

When this promise makes progress towards resolution, multiple things happen:
- Side-effects (writes and reads) happen.
- Intermediary Promises are created and resolved (and cancelled).
- The scheduler state is changed. The internal state of intermediate promises is changed.

A short aside on intermediary promises:
These promises only exist within the various scopes of the sub-expressions, they are innaccessible to the outside.
They are still promises in the same way that the whole expression is a promise.
For all we know, this small example we are looking at is part of the progress for a larger promise and actually innaccessible to the larger program.

Now consider the equivalent expression rewritten in a somewhat strange style. The new style binds intermediate values to new identifiers to better separate the promises syntactically.

```
let* () = Lwt_io.write Lwt_io.stdout "name?" in
let read_name = Lwt_io.read_line Lwt_io.stdin in
let timeout =
  let* () = Lwt_unix.sleep 1. in
  Lwt.return ""
in
let* name = Lwt.pick [ read_name; timeout ] in
let dest = if name = "" then "World" else name in
Lwt_io.write Lwt_io.stdout ("Hello " ^ dest)
```

We can handwavedly trace the execution of the progress. For this purpose, we consider an execution where the timeout resolves (and the `read_line` doesn't).

```
let* () = Lwt_io.write Lwt_io.stdout "name?" in         |  ⌜⌜·⌟
let read_name = Lwt_io.read_line Lwt_io.stdin in        |      ⌜·······⌟
let timeout =                                           |       ⌜
  let* () = Lwt_unix.sleep 1. in                        |        ⌜·⌟
  Lwt.return ""                                         |           ⌜⌟
in                                                      |             ⌟
let* name = Lwt.pick [ read_name; timeout ] in          |         ⌜     ⌟
let dest = if name = "" then "World" else name in       |                ⌜
Lwt_io.write Lwt_io.stdout ("Hello " ^ dest)            |                 ·⌟⌟
```

The central dots (·) represent the places where progress is not immediate, places where the scheduler is involved.
The pairs of corners (⌜⌟) represent the lifetime of promises. They are spread horizontally to show the sequence of happenstances which make the progress and vertically to show the structure of the program with its binds.


 *)

(*

# Zones

/Zones/ are scopes you can use to structure progress.

Zones are ambient: there is always a zone that progress happens inside of. It might be the default top-level zone if you haven't explicitly added one.

Zones are hierarchical: if you create a zone, it is a subzone of the current zone.

The basic use-case for zones is to structure the computation into different parts. Think of a program with multiple concurrent main loops (one to answer RPC queries, one to read stdin and print on stdout, one to periodically save state to disk): you execute each of these into a different zone. (And you subdivide further into sub-zones if needs be.)

What the zones give you is a way to structure your concurrency. Specifically you can:
- Wait for a zone to finish: you attach your asynchronous task to a zone, the zone's main promise resolves only once all the asynchronous tasks have resolved (see `dont_wait` below)
- Set your granularity for cancelation: you cancel a whole zone. All the progress within it stops. All the unresolved promises within get rejected with `Cancelled`.


 *)


(* The top-level of lwt-modern is intended for general use. *)

(* promises are first-class values, do what you will (although don't polycompare) *)
type 'a t = 'a Lwt.t

(* a distinct module so you can bring just the essential into your scope. also open Infix or Let, unless you are using the ppx *)
module OpenMe : sig
  type 'a promise = 'a Lwt.t
  val return : 'a -> 'a t
  val pause : unit -> unit t
end
include OpenMe
module Infix : sig
  val (>>=) : 'a t -> ('a -> 'b t) -> 'b t
  val (>|=) : 'a t -> ('a -> 'b) -> 'b t
end
module Let : sig
  val (let*) : 'a t -> ('a -> 'b t) -> 'b t
  val (and*) : 'a t -> 'b t -> ('a * 'b) t
end

val bind : 'a t -> ('a -> 'b t) -> 'b t
val match_ : (unit -> 'a t) -> ?exc:(exn -> 'b t) -> ('a -> 'b t) -> 'b t
val finalize : (unit -> 'a t) -> (unit -> unit t) -> 'a t
val both : 'a t -> 'b t -> ('a * 'b) t
val all : 'a t list -> 'a list t
val join : unit t list -> unit t
val first : 'a t list -> 'a t
val firstn : 'a t list -> ('a list * 'a t list) t
val map: 'a t -> ('a -> 'b) -> 'b t

type zone
val zone :
  ?async_exn_handler:(exn -> unit t) ->
  ?finalize:(unit -> unit t) ->
  (zone -> 'a t) ->
  'a t
val dont_wait : ?zone:zone -> (unit -> unit t) -> unit

(* await for direct-style programming, only works when in a zone, but always in the zone anyway *)
val await : 'a t -> 'a

(* integrated awaiting *)
module Direct : sig
  val pause : unit -> unit
  val first : 'a list -> 'a
  val join : unit list -> unit
  module Unix : sig
    (* TODO: ~ the Lwt_unix module but with await applied *)
  end
end



(* Librarian is for users who are writing a library on top of Lwt. Think writing `Aches`' `Lache`, or `Lwt_pipeline`, or `Lwt_exit`, or `Lwt_seq`, or `Lwt_list`, etc. Basically, when you are defining new abstractions or significantly extending the abstractions of Lwt, you likely need `Librarian`. *)
module Librarian : sig

    (* cancel a whole zone. no progress ever happens in this zone. promises of the zone are marked as rejected with `Cancelled`. *)
  val cancel : zone -> unit
  val cancel_self : unit -> unit

  (* cancels the zones of all the unresolved promises at the end *)
  val first_and_cancel : 'a t list -> 'a t

  (* on_ attaches explicit callbacks to a promise, normal use should  *)
  val on_: 'a t -> ?resolve:('a -> unit) -> ?reject:(exn -> unit) -> unit -> unit

  (* manually resolving promises *)
  type 'a resolver = 'a Lwt.u

  (* create a manually resolving promise. the promise is attached to the ambient zone. *)
  val resolvable : unit -> ('a Core.promise * 'a resolver)

  (* interrupt current progress and switch to progress on the given resolver. current progress will be resumed later by the scheduler. *)
  val yield_to : 'a u -> 'a -> unit Core.t

  (* continue with the current progress. when next the scheduler takes back control, it'll resolve the promise associated to the given resolver.

     note that the scheduler will do this as well as all its other tasks. there are no guarantess about the order it'll perform the tasks.

     @raise Failure if the resolver has already been scheduled for resolution by another promise's progress.
   *)
  val schedule_for_resolution : 'a u -> 'a -> unit

  (* an already resolved promise. alias for Core.return *)
  val resolved : 'a -> 'a t

  (* an already rejected promise. this should be used for populating data-structures with placeholder failures. *)
  val rejected : exn -> 'a t

end

(* Debugger is for users who are debugging their program. These shouldn't appear in code as it breaks abstraction. But breaking abstraction is useful for debugging. *)
module Debugger : sig
  type 'a state =
    | Resolved of 'a
    | Rejected of exn
    | Pending
  val state : 'a Core.t -> 'a state
end
