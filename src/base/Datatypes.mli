(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.

  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.

  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Syntax
open ErrorUtils
open Core_kernel

(**********************************************************)
(*                 Built-in Algebraic Data Types          *)
(**********************************************************)

type constructor = {
  cname : string;
  (* constructor name *)
  arity : int; (* How many arguments it takes *)
}
[@@deriving equal]

type adt = {
  tname : string;
  tparams : string list;
  tconstr : constructor list;
  tmap : (string * typ list) list;
}
[@@deriving equal]

module DataTypeDictionary : sig
  (* Hiding the actual data type dicionary *)

  (* Re-initialize environment with the built-in ADTs *)
  val reinit : unit -> unit

  (*  Get ADT by name  *)
  val lookup_name :
    ?sloc:ErrorUtils.loc -> string -> (adt, scilla_error list) result

  (*  Get ADT by the constructor  *)
  val lookup_constructor :
    ?sloc:ErrorUtils.loc ->
    string ->
    (adt * constructor, scilla_error list) result

  (* Get typing map for a constructor *)
  val constr_tmap : adt -> string -> typ list option

  (* Get all known ADTs *)
  val get_all_adts : unit -> adt list

  (* Get all known ADT constructors *)
  val get_all_ctrs : unit -> (adt * constructor) list

  val add_adt : adt -> loc -> (unit, scilla_error list) result

  (*  Built-in ADTs  *)
  val bool_typ : typ

  val nat_typ : typ

  val option_typ : typ -> typ

  val list_typ : typ -> typ

  val pair_typ : typ -> typ -> typ
end

val scilla_list_to_ocaml : literal -> (literal list, scilla_error list) result

val scilla_list_to_ocaml_rev :
  literal -> (literal list, scilla_error list) result

open Snark

module SnarkTypes : sig
  val scalar_type : typ

  val g1point_type : typ

  val g2point_type : typ

  val g2comp_type : typ

  val g1g2pair_type : typ

  val g1g2pair_list_type : typ

  val scilla_scalar_to_ocaml : literal -> (scalar, scilla_error list) result

  val scilla_g1point_to_ocaml : literal -> (g1point, scilla_error list) result

  val scilla_g1g2pairlist_to_ocaml :
    literal -> ((g1point * g2point) list, scilla_error list) result

  val ocaml_g1point_to_scilla_lit :
    g1point -> (literal, scilla_error list) result
end
