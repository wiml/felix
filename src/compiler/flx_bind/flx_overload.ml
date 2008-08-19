open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_set
open Flx_mtypes2
open Flx_print
open Flx_exceptions
open Flx_typing
open Flx_typing2
open List
open Flx_srcref
open Flx_unify
open Flx_beta
open Flx_generic
open Flx_tconstraint
open Flx_tpat
open Flx_maps

exception OverloadKindError of range_srcref * string

type overload_result =
 int *  (* index of function *)
 btypecode_t * (* type of function signature *)
 btypecode_t * (* type of function return *)
 (int * btypecode_t) list * (* mgu *)
 btypecode_t list (* ts *)

type result =
  | Unique of overload_result
  | Fail

let dfltvs_aux = { raw_type_constraint=`TYP_tuple []; raw_typeclass_reqs=[]}
let dfltvs = [],dfltvs_aux


let get_data table index : symbol_data_t =
  try Hashtbl.find table index
  with Not_found ->
    failwith ("[Flx_lookup.get_data] No definition of <" ^ string_of_int index ^ ">")

let sig_of_symdef symdef sr name i = match symdef with
  | `SYMDEF_match_check (_)
    -> `TYP_tuple[],`TYP_sum [`TYP_tuple[];`TYP_tuple[]],None (* bool *)

  (* primitives *)
  | `SYMDEF_fun (_,ps,r,_,_,_)
    -> typeof_list ps,r,None

  | `SYMDEF_callback (_,ts_orig,r,_)
    ->
      let ts_f =
        filter
        (function
          | `AST_name (_,id,[]) when id = name -> false
          | t -> true
        )
        ts_orig
      in
      let tf_args = match ts_f with
        | [x] -> x
        | lst -> `TYP_tuple lst
      in
      let tf = `TYP_function (tf_args, r) in

      (* The type of the arguments Felix thinks the raw
         C function has on a call. A closure of this
         function is a Felix function .. NOT the raw
         C function.
      *)
      let ts_cf =
        map
        (function
          | `AST_name (_,id,[]) when id = name -> tf
          | t -> t
        )
        ts_orig
      in
      typeof_list ts_cf,r,None

  | `SYMDEF_function (ps,r,_,_)
    ->
    let p = fst ps in
    begin match p,r with
    (*
    | (`PRef,_, r)::tail,`AST_void _
    (* | (`PVal,_,`TYP_pointer r)::tail,`AST_void _ *) ->
      print_endline "Mangled Procedure Overload";
      paramtype tail,r
    *)

    | _ ->
      paramtype p,r,Some (map (fun (_,name,_,d)->name,d) p)
    end

  | `SYMDEF_cstruct ls
  | `SYMDEF_struct ls ->
    typeof_list (map snd ls),`AST_index (sr,name,i),
     Some (map (fun (p,_) -> p,None) ls)

  | `SYMDEF_const_ctor (_,r,_,_) -> `AST_void sr,r,None
  | `SYMDEF_nonconst_ctor (_,r,_,_,t) -> t,r,None
  | `SYMDEF_type_alias t ->
    (*
    print_endline ("[sig_of_symdef] Found a typedef " ^ name);
    *)
    begin match t with
    | `TYP_typefun (ps,r,b) -> 
      (*
      print_endline "TYP_typefun";
      *)
      typeof_list (map snd ps),r,None
    | `TYP_case _ -> `TYP_type,`TYP_type,None
    | symdef ->
      (*
      print_endline "OverloadKindError";
      *)
      raise (OverloadKindError (sr,
        "[sig_of_symdef] Expected "^
        name
        ^" to be a type function, got " ^
        string_of_typecode t
      ))
    end

  | symdef ->
    raise (OverloadKindError (sr,
      "[sig_of_symdef] Expected "^
      name
      ^" to be function or procedure, got " ^
     string_of_symdef symdef name dfltvs
    ))

let resolve syms i =
  match get_data syms.dfns i with
  {id=id; sr=sr;parent=parent;privmap=table;dirs=dirs;symdef=symdef} ->
  let pvs,vs,{raw_type_constraint=con; raw_typeclass_reqs=rtcr} =
    find_split_vs syms i
  in
  let t,r,pnames = sig_of_symdef symdef sr id i in
  id,sr,parent,vs,pvs,con,rtcr,t,r,pnames

let rec unravel_ret tin dts =
  match tin with
  | `BTYP_function (a,b) -> unravel_ret b (a::dts)
  | _ -> rev dts

