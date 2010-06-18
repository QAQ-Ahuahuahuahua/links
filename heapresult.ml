open Printf
open Utility

module A = Algebra
module FieldEnv = Utility.StringMap

exception Runtime_error = Errors.Runtime_error

type implementation_type = [ `List | `Atom ]

module XmlSqlPlan : sig
  val extract_queries : string -> (int * ((string * (int * string) list) * string * implementation_type option))
      list
end =
struct
  type tree = E of Xmlm.tag * tree list | D of string

  let in_tree i = 
    let el tag childs = E (tag, childs)  in
    let data d = D d in
      Xmlm.input_doc_tree ~el ~data i

  let filter_whitespace_els l =
    List.filter (function E _ -> true | D _ -> false) l

  let find_el elements name =
    let p = function
      | E (((_, elname), _), _) -> name = elname
      | _ -> false
    in
      List.find p elements

  let lookup_attr attributes name =
    let p ((_, n), _) = n = name in
      snd (List.find p attributes)

  let find_property_value elements name =
    let p = function
      | E (((_, "property"), attrs), _) ->
	  List.exists 
	    (fun ((_, attr_name), propname) -> 
	       propname = name
		&& attr_name = "name") 
	    attrs
      | _ -> false
    in
      try 
	match List.find p elements with
	  | E (((_, "property"), attrs), _) ->
	      snd (List.find (fun ((_, attr_name), _) -> attr_name = "value") attrs)
	  |_ -> assert false
      with NotFound _ -> assert false

  let collect_column = function
    | E (((_, "column"), attrs), []) ->
	let name = lookup_attr attrs "name" in
	let funct = lookup_attr attrs "function" in
	  if funct = "item" then
	    let pos = 1 + (int_of_string (lookup_attr attrs "position")) in
	      `Item (pos, name)
	  else if funct = "iter" then
	    `Iter (name)
	  else
	    assert false
    | _ -> assert false

  let collect_schema = function
    | E (((_, "schema"), _), childs) ->
	let cols = List.map collect_column (filter_whitespace_els childs) in
	let rec iter l = 
	  (match l with
	     | (`Iter name) :: _ -> name
	     | (`Item _) :: xs -> iter xs
	     | [] -> assert false)
	in
	let rec item l =
	  (match l with
	     | (`Iter _) :: xs -> item xs
	     | (`Item (pos, name)) :: xs -> (pos, name) :: (item xs)
	     | [] -> [])
	in
	  (iter cols, item cols)
    | _ -> assert false

  let collect_query = function
    | E (((_, "query"), _), [D query]) -> query
    | _ -> assert false

  let collect_properties = function
    | E (((_, "properties"), _), childs) ->
	find_property_value childs "overallResultType"
    | _ -> assert false

  let implementation_type_of_string = function
    | "LIST" -> `List
    | "TUPLE" -> `Atom
    | _ -> assert false

  let collect_plan = function
    | E (((_, "query_plan"), attrs), childs) ->
	(try 
	   let id = int_of_string (lookup_attr attrs "id") in
	   let schema = collect_schema (find_el childs "schema") in
	   let query = collect_query (find_el childs "query") in
	     if id = 0 then
	       let result_type = collect_properties (find_el childs "properties") in
	       let itype = implementation_type_of_string result_type in
		 (id, (schema, query, Some itype))
	     else
	       (id, (schema, query, None))
	 with NotFound _ -> 
	   assert false)
    | _ -> assert false

  let collect_plans = function
    | E (((_, "query_plan_bundle"), []), childs) ->
	List.map collect_plan (filter_whitespace_els childs)
    | _ -> assert false

  let extract_queries xmlstring =
    let xml_input = Xmlm.make_input (`String (0, xmlstring)) in
      collect_plans (snd (in_tree xml_input))
end

exception ColumnMappingError of string
exception ItemAccessError of int

type accessor_functions = (int -> int -> string) * (int -> string) * int
type itbls = (int * table_struct) list
and table_struct = Table of (accessor_functions * Cs.cs * itbls * implementation_type option)

type field_name = string
type atom_type =
  [ `Primitive of Algebra.column_type
  | `Record of field_name list ]

(* Create functions which encapsulate the access to one table's 
   item and iter fields. *)
let table_access_functions (iter_schema_name, offsets_and_schema_names) dbvalue : accessor_functions = 
  let result_fields = fromTo 0 dbvalue#nfields in
  let result_names = List.map (fun i -> (dbvalue#fname i, i)) result_fields in
   (* List.iter (fun (s, i) -> Debug.f "%s = %d " s i) result_names;
    Debug.print ""; *)
  let nr_tuples = dbvalue#ntuples in
  let nr_fields = dbvalue#nfields in
  let find_field col_name = 
    try
      let startswith s1 s2 = 
	let len = String.length s2 in
	  (String.sub s1 0 len) = s2
      in
      let pred (name, _) = startswith name (col_name ^ "_") in
	snd (List.find pred result_names)
    with NotFound _ -> 
      raise (ColumnMappingError col_name)
  in
  let iter_field = find_field iter_schema_name in
    assert (iter_field < nr_fields);
    let offsets_to_fields = 
      List.map 
	(fun (offset, schema_name) ->
	   (offset, find_field schema_name))
	offsets_and_schema_names
    in
    (* let foo = List.map (fun (offset, col) -> sprintf "(%d -> %d)" offset col) offsets_to_fields in 
      Debug.print (mapstrcat " " (fun x -> x) foo);  *)
    let item row offset = 
      (* Debug.f "item access %d\n" offset; *)
      try 
	assert (row < nr_tuples);
	let field = List.assoc offset offsets_to_fields in
	  assert (field < nr_fields);
	  dbvalue#getvalue row field
      with Not_found -> raise (ItemAccessError offset)
    in
    let iter row =
      assert (row < nr_tuples);
      dbvalue#getvalue row iter_field
    in
      (item, iter, dbvalue#ntuples)

let execute_query database query =
  if Settings.get_value Basicsettings.Ferry.print_sql_queries then
    Debug.print (">>>> Executing query\n" ^ query);
  let dbresult = (database#exec query) in
    match dbresult#status with
      | `QueryError msg -> 
	  raise(Runtime_error("An error occurred executing the query " ^ query ^
                                ": " ^ msg))
      | _ -> dbresult

(* reconstruct the itbls tree structure from colref/idref *)
let reconstruct_itbls root_acc root_cs root_result_type result_bundle : table_struct =
  (* construct Table values *)
  let refs = 
    List.map
      (fun (id, (refid, refcol), acc, _, cs, result_type) ->
	 let table = Table (acc, cs, [], result_type) in
	   (refid, (id, refcol, table)))
      result_bundle
  in
  (* predicate for List.filter *)
  let p wanted_key entry = 
    match entry with
      | (key, _value) when wanted_key = key -> true
      | _ -> false
  in
  (* reconstruct itbl tree from flat (refid, refcol) information *)
  let rec assemble_tree parent_id parent_table =
    let childs = List.filter (p parent_id) refs in
    let itbls = 
      List.map 
	(fun (_, (id, refcol, table)) -> 
	   (refcol, (assemble_tree id table))) 
	childs 
    in
    let Table (acc, cs, _, t) = parent_table in
      Table (acc, cs, itbls, t)
  in
    assemble_tree 0 (Table (root_acc, root_cs, [], root_result_type))

let transform_and_execute database xml_sql_bundle algebra_bundle = 
  let (_, root_cs, sub_algebra_plans) = algebra_bundle in
  let sql_plans = XmlSqlPlan.extract_queries xml_sql_bundle in
  (* combine the sql queries with the corresponding cs component and idref/colref *)
  let rec merge sql_bundle =
    match sql_bundle with
      | (0, _) :: sql_bundle -> merge sql_bundle
      | (id, (schema, query, result_type)) :: sql_bundle ->
	  (try
	    let (refs, _, cs) = List.assoc id sub_algebra_plans in
	      (id, refs, query, schema, cs, result_type) :: (merge sql_bundle)
	  with NotFound _ -> assert false)
      | [] -> []
  in
  let (root_schema, root_query, root_result_type) =
    try
      List.assoc 0 sql_plans
    with Not_found -> assert false
  in
  let plan_bundle = merge sql_plans in
  let result_bundle = 
    List.map
      (fun (id, refs, query, schema, cs, result_type) ->
	 let dbresult = execute_query database query in
	   (id, refs, (table_access_functions schema dbresult), schema, cs, result_type))
      plan_bundle
  in
  let root_result = execute_query database root_query in
  let root_access = table_access_functions root_schema root_result in
    reconstruct_itbls root_access root_cs root_result_type result_bundle

let mk_primitive raw_value t = 
  match t with
    | `IntType -> Value.box_int (Num.num_of_string raw_value)
    | `StrType -> Value.string_as_charlist raw_value
    | `BoolType -> Value.box_bool ((int_of_string raw_value) = 1)
    | `CharType -> Value.box_char (String.get raw_value 0)
    | `FloatType -> (if raw_value = "" then Value.box_float 0.00      (* HACK HACK *)
                     else Value.box_float (float_of_string raw_value))
    | `NatType -> failwith "Heapresult.mk_primitive: nat is not a Links type"
    | `Surrogate -> assert false 

let rec mk_record itbl_offsets field_names cs (item : int -> string) itbls =
   let mk_field (next_offsets, record) field_name =
     let field_cs = Cs.lookup_record_field cs field_name in
(*       Debug.print (Cs.print cs);
       Debug.print ("mk_record " ^ field_name); *)
     let (new_offsets, value) = handle_row next_offsets item field_cs itbls in
       (new_offsets, ((field_name, value) :: record))
   in
   let (new_offsets, values) = List.fold_left mk_field (itbl_offsets, []) field_names in
     (new_offsets, `Record values)

