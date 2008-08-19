open Flx_ast

val parse_file :
  string -> (* filenames *)
  string -> (* base dir *)
  string list -> (* include files *)
  string option -> (* syntax cache directory *)
  (string -> expr_t -> expr_t) -> (* expand expr *)
  string list -> (* auto imports *)
  string list * compilation_unit_t

val parse_string :
  string ->
  string ->
  (string -> expr_t -> expr_t) ->
  compilation_unit_t