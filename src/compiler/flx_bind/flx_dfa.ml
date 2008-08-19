(* build a DFA from a regular expression *)
open Flx_ast
open Flx_print
open Flx_mtypes2

let hashtbl_length h =
  let n = ref 0 in
  Hashtbl.iter (fun _ _ -> incr n) h;
  !n

let augment re = `REGEXP_seq (re,`REGEXP_sentinel)

type annotation_t =
 {
   nullable: bool;
   firstpos: PosSet.t;
   lastpos: PosSet.t
 }

let fp_get followpos i =
  try Hashtbl.find followpos i
  with Not_found -> PosSet.empty

let fp_add followpos i j =
  Hashtbl.replace followpos i (PosSet.add j (fp_get followpos i))

let fp_union followpos i x =
  Hashtbl.replace followpos i (PosSet.union (fp_get followpos i) x)

let rec annotate counter followpos posmap codemap re =
  let a r = annotate counter followpos posmap codemap r in
  match re with
  | `REGEXP_group _ -> failwith "Can't handle groups yet"
  | `REGEXP_name _ -> failwith "Unbound regular expresion name"
  | `REGEXP_seq (r1,r2) ->
    let a1 = a r1 and a2 = a r2 in
    let au =
    {
      nullable = a1.nullable && a2.nullable;
      firstpos =
        if a1.nullable
        then PosSet.union a1.firstpos a2.firstpos
        else a1.firstpos;
      lastpos =
        if a2.nullable
        then PosSet.union a1.lastpos a2.lastpos
        else a2.lastpos;
    }
    in
      PosSet.iter
      (fun i -> fp_union followpos i a2.firstpos)
      a1.lastpos
      ;
      au

  | `REGEXP_alt (r1,r2) ->
    let a1 = a r1 and a2 = a r2 in
    {
      nullable = a1.nullable || a2.nullable;
      firstpos =
        PosSet.union a1.firstpos a2.firstpos;
      lastpos =
        PosSet.union a1.lastpos a2.lastpos
    }

  | `REGEXP_aster r1 ->
    let a1 = a r1 in
    let au =
    {
      nullable = true;
      firstpos = a1.firstpos;
      lastpos = a1.lastpos
    }
    in
      PosSet.iter
      (fun i -> fp_union followpos i a1.firstpos)
      a1.lastpos
      ;
      au

  | `REGEXP_string s ->
    let n = String.length s in
    if n = 0
    then (a `REGEXP_epsilon)
    else
      begin
        let start = !counter in
        counter := start + n;
        let last = !counter - 1 in
        let au =
        {
          nullable = false;
          firstpos = PosSet.singleton start;
          lastpos = PosSet.singleton last
        }
        in
          for i = start to last-1 do
            fp_add followpos i (i+1);
            Hashtbl.add posmap i (Char.code s.[i-start])
          done
          ;
          Hashtbl.add posmap last (Char.code s.[last-start])
          ;
          au
      end

  | `REGEXP_epsilon ->
    {
      nullable = true;
      firstpos = PosSet.empty;
      lastpos = PosSet.empty
    }

  | `REGEXP_code s ->
    Hashtbl.add codemap !counter s;
    let u =
    {
      nullable = false;
      firstpos = PosSet.singleton !counter;
      lastpos = PosSet.singleton !counter
    }
    in
      incr counter;
      u

  | `REGEXP_sentinel ->
    let u =
    {
      nullable = false;
      firstpos = PosSet.singleton !counter;
      lastpos = PosSet.singleton !counter;
    }
    in
      Hashtbl.add followpos !counter PosSet.empty;
      u

let list_of_set x =
  let lst = ref [] in
  PosSet.iter
  (fun i -> lst := i :: !lst)
  x
  ;
  !lst

let string_of_set x =
  "{" ^
  String.concat ", " (List.map string_of_int (list_of_set x)) ^
  "}"

let print_followpos followpos =
  Hashtbl.iter
  (fun i fp ->
    print_endline (
      (string_of_int i) ^
      " -> " ^
      string_of_set fp
    )
  )
  followpos

let print_int_set s =
  print_string "{";
  PosSet.iter
  (fun i -> print_string (string_of_int i ^ ", "))
  s
  ;
  print_string "}"

exception Found of int
;;

let process_regexp re =
    (*
    print_endline ("  | " ^ Lex_print.string_of_re re);
    *)
    let are = augment re in
    let followpos = Hashtbl.create 97 in
    let codemap = Hashtbl.create 97 in
    let posmap = Hashtbl.create 97 in
    let counter = ref 1 in
    let root = annotate counter followpos posmap codemap are in
    let posarray = Array.make !counter 0 in
    let alphabet = ref CharSet.empty in
    Hashtbl.iter
    (fun i c ->
      posarray.(i-1) <- c;
      alphabet := CharSet.add c !alphabet
    )
    posmap;
    (*
    print_endline "Followpos:";
    print_followpos followpos;
    print_endline ("Charpos '" ^ posarray ^ "'");
    print_endline ("Codepos: ");
    Hashtbl.iter
    (fun i c ->
      print_endline ((string_of_int i) ^ " -> " ^ c)
    )
    codemap
    ;
    print_string "alphabet '";
    CharSet.iter
    (fun c -> print_char c)
    !alphabet;
    print_endline "'";
    *)
    let marked_dstates = ref PosSetSet.empty in
    let unmarked_dstates = ref (PosSetSet.singleton root.firstpos) in
    let find_char c t =
      try
        PosSet.iter
        (fun i -> if posarray.(i-1) = c then raise (Found i))
        t
        ;
        print_endline ("Can't find char '" ^ String.make 1 (Char.chr c) ^ "'")
        ;
        raise Not_found
      with Found p -> p
    in
    let state_counter = ref 1 in
    let state_map = Hashtbl.create 97 in
    let inv_state_map = Hashtbl.create 97 in

    let dtran = Hashtbl.create 97 in
    Hashtbl.add state_map 0 root.firstpos;
    Hashtbl.add inv_state_map root.firstpos 0;
    (*
    print_endline "Root is";
    print_int_set root.firstpos;
    print_endline "";
    *)
    while not (PosSetSet.is_empty !unmarked_dstates) do
      let t = PosSetSet.choose !unmarked_dstates in
      unmarked_dstates := PosSetSet.remove t !unmarked_dstates;
      marked_dstates := PosSetSet.add t !marked_dstates;
      let src_state_index =
        try
          let state_index = Hashtbl.find inv_state_map t in
          (*
          print_endline ("src_state = " ^ string_of_int state_index);
          *)
          state_index
        with Not_found ->
          print_endline "Can't find "; print_int_set t;
          print_endline "";
          raise Not_found
      in

      CharSet.iter
      (fun c ->
        let u = ref (PosSet.empty) in
        PosSet.iter
        (fun i ->
          if posarray.(i-1) = c
          then begin
            u := PosSet.union !u (try Hashtbl.find followpos i with
            Not_found -> failwith ("Can't find followpos of index " ^ string_of_int i))
          end
        )
        t
        ;
        if not (PosSet.is_empty !u)
        then
          let dst_state_index =
            if not (PosSetSet.mem !u !marked_dstates)
            && not (PosSetSet.mem !u !unmarked_dstates)
            then begin
              let state_index = !state_counter in
              incr state_counter
              ;
              (*
              print_string ("Adding new state " ^ string_of_int state_index ^ " = ");
              print_int_set !u;
              print_endline "";
              *)
              Hashtbl.add state_map state_index !u;
              Hashtbl.add inv_state_map !u state_index;
              let n1 = PosSetSet.cardinal !unmarked_dstates in
              unmarked_dstates := PosSetSet.add !u !unmarked_dstates;
              assert(n1 <> PosSetSet.cardinal !unmarked_dstates);
              state_index
            end
            else
              try Hashtbl.find inv_state_map !u with Not_found -> failwith "ERROR 2"
          in
          Hashtbl.add dtran (c,src_state_index) dst_state_index
      )
      !alphabet
    done;
    (*
    print_endline "states:";
    PosSetSet.iter
    (fun s -> print_int_set s; print_endline "")
    !marked_dstates
    ;
    print_endline "";

    print_endline "states:";
    Hashtbl.iter
    (fun idx state ->
      print_string (string_of_int idx ^ " -> ");
      print_int_set state;
      print_endline ""
    )
    state_map
    ;
    *)

    let term_codes = Hashtbl.create 97 in
    Hashtbl.iter
    (fun idx state ->
      try
        PosSet.iter
        (fun i ->
          if Hashtbl.mem codemap i
          then raise (Found i)
        )
        state
        ;
        raise Not_found
      with
      | Found i ->
        let code = Hashtbl.find codemap i in
        Hashtbl.add term_codes idx code
      |  Not_found -> ()
    )
    state_map
    ;

    !alphabet,!state_counter, term_codes, dtran