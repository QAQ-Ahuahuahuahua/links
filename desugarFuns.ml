open Utility
open Sugartypes

(*
    fun f[qs](xs1)...(xsk) {e}
  -->
    fun f[qs](xs1) {
      fun f2(xs2) {
        ...
        fun fk(xsk) {
          e
        }
        fk
        ...
      }
      f2
    }


    fun [qs](xs1)...(xsk) {e}
  -->
    {fun f[qs](xs1)...(xsk) {e};
     f}
*)


let dp = Sugartypes.dummy_position

(* unwrap a curried function definition as
   a collection of nested functions
*)
let unwrap_def ((f, Some ft, fpos), (tyvars, lam), location, t) =
  let rt = TypeUtils.return_type ft in
  let lam =
    let rec make_lam t : funlit -> funlit =
      function
        | ([ps], body) as lam -> lam
        | (ps::pss, body) ->
            let g = gensym ~prefix:"_fun_" () in
            let rt = TypeUtils.return_type t in
              ([ps],
               (`Block
                  ([`Fun ((g, Some t, dp),
                          ([], make_lam rt (pss, body)),
                          location,
                          None), dp],
                   ((`Var g), dp)), dp))   
    in
      make_lam rt lam
  in
    ((f, Some ft, fpos), (tyvars, lam), location, t)

(*
  unwrap a curried function definition
  with a position attached
  (for recursive functions)
*)
let unwrap_def_dp (fb, tlam, location, t, pos) =  
  let (fb, tlam, location, t) = unwrap_def (fb, tlam, location, t) in
    (fb, tlam, location, t, pos)

class desugar_funs {Types.var_env=var_env; Types.tycon_env=tycon_env} =
object (o : 'self_type)
  inherit (TransformSugar.transform (var_env, tycon_env)) as super

  method phrasenode : Sugartypes.phrasenode -> ('self_type * Sugartypes.phrasenode * Types.datatype) = function
    | `FunLit (Some argss, lam) ->
        let inner_mb = snd (last argss) in
        let (o, lam, rt) = o#funlit inner_mb lam in
        let ft =
          List.fold_right
            (fun (args, mb) rt ->
               `Function (args, mb, rt))
            argss
            rt in
        let f = gensym ~prefix:"_fun_" () in
        let e =
          `Block
            ([`Fun (unwrap_def ((f, Some ft, dp), ([], lam), `Unknown, None)),
              dp],
             ((`Var f), dp))
        in
          (o, e, ft)
    | e -> super#phrasenode e

  method bindingnode = function
    | `Fun _ as b ->
        let (o, b) = super#bindingnode b in
          begin
            match b with
              | `Fun r -> (o, `Fun (unwrap_def r))
              | _ -> assert false
          end
    | `Funs _ as b ->
        let (o, b) = super#bindingnode b in
          begin
            match b with
              | `Funs defs -> (o, `Funs (List.map unwrap_def_dp defs))
              | _ -> assert false
          end
    | b -> super#bindingnode b
end

let desugar_funs env = ((new desugar_funs env) : desugar_funs :> TransformSugar.transform)

let has_no_funs =
object
  inherit SugarTraversals.predicate as super

  val has_no_funs = true
  method satisfied = has_no_funs

  method phrasenode = function
    | `FunLit _ -> {< has_no_funs = false >}
    | e -> super#phrasenode e

  method bindingnode = function
    | `Fun (_f, (_tyvars, ([_ps], _body)), _location, _t) as b ->
        super#bindingnode b
    | `Fun _ -> {< has_no_funs = false >}
    | `Funs defs as b ->
        if
          List.exists
            (function
               | (_f, (_tyvars, ([_ps], _body)), _location, _t, _pos) -> false
               | _ -> true) defs
        then
          {< has_no_funs = false >}
        else
          super#bindingnode b
    | b -> super#bindingnode b
end