and handle_row itbl_offsets item cs itbls = 
  let typ = Cs.atom_type cs in
  match typ with
    | `Primitive `Surrogate ->
	let col = 
	  (match cs with
	     | [`Offset (i, `Surrogate)] -> i
	     | cs -> failwith ("Heapresult.handle_row: cs in no inner list surrogate column " ^
				 (Cs.show cs)))
	in
	let offset = 
	  match itbl_offsets with
	    | Some offsets ->
		(try
		  List.assoc col offsets
		with NotFound _ -> 0)
	    | None -> 0
	in
	let itbl = 
	  try
	    List.assoc col itbls
	  with NotFound _ -> assert false
	in
	let surrogate_key = int_of_string (item col) in
	let (next_offset, value) = handle_inner_table surrogate_key offset itbl in
	let new_offsets =
	  match itbl_offsets with
	    | Some offsets ->
		Some ((col, next_offset) :: (remove_keys offsets [col]))
	    | None ->
		Some [col, next_offset]
	in
	  (new_offsets, value)
    | `Primitive t -> 
	let col =
	  (match cs with
	    | [`Offset (i, _)] -> i
	    | _ -> failwith "Heapresult.handle_row: cs does not represent a primitive value")
	in
	let raw_value = item col in
	  (itbl_offsets, mk_primitive raw_value t)
    | `Record field_names -> 
	mk_record itbl_offsets field_names cs item itbls

and handle_table (Table ((item, _, nr_tuples), cs, itbls, result_type)) = 
  (* Debug.print "handle_table"; *)
  (* Debug.print (Cs.print cs); *)
  let restype = match result_type with
    | Some t -> t 
    | None -> assert false
  in
  match restype with
    | `Atom ->
	assert (nr_tuples = 1);
	snd (handle_row None (item 0) cs itbls)
    | `List ->
	let rec loop_tuples i row_values offsets =
	  if i = nr_tuples then
	    (offsets, List.rev row_values)
	  else
	    let col_value = item i in
	    let (next_offsets, row_value) = handle_row offsets col_value cs itbls in
	      loop_tuples (i + 1) (row_value :: row_values) next_offsets
	in
	  `List (snd (loop_tuples 0 [] None))
	
and handle_inner_table surrogate_key offset (Table ((item, iter, nr_tuples), cs, itbls, _)) =
  (* Debug.f "handle_inner_table surr_key %d offset %d nr_tuples %d" surrogate_key offset nr_tuples; *)
  (* Debug.print (Cs.print cs); *)
  let rec loop_tuples i row_values inner_offsets =
    if i = nr_tuples then
      (i - 1), (List.rev row_values)
    else
      let iter_val = int_of_string (iter i) in
	if surrogate_key < iter_val then
	  if i = 0 then
	    (0, (List.rev row_values))
	  else
	    (i - 1), (List.rev row_values)
	else if surrogate_key = iter_val then
	  let (new_inner_offsets, row_value) = handle_row inner_offsets (item i) cs itbls in
	    loop_tuples (i + 1) (row_value :: row_values) new_inner_offsets
	else
	  loop_tuples (i + 1) row_values inner_offsets
  in
  let (next_offset, values) = loop_tuples offset [] None in
    (next_offset, `List values)