let hack_name qn = match qn with
| `AST_name (sr,name,ts) -> `AST_name (sr,"_inst_"^name,ts)
| `AST_lookup (sr,(e,name,ts)) -> `AST_lookup (sr,(e,"_inst_"^name,ts))
| _ -> failwith "expected qn .."

(* Note this bt must bind types in the base context *)
let consider syms bt be luqn2 name
  ({base_sym=i;spec_vs=spec_vs; sub_ts=sub_ts} as eeek)
  input_ts arg_types call_sr
: overload_result option =
    let bt sr t = bt sr i t in
    let id,sr,p,base_vs,parent_vs,con,rtcr,base_domain,base_result,pnames =
      resolve syms i
    in
    let fixup_argtypes argt rs =
      begin match pnames with
        | None -> argt
        | Some ps ->
        match
          begin try
            iter (fun (name,_)->ignore (assoc name ps)) rs;
            true
          with Not_found -> false
          end
        with false -> argt
        | _ ->
        match base_domain with
        | `TYP_record _ -> argt
        | `TYP_tuple [] -> argt (* lazy *)
        | _ ->
        let ps =
          map (fun (name,e) ->
            name,
            match e with
            | None -> None
            | Some e -> Some (be i e)
          )
          ps
        in
        begin
          try
            let ats = map (fun (name,d)->
              try assoc name rs
              with Not_found ->
              match d with (* ok to skip if there is a default *)
              | Some (e,t) -> t
              | None -> raise Not_found
            ) ps
            in
            let t = match ats with
              | [] -> assert false
              | [x] -> x
              | _ -> `BTYP_tuple ats
            in
            t
          with Not_found -> argt
        end
      end
    in
    let arg_types =
      match arg_types with
      | `BTYP_record rs as argt :: tail -> fixup_argtypes argt rs :: tail
      | `BTYP_tuple [] as argt :: tail -> fixup_argtypes argt [] :: tail
      | _ -> arg_types
    in
    (*
    if length rtcr > 0 then begin
      (*
      print_endline (name ^" TYPECLASS INSTANCES REQUIRED (unbound): " ^
      catmap "," string_of_qualified_name rtcr);
      *)
      iter
      (fun qn -> let es,ts' = luqn2 i (hack_name qn) in
        print_endline ("With ts = " ^ catmap "," string_of_typecode ts');
        match es with
        | `NonFunctionEntry _ -> print_endline "EXPECTED INSTANCES TO BE FUNCTION SET"
        | `FunctionEntry es ->
          print_endline ("Candidates " ^ catmap "," string_of_entry_kind es)
      )
      rtcr
    end
    ;
    *)
    (*
    print_endline (id ^ "|-> " ^string_of_myentry syms.dfns eeek);
    begin
      print_endline ("PARENT VS=" ^ catmap "," (fun (s,i,_)->s^"<"^si i^">") parent_vs);
      print_endline ("base VS=" ^ catmap "," (fun (s,i,_)->s^"<"^si i^">") base_vs);
      print_endline ("sub TS=" ^ catmap "," (sbt syms.dfns) sub_ts);
      print_endline ("spec VS=" ^ catmap "," (fun (s,i)->s^"<"^si i^">") spec_vs);
      print_endline ("input TS=" ^ catmap "," (sbt syms.dfns) input_ts);
    end
    ;
    *)
    (* these are wrong .. ? or is it just shitty table?
       or is the mismatch due to unresolved variables?
    *)
    if (length base_vs != length sub_ts) then
    begin
      print_endline "WARN: VS != SUB_TS";
      print_endline (id ^ "|-> " ^string_of_myentry syms.dfns eeek);
      print_endline ("PARENT VS=" ^ catmap "," (fun (s,i,_)->s^"<"^si i^">") parent_vs);
      print_endline ("base VS=" ^ catmap "," (fun (s,i,_)->s^"<"^si i^">") base_vs);
      print_endline ("sub TS=" ^ catmap "," (sbt syms.dfns) sub_ts);
      print_endline ("spec VS=" ^ catmap "," (fun (s,i)->s^"<"^si i^">") spec_vs);
      print_endline ("input TS=" ^ catmap "," (sbt syms.dfns) input_ts);
    end
    ;
    (*
    if (length spec_vs != length input_ts) then print_endline "WARN: SPEC_VS != INPUT_TS";
    *)

    (* bind type in base context, then translate it to view context:
       thus, base type variables are eliminated and specialisation
       type variables introduced
    *)
   let spec t =
      (*
      print_endline ("specialise Base type " ^ sbt syms.dfns t);
      *)
      let n = length base_vs in
      let ts = list_prefix sub_ts n in
      let vs = map (fun (i,n,_) -> i,n) base_vs in
      let t = tsubst vs ts t in
      (*
      print_endline ("to View type " ^ sbt syms.dfns t);
      *)
      t
    in
    let spec_bt sr t =
      let t = bt sr t in
      let t = spec t in
      t
    in

    let con = bt sr con in
    let domain = bt sr base_domain in
    let spec_domain = spec domain in
    let spec_result =
      try spec_bt sr base_result
      with _ -> clierr sr ("Failed to bind candidate return type! fn='"^name^"', type="^string_of_typecode base_result)
    in
    (*
    print_endline ("BASE Return type of function " ^ id^ "<"^si i^">=" ^ sbt syms.dfns spec_result);
    *)

    (* unravel function a->b->c->d->..->z into domains a,b,c,..y
      to match curry argument list
    *)
    let curry_domains =
      try unravel_ret spec_result []
      with _ -> print_endline "Failed to unravel candidate return type!"; []
    in
    let curry_domains = spec_domain :: curry_domains in

    (*
    print_endline ("Argument  sigs= " ^  catmap "->" (sbt syms.dfns) arg_types);
    print_endline ("Candidate sigs= " ^  catmap "->" (sbt syms.dfns) curry_domains);
    *)
    (*
    if con <> `BTYP_tuple [] then
      print_endline ("type constraint (for "^name^") = " ^ sbt syms.dfns con)
    ;
    *)
    (*
       We need to attempt to find assignments for spec_vs which
       unify the specialised function signature(s) with arguments.

       To do this we match up:

       (a) spec vs variables with input ts values
       (b) signatures with arguments

       which hopefully produces mgu with all the spec_vs variables

       If this succeeds, we plug these into the sub_ts to get
       assignments for base_vs, eliminating the spec vs and
       base vs variables. The parent variables must not be
       eliminated since they act like constants (constructors).

       The resulting ts is then returned, it may contain variables
       from the calling context.

       There is a twist: a polymorphic function calling itself.
       In that case the variables in the calling context
       can be the same as the base variables of the called
       function, but they have to be treated like constants.
       for example here:

       fun f[t] ... => .... f[g t]

       the 't' in f[g t] has to be treated like a constant.

       So the base_vs variables are renamed in the
       function signature where they're dependent.

       The spec vs variables don't need renaming
       because they're anonymous.

       Note that the base_vs variables are eliminated
       from the signature .. so the renaming is pointless!


    *)
    (* Step1: make equations for the ts *)

    let n_parent_vs = length parent_vs in
    let n_base_vs = length base_vs in
    let n_spec_vs = length spec_vs in
    let n_sub_ts = length sub_ts in
    let n_input_ts = length input_ts in

    (* equations for user specified assignments *)
    let lhsi = map (fun (n,i) -> i) spec_vs in
    let lhs = map (fun (n,i) -> `BTYP_var ((i),`BTYP_type 0)) spec_vs in
    let n = min n_spec_vs n_input_ts in
    let eqns = combine (list_prefix lhs n) (list_prefix input_ts n) in

    (* these are used for early substitution *)
    let eqnsi = combine (list_prefix lhsi n) (list_prefix input_ts n) in

    (*
    print_endline "TS EQUATIONS ARE:";
    iter (fun (t1,t2) -> print_endline (sbt syms.dfns t1 ^ " = " ^ sbt syms.dfns t2))
    eqns
    ;
    *)

    (*
    print_endline ("Curry domains (presub)   = " ^ catmap ", " (sbt syms.dfns) curry_domains);
    *)
    let curry_domains = map (fun t -> list_subst syms.counter eqnsi t) curry_domains in

    (*
    print_endline ("Curry domains (postsub)  = " ^ catmap ", " (sbt syms.dfns) curry_domains);
    *)

    let curry_domains = map (fun t -> reduce_type (beta_reduce syms sr t)) curry_domains in

    (*
    print_endline ("Curry domains (postbeta) = " ^ catmap ", " (sbt syms.dfns) curry_domains);
    *)

    let n = min (length curry_domains) (length arg_types) in
    let eqns = eqns @ combine (list_prefix curry_domains n) (list_prefix arg_types n) in

    let dvars = ref IntSet.empty in
    iter (fun (_,i)-> dvars := IntSet.add i !dvars) spec_vs;

    (*
    print_endline "EQUATIONS ARE:";
    iter (fun (t1,t2) -> print_endline (sbt syms.dfns t1 ^ " = " ^ sbt syms.dfns t2))
    eqns
    ;
    (* WRONG!! dunno why, but it is! *)
    print_endline ("DEPENDENT VARIABLES ARE " ^ catmap "," si
      (IntSet.fold (fun i l-> i::l) !dvars [])
    );
    print_endline "...";
    *)

    (*
    let mgu = maybe_specialisation syms.counter syms.dfns eqns in
    *)
    (* doesn't work .. fails to solve for some vars
       which aren't local vs of the fun .. this case:

       fun g2[w with Eq[w,w]] (x:int,y:int)=> xeq(x,y);

       doesn't solve for w checking xeq(x,y) .. not
       sure why it should tho .. w should be fixed
       already by the instance match .. hmm ..
    *)
    let mgu =
      try Some (unification true syms.counter syms.dfns eqns !dvars)
      with Not_found -> None
    in
    match mgu with
    | Some mgu ->
      (*
      print_endline "Specialisation detected";
      print_endline (" .. mgu = " ^ string_of_varlist syms.dfns mgu);
      *)
      let mgu = ref mgu in
      (* each universally quantified variable must be fixed
        by the mgu .. if it doesn't its an error .. hmmm

        THIS CANNOT HAPPEN NOW!
        JS: 13/3/2006 .. oh yes it can!

      *)
      (* Below algorithm is changed! We now make list
         of unresolved dependent variables, and see
         if the constraint resolution can help.
         Actually, at this point, we can even try
         to see if the return type can help
       *)

      (*
      print_endline "Check for unresolved";
      *)
      let unresolved = ref (
        fold_left2
        (fun acc (s,i) k ->
          if not (mem_assoc i !mgu) then (s,i,`TYP_type,k)::acc else acc
        )
        [] spec_vs (nlist n_spec_vs)
      )
      in

      let th i = match i with
        | 0 -> "first"
        | 1 -> "second"
        | 2 -> "third"
        | _ -> si (i+1) ^ "'th"
      in

      let report_unresolved =
        (*
        let maybe_tp tp = match tp with
          | `TPAT_any -> ""
          | tp -> ": " ^ string_of_tpattern tp
        in
        *)
        let maybe_tp tp = match tp with
          | `AST_patany _ -> ""
          | tp -> ": " ^ string_of_typecode tp
        in
        fold_left (fun acc (s,i,tp,k) -> acc ^
          "  The " ^th k ^" subscript  " ^ s ^ "["^si i^"]" ^
           maybe_tp tp ^ "\n"
        ) "" !unresolved
      in
      (*
      if length !unresolved > 0 then
        print_endline (
        "WARNING: experimental feature coming up\n" ^
        "Below would be an error, but we try now to do more work\n" ^
        (* clierr call_sr ( *)
          "[resolve_overload] In application of " ^ id ^
          " cannot resolve:\n" ^
          report_unresolved ^
         "Try using explicit subscript" ^
         "\nMost General Unifier(mgu)=\n" ^ string_of_varlist syms.dfns !mgu
        )
      ;
      *)
(*
      if length !unresolved > 0 then None else
*)

      (* HACKERY to try to get more values from type patterns*)
(*
      if length !unresolved > 0 then
*)
      begin
        (* convert mgu from spec vars to base vars *)
        let basemap = map2 (fun (_,i,_) t -> i,list_subst syms.counter !mgu t) base_vs sub_ts in
        (*
        print_endline ("New basemap: " ^ catmap ","
          (fun (i,t) -> si i ^ "->" ^ sbt syms.dfns t)
          basemap
        );
        *)

        let extra_eqns = ref [] in
        let dvars = ref IntSet.empty in
        iter (fun (_,i)->
          if not (mem_assoc i !mgu) then (* mgu vars get eliminated *)
          dvars := IntSet.add i !dvars
        )
        spec_vs;

        iter (fun (s,j',tp) ->
           let et,explicit_vars1,any_vars1, as_vars1, eqns1 =
            type_of_tpattern syms tp
           in
           let et = spec_bt sr et in
           let et = list_subst syms.counter !mgu et in
           let et = beta_reduce syms sr et in
           (*
           print_endline ("After substitution of mgu, Reduced type is:\n  " ^
             sbt syms.dfns et)
           ;
           *)

           (* tp is a metatype .. it could be a pattern-like thing, which is
           a constraint. But it could also be an actual meta-type! In that
           case it is a constraint too, but not the right kind of constraint.
           EG in

              j' -> fun (x:TYPE):TYPE=>x : TYPE->TYP

           the TYPE->TYPE is a constraint only in the sense that it
           is the type of j'. Felix messes these things up.. you can
           give an explicit TYPE->TYPE which really amounts only
           to a typing constraint .. and no additional constraint.

           So we have to eliminate these from consideration

           *)

           (*
           print_endline ("Analysing "^s^"<"^si j'^">: " ^ string_of_typecode tp);
           print_endline (si j' ^ (if mem_assoc j' basemap then " IS IN BASEMAP" else " IS NOT IN BASEMAP"));
           *)
           (* this check is redundant .. we're SCANNING the base vs! *)
           match et with
           | `BTYP_type _
           | `BTYP_function _ -> () (* print_endline "ignoring whole metatype" *)
           | _ ->
           if mem_assoc j' basemap then begin
             let t1 = assoc j' basemap in
             let t2 = et in
             (*
             print_endline ("CONSTRAINT: Adding equation " ^ sbt syms.dfns t1 ^ " = " ^ sbt syms.dfns t2);
             *)
             extra_eqns := (t1,t2) :: !extra_eqns
           end
           ;

           (* THIS CODE DOES NOT WORK RIGHT YET *)
           if length explicit_vars1 > 0 then
           print_endline ("Explicit ?variables: " ^
             catmap "," (fun (i,s) -> s ^ "<" ^ si i ^ ">") explicit_vars1)
           ;
           iter
           (fun (i,s) ->
             let coupled = filter (fun (s',_,_) -> s = s') base_vs in
             match coupled with
             | [] -> ()
             | [s',k,pat] ->
                print_endline (
                    "Coupled " ^ s ^ ": " ^ si k ^ "(vs var) <--> " ^ si i ^" (pat var)" ^
                  " pat=" ^ string_of_typecode pat);
             let t1 = `BTYP_var (i,`BTYP_type 0) in
             let t2 = `BTYP_var (k,`BTYP_type 0) in
             print_endline ("Adding equation " ^ sbt syms.dfns t1 ^ " = " ^ sbt syms.dfns t2);
             extra_eqns := (t1,t2) :: !extra_eqns;
             (*
             dvars := IntSet.add i !dvars;
             print_endline ("ADDING DEPENDENT VARIABLE " ^ si i);
             *)

             | _ -> assert false (* vs should have distinct names *)
           )
           explicit_vars1
           ;

           if length as_vars1 > 0 then begin
             print_endline ("As variables: " ^
               catmap "," (fun (i,s) -> s ^ "<" ^ si i ^ ">") as_vars1)
             ;
             print_endline "RECURSIVE?? AS VARS NOT HANDLED YET"
           end;

           (*
           if length any_vars1 > 0 then
           print_endline ("Wildcard variables: " ^
             catmap "," (fun i -> "<" ^ si i ^ ">") any_vars1)
           ;
           *)

           (* add wildcards to dependent variable set ?? *)
           iter (fun i-> dvars := IntSet.add i !dvars) any_vars1;

           (* add 'as' equations from patterns like
              t as v
           *)
           iter (fun (i,t) -> let t2 = bt sr t in
             let t1 = `BTYP_var (i,`BTYP_type 0) in
             extra_eqns := (t1,t2) :: !extra_eqns
           ) eqns1;

           (*
           if length eqns1 > 0 then
           print_endline ("Equations for as terms (unbound): " ^
             catmap "\n" (fun (i,t) -> si i ^ " -> " ^ string_of_typecode t) eqns1)
           ;
           *)
        )
        base_vs
        ;

        (* NOW A SUPER HACK! *)
        let rec xcons con = match con with
        | `BTYP_intersect cons -> iter xcons cons
        | `BTYP_type_match (arg,[{pattern=pat},`BTYP_tuple[]]) ->
          let arg = spec arg in
          let arg = list_subst syms.counter !mgu arg in
          let arg = beta_reduce syms sr arg in
          let pat = spec pat in
          let pat = list_subst syms.counter !mgu pat in
          let pat = beta_reduce syms sr pat in
          extra_eqns := (arg, pat)::!extra_eqns
        | _ -> ()
        in
        xcons con;

        (*
        print_endline "UNIFICATION STAGE 2";
        print_endline "EQUATIONS ARE:";
        iter (fun (t1,t2) -> print_endline (sbt syms.dfns t1 ^ " = " ^ sbt syms.dfns t2))
        !extra_eqns
        ;
        print_endline "...";
        print_endline ("DEPENDENT VARIABLES ARE " ^ catmap "," si
          (IntSet.fold (fun i l-> i::l) !dvars [])
        );
        *)
        let maybe_extra_mgu =
          try Some (unification false syms.counter syms.dfns !extra_eqns !dvars)
          with Not_found -> None
        in
        match maybe_extra_mgu with
        | None -> () (* print_endline "COULDN'T RESOLVE EQUATIONS"  *)
        | Some extra_mgu ->
           (*
           print_endline ("Resolved equations with mgu:\n  " ^
              string_of_varlist syms.dfns extra_mgu)
           ;
           *)
           let ur = !unresolved in
           unresolved := [];
           iter (fun ((s,i,_,k) as u) ->
             (*
             let j = base + k in
             *)
             let j = i in
             if mem_assoc j extra_mgu
             then begin
                let t = assoc j extra_mgu in
                (*
                print_endline ("CAN NOW RESOLVE " ^
                  th k ^ " vs term " ^ s ^ "<"^ si i^"> ---> " ^ sbt syms.dfns t)
                ;
                *)
                mgu := (j,t) :: !mgu
             end
             else begin
               (*
               print_endline ("STILL CANNOT RESOLVE " ^ th k ^ " vs term " ^ s ^ "<"^si i^">");
               *)
               unresolved := u :: !unresolved
             end
           )
           ur
      end
      ;


      if length !unresolved > 0 then None else begin
        let ok = ref true in
        iter
        (fun sign ->
          if sign <> list_subst syms.counter !mgu sign then
          begin
            ok := false;
            (*
            print_endline ("At " ^ short_string_of_src call_sr);
            (*
            clierr call_sr
            *)
            print_endline
            (
              "[resolve_overload] Unification of function " ^
              id ^ "<" ^ si i ^ "> signature " ^
              sbt syms.dfns domain ^
              "\nwith argument type " ^ sbt syms.dfns sign ^
              "\nhas mgu " ^ string_of_varlist syms.dfns !mgu ^
              "\nwhich specialises a variable of the argument type"
            )
            *)
          end
        )
        arg_types
        ;
        if not (!ok) then None else
        (*
        print_endline ("Matched with mgu = " ^ string_of_varlist syms.dfns !mgu);
        *)
        (* RIGHT! *)
(*
        let ts = map (fun i -> assoc (base+i) !mgu) (nlist (m+k)) in
*)
        (* The above ts is for plugging into the view, but we
          have to return the elements to plug into the base
          vs list, this is the sub_ts with the above ts plugged in,
          substituting away the view vs
        *)

        let base_ts = map (list_subst syms.counter !mgu) sub_ts in

        (*
        print_endline ("Matched candidate " ^ si i ^ "\n" ^
          ", spec domain=" ^ sbt syms.dfns spec_domain ^"\n" ^
          ", base domain=" ^ sbt syms.dfns domain ^"\n" ^
          ", return=" ^ sbt syms.dfns spec_result ^"\n" ^
          ", mgu=" ^ string_of_varlist syms.dfns !mgu ^ "\n" ^
          ", ts=" ^ catmap ", " (sbt syms.dfns) base_ts
        );
        *)

        (* we need to check the type constraint, it uses the
          raw vs type variable indicies. We need to substitute
          in the corresponding ts values. First we need to build
          a map of the correspondence
        *)
        let parent_ts = map (fun (n,i,_) -> `BTYP_var ((i),`BTYP_type 0)) parent_vs in
        let type_constraint = build_type_constraints syms (bt sr) sr base_vs in
        let type_constraint = `BTYP_intersect [type_constraint; con] in
        (*
        print_endline ("Raw type constraint " ^ sbt syms.dfns type_constraint);
        *)
        let vs = map (fun (s,i,_)-> s,i) base_vs in
        let type_constraint = tsubst vs base_ts type_constraint in
        (*
        print_endline ("Substituted type constraint " ^ sbt syms.dfns type_constraint);
        *)
        let reduced_constraint = beta_reduce syms sr type_constraint in
        (*
        print_endline ("Reduced type constraint " ^ sbt syms.dfns reduced_constraint);
        *)
        begin match reduced_constraint with
        | `BTYP_void ->
          (*
          print_endline "Constraint failure, rejecting candidate";
          *)
          None
        | `BTYP_tuple [] ->
          let parent_ts = map (fun (n,i,_) -> `BTYP_var ((i),`BTYP_type 0)) parent_vs in
          Some (i,domain,spec_result,!mgu,parent_ts @ base_ts)

        | x ->
          clierr sr
          ("[overload] Cannot resolve type constraint! " ^
            sbt syms.dfns type_constraint ^
            "\nReduced to " ^ sbt syms.dfns x
          )
        end
      end

    | None ->
      (*
      print_endline "No match";
      *)
      None

let overload
  syms
  bt be
  luqn2
  call_sr
  (fs : entry_kind_t list)
  (name: string)
  (sufs : btypecode_t list)
  (ts:btypecode_t list)
:
  overload_result option
=
  (*
  print_endline ("Overload " ^ name);
  print_endline ("Argument sigs are " ^ catmap ", " (sbt syms.dfns) sufs);
  print_endline ("Candidates are " ^ catmap "," (string_of_entry_kind) fs);
  print_endline ("Input ts = " ^ catmap ", " (sbt syms.dfns) ts);
  *)
  (* HACK for the moment *)
  let aux i =
    match consider syms bt be luqn2 name i ts sufs call_sr with
    | Some x -> Unique x
    | None -> Fail
  in
  let fun_defs = List.map aux fs in
  let candidates =
    List.filter
    (fun result -> match result with
      | Unique _ -> true
      | Fail -> false
    )
    fun_defs
  in
    (*
    print_endline "Got matching candidates .. ";
    *)
  (* start with an empty list, and fold one result
  at a time into it, as follows: if one element
  of the list is greater (more general) than the candidate,
  then add the candidate to the list and remove all
  element greater than the candidate,

  otherwise, if one element of the list is less then
  the candidate, keep the list and discard the candidate.

  The list starts off empty, so that all elements in
  it are vacuously incomparable. It follows either
  the candidate is not less than all the list,
  or not less than all the list: that is, there cannot
  be two element a,b such that a < c < b, since by
  transitivity a < c would follow, contradicting
  the assumption the list contains no ordered pairs.

  If in case 1, all the greater element are removed and c added,
  all the elements must be less or not comparable to c,
  thus the list remains without comparable pairs,
  otherwise in case 2, the list is retained and c discarded
  and so trivially remains unordered.

  *)

  let candidates = fold_left
  (fun oc r ->
     match r with Unique (j,c,_,_,_) ->
     (*
     print_endline ("Considering candidate sig " ^ sbt syms.dfns c);
     *)
     let rec aux lhs rhs =
       match rhs with
       | [] ->
         (*
         print_endline "return elements plus candidate";
         *)
         r::lhs (* return all non-greater elements plus candidate *)
       | (Unique(i,typ,rtyp,mgu,ts) as x)::t
       ->
         (*
         print_endline (" .. comparing with " ^ sbt syms.dfns typ);
         *)
         begin match compare_sigs syms.counter syms.dfns typ c with
         | `Less ->
           (*
           print_endline "Candidate is more general, discard it, retain whole list";
           *)
           lhs @ rhs (* keep whole list, discard c *)
         | `Equal ->
           (* same function .. *)
           if i = j then aux lhs t else
           let sr = match (try Hashtbl.find syms.dfns i with Not_found -> failwith "ovrload BUGGED") with {sr=sr} -> sr in
           let sr2 = match (try Hashtbl.find syms.dfns j with Not_found -> failwith "overload Bugged") with {sr=sr} -> sr in
           clierrn [call_sr; sr2; sr]
           (
             "[resolve_overload] Ambiguous call: Not expecting equal signatures" ^
             "\n(1) fun " ^ si i^ ":" ^ sbt syms.dfns typ ^
             "\n(2) fun " ^ si j^ ":"^ sbt syms.dfns c
           )

         | `Greater ->
           (*
           print_endline "Candidate is less general: discard this element";
           *)
           aux lhs t (* discard greater element *)
         | `Incomparable ->
           (*
           print_endline "Candidate is comparable, retail element";
           *)
           aux (x::lhs) t (* keep element *)
       end
       | Fail::_ -> assert false
     in aux [] oc
     | Fail -> assert false
  )
  []
  candidates in
  match candidates with
  | [Unique (i,t,rtyp,mgu,ts)] ->
    (*
    print_endline ("[overload] Got unique result " ^ si i);
    *)
    Some (i,t,rtyp,mgu,ts)

  | [] -> None
  | _ ->
    clierr call_sr
    (
      "Too many candidates match in overloading " ^ name ^
      " with argument types " ^ catmap "," (sbt syms.dfns) sufs ^
      "\nOf the matching candidates, the following are most specialised ones are incomparable\n" ^
      catmap "\n" (function
        | Unique (i,t,_,_,_) ->
          qualified_name_of_index syms.dfns i ^ "<" ^ si i ^ "> sig " ^
          sbt syms.dfns t
        | Fail -> assert false
      )
      candidates
      ^
      "\nPerhaps you need to define a function more specialised than all these?"
    )

(* FINAL NOTE: THIS STILL WON'T BE ENOUGH: THE SEARCH ALGORITHM
NEEDS TO BE MODIFIED TO FIND **ALL** FUNCTIONS .. alternatively,
keep the results from overload resolution for each scope, and resubmit
in a deeper scope: then if there is a conflict between signatures
(equal or unordered) the closest is taken if that resolves the
conflict
*)