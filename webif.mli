(** Web interface *)

open Webserver_types
open Ir
open Proc
open Value

module WebIf : functor (Webs : WEBSERVER) ->
sig

  val do_request :
    (Value.env * Ir.var Env.String.t * Types.typing_environment) ->
    (string * string) list ->
    (unit -> string * string) ->
    Value.continuation ->
    ((string * string) list -> string -> 'b) ->
    'b

  val serve_request :
    (Value.env * Ir.var Env.String.t * Types.typing_environment) ->
    (Ir.binding list) ->
    string ->
    unit

end
