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
*)

(* Sharding Analysis for Scilla contracts. *)

open Core_kernel.Result.Let_syntax
open TypeUtil
open Syntax
open ErrorUtils
open MonadUtil
open Yojson

module ScillaSA
    (SR : Rep) (ER : sig
      include Rep

      val get_type : rep -> PlainTypes.t inferred_type

      val mk_id : loc ident -> typ -> rep ident
    end) =
struct
  module SER = SR
  module EER = ER
  module SASyntax = ScillaSyntax (SR) (ER)
  module SCU = ContractUtil.ScillaContractUtil (SR) (ER)
  module MP = ContractUtil.MessagePayload
  module TU = TypeUtilities
  open SASyntax
  open PrettyPrinters

  (* field name, with optional map keys; if the field is a map, the pseudofield
     is always a bottom-level access *)
  type pseudofield = ER.rep ident * ER.rep ident list option

  let pp_pseudofield (field, opt_keys) =
    let base = get_id field in
    let keys =
      match opt_keys with
      | Some ks ->
          List.fold_left (fun acc kid -> acc ^ "[" ^ get_id kid ^ "]") "" ks
      | None -> ""
    in
    base ^ keys

  let pp_compare (pfa : pseudofield) (pfb : pseudofield) =
    String.compare (pp_pseudofield pfa) (pp_pseudofield pfb)

  let mk_id f =
    let dummy_type = Unit in
    ER.mk_id (mk_ident f) dummy_type

  (* Turn, e.g. balances[_sender][to] into pseudofield *)
  let pp_of_str ?(extra_sep = []) str =
    let ds =
      String.map
        (fun c -> if c = '[' || c = ']' || List.mem c extra_sep then '|' else c)
        str
    in
    let components = String.split_on_char '|' ds in
    (* Filter out empty component at the end *)
    let components =
      List.filter (fun s -> not @@ String.equal s "") components
    in
    match components with
    | [ f ] -> pure @@ (mk_id f, None)
    | f :: keys -> pure @@ (mk_id f, Some (List.map mk_id keys))
    (* bad input *)
    | [] ->
        fail0
          (Printf.sprintf "Sharding analysis: bad pseudofield string %s " str)

  let weak_read_of_str str =
    let components = String.split_on_char ':' str in
    if List.length components = 2 then
      let%bind pf = pp_of_str @@ List.nth components 1 in
      pure @@ (List.nth components 0, pf)
    else
      fail0 (Printf.sprintf "Sharding analysis: bad weak read string %s " str)

  (* We keep track of whether identifiers in the impure part of the language
     shadow any of their component's parameters *)
  type ident_shadow_status =
    | ShadowsComponentParameter
    | ComponentParameter
    | DoesNotShadow

  type de_bruijn_level = int

  type arg_index = int

  type contrib_source =
    | UnknownSource
    | ConstantLiteral of literal
    | ConstantContractParameter of ER.rep ident
    | Pseudofield of pseudofield
    (* When analysing pure functions, we describe their output's contributions
       in terms of how the function's formal parameters flow into the output *)
    | FormalParameter of de_bruijn_level
    | ProcParameter of arg_index

  type contrib_cardinality = NoContrib | LinearContrib | NonLinearContrib

  type contrib_op = BuiltinOp of builtin | Conditional

  let pp_contrib_source cs =
    match cs with
    | UnknownSource -> "_unknown_source"
    | ConstantLiteral l -> "Literal " ^ pp_literal_simplified l
    | ConstantContractParameter id -> "CParam " ^ get_id id
    | Pseudofield pf -> pp_pseudofield pf
    | FormalParameter i -> "_" ^ string_of_int i
    | ProcParameter i -> "_p" ^ string_of_int i

  let pp_contrib_op co =
    match co with BuiltinOp blt -> pp_builtin blt | Conditional -> "?cond"

  module OrderedContribOp = struct
    type t = contrib_op

    let compare a b = compare (pp_contrib_op a) (pp_contrib_op b)
  end

  module ContribOps = Set.Make (OrderedContribOp)

  type contrib_ops = ContribOps.t

  type contrib_summary = contrib_cardinality * contrib_ops

  module OrderedContribSource = struct
    type t = contrib_source

    let compare a b = compare (pp_contrib_source a) (pp_contrib_source b)
  end

  module Contrib = Map.Make (OrderedContribSource)
  module ContribSources = Set.Make (OrderedContribSource)

  (* keys are contrib_source, values are contrib_summary *)
  type contributions = contrib_summary Contrib.t

  (* How precise are we about the NON-CONSTANT keys in contributions? *)
  (* Exactly: these are exactly the contributions in the result, i.e. branches
     differ only by constants. SubsetOf: the result has a subset of these
     contributions, i.e. branches _may_ differ by non-constants *)
  type source_precision = Exactly | SubsetOf

  type known_contrib = source_precision * contributions

  type expr_type =
    (* "I give up" type, for things we cannot analyse *)
    | EUnknown
    (* Known contribution *)
    | EVal of known_contrib
    (* This is a hack for message/event types: we store both the type of all
       message tags put together and, separately, the type of just _recipient
       and _amount: first full, then special. But ECompositeVal could be used
       more generally, whenever we want to keep more than one expr_type for a
       given identifier. *)
    | ECompositeVal of expr_type * expr_type
    (* Transformation of contributions, i.e. derived contributions *)
    | EOp of contrib_op * expr_type
    | EComposeSequence of expr_type list
    (* conditional * clauses *)
    | EComposeParallel of expr_type * expr_type list
    | EFun of efun_desc
    | EApp of efun_desc * expr_type list

  (* We get away with not giving expr_types to the parameters because the Scilla
     type checker guarantees EApp will always match what we expect. *)
  and efun_desc = EFunDef of de_bruijn_level list * efun_def

  (* Either something that can be evaluated, or an unknown (parameter of a HO
     function or of a procedure). If the latter, we store _which_ parameter we
     are, so when EApp is used, we can replace the definition with the concrete
     one. *)
  and efun_def =
    | DefExpr of expr_type
    | DefFormalParameter of de_bruijn_level
    | DefProcParameter of arg_index

  let et_nothing = EVal (Exactly, Contrib.empty)

  (* This is a bit of a hack -- we give this type to messages that may send money *)
  let et_sends_money = EVal (SubsetOf, Contrib.empty)

  (**  Helper functions  **)
  let min_precision ua ub =
    match (ua, ub) with Exactly, Exactly -> Exactly | _ -> SubsetOf

  let pp_contrib_cardinality cc =
    match cc with
    | NoContrib -> "None"
    | LinearContrib -> "Linear"
    | NonLinearContrib -> "NonLinear"

  let max_contrib_card a b =
    match (a, b) with
    | NoContrib, NoContrib -> NoContrib
    | NonLinearContrib, _ -> NonLinearContrib
    | _, NonLinearContrib -> NonLinearContrib
    | _ -> LinearContrib

  let product_contrib_card a b =
    match (a, b) with
    | NoContrib, _ | _, NoContrib -> NoContrib
    | NonLinearContrib, _ | _, NonLinearContrib -> NonLinearContrib
    | LinearContrib, LinearContrib -> LinearContrib

  let pp_contrib_summary (cs : contrib_summary) =
    let card, ops_set = cs in
    let ops = ContribOps.elements ops_set in
    let ops_str = String.concat " " @@ List.map pp_contrib_op ops in
    let card_str = pp_contrib_cardinality card in
    card_str ^ ", " ^ ops_str

  let pp_contribs (contribs : contributions) =
    Contrib.fold
      (fun co_src co_summ str ->
        str ^ "{" ^ pp_contrib_source co_src ^ ", " ^ pp_contrib_summary co_summ
        ^ "}")
      contribs ""

  let pp_precision u =
    match u with Exactly -> "Exactly" | SubsetOf -> "SubsetOf"

  let pp_known_contrib (ps, cs) = pp_precision ps ^ " " ^ pp_contribs cs

  let rec pp_expr_type et =
    match et with
    | EUnknown -> "EUnknown"
    | EVal kc -> "EVal " ^ pp_known_contrib kc
    | ECompositeVal (full, special) ->
        Printf.sprintf "ECompVal [%s] (%s)" (pp_expr_type special)
          (pp_expr_type full)
    | EOp (op, et) ->
        Printf.sprintf "EOp({%s}, {%s})" (pp_contrib_op op) (pp_expr_type et)
    | EComposeSequence etl ->
        Printf.sprintf "EComposeSeq(%s)" (pp_expr_type_list ~sep:" ;; " etl)
    | EComposeParallel (c, etl) ->
        Printf.sprintf "EComposePar(%s ~~ %s)" (pp_expr_type c)
          (pp_expr_type_list ~sep:" || " etl)
    | EFun fd -> pp_efun_desc fd
    | EApp (eref, etl) ->
        Printf.sprintf "(EApp (%s) @@ %s)" (pp_efun_desc eref)
          (pp_expr_type_list ~sep:" @@ " etl)

  and pp_expr_type_list ?(sep = ", ") etl =
    String.concat sep (List.map pp_expr_type etl)

  and pp_efun_desc d =
    let pp_efun_def def =
      match def with
      | DefExpr et -> pp_expr_type et
      | DefFormalParameter i ->
          "DefParam " ^ pp_contrib_source (FormalParameter i)
      | DefProcParameter i -> "DefParam " ^ pp_contrib_source (ProcParameter i)
    in

    match d with
    | EFunDef (lvls, def) ->
        let fargs =
          String.concat ", " (List.map (fun i -> "_" ^ string_of_int i) lvls)
        in
        let ds = pp_efun_def def in
        Printf.sprintf "EFun(%s) = %s" fargs ds

  (* TODO: should this belong to the blockchain code? *)
  type sharding_constraint =
    (* Message sends are OK only to non-contracts *)
    (* If money is sent, CMustOwn _balance to prevent double-spending. *)
    | CMustBeUserAddr of ER.rep ident
    (* There should be no duplicate values in these arguments. This is to
       guarantee map keys do not alias. This is important because our
       commutativity analysis assumes that pseudofields do not alias. *)
    | CMustNotHaveDuplicates of (ER.rep ident * ER.rep ident) list
    (* If a transition accepts money, it must be processed in the sender shard
       to prevent double-spending. Accepting money is commutative, though, so
       we do not need to have full ownership of _balance. *)
    | CSenderShard
    (* If a transition sends money, it must be processed in the contract's shard
       to prevent double-spending *)
    | CContractShard
    (* Must be able to access this pseudofield in a non-commutative fashion *)
    | CAccess of pseudofield
    (* This constraint cannot be satisfied --> must go to the DS *)
    | CUnsat

  type transition_name = string

  type pseudofield_name = string

  type weak_read = transition_name * pseudofield_name

  let pp_sharding_constraint sc =
    match sc with
    | CMustBeUserAddr id -> "CMustBeUserAddr " ^ get_id id
    | CMustNotHaveDuplicates idl ->
        Printf.sprintf "CMustNotHaveDuplicates [%s]"
          (String.concat ", "
             (List.map (fun (id1, id2) -> get_id id1 ^ " != " ^ get_id id2) idl))
    | CSenderShard -> "CSenderShard"
    | CContractShard -> "CContractShard"
    | CAccess pf -> Printf.sprintf "CAccess %s" (pp_pseudofield pf)
    | CUnsat -> "CUnsat"

  let sharding_constraint_to_json sc : Yojson.Basic.t =
    let ctype, carg =
      match sc with
      | CMustBeUserAddr i -> ("CMustBeUserAddr", `String (get_id i))
      | CMustNotHaveDuplicates dl ->
          let l =
            List.map
              (fun (a, b) -> `List [ `String (get_id a); `String (get_id b) ])
              dl
          in
          ("CMustNotHaveDuplicates", `List l)
      | CSenderShard -> ("CSenderShard", `Null)
      | CContractShard -> ("CContractShard", `Null)
      | CAccess pf -> ("CAccess", `String (pp_pseudofield pf))
      | CUnsat -> ("CUnsat", `Null)
    in
    `Assoc [ ("ctype", `String ctype); ("carg", carg) ]

  let json_to_sharding_constraint js : sharding_constraint =
    let ctype = Basic.Util.member "ctype" js in
    match ctype with
    | `String ctype ->
        let carg = Basic.Util.member "carg" js in
        if String.compare ctype "CMustBeUserAddr" = 0 then
          match carg with `String i -> CMustBeUserAddr (mk_id i) | _ -> CUnsat
        else if String.compare ctype "CMustNotHaveDuplicates" = 0 then
          match carg with
          | `List al ->
              let all_args_good =
                List.for_all
                  (fun pair ->
                    match pair with
                    | `List [ `String _; `String _ ] -> true
                    | _ -> false)
                  al
              in
              if not all_args_good then CUnsat
              else
                let args =
                  List.map
                    (fun pair ->
                      match pair with
                      | `List [ `String a; `String b ] -> (mk_id a, mk_id b)
                      | _ -> (mk_id "", mk_id ""))
                    al
                in
                CMustNotHaveDuplicates args
          | _ -> CUnsat
        else if String.compare ctype "CSenderShard" = 0 then CSenderShard
        else if String.compare ctype "CContractShard" = 0 then CContractShard
        else if String.compare ctype "CAccess" = 0 then
          match carg with
          | `String pf -> (
              match pp_of_str pf with Ok pf -> CAccess pf | _ -> CUnsat )
          | _ -> CUnsat
        else CUnsat
    | _ -> CUnsat

  module OrderedShardingConstraint = struct
    type t = sharding_constraint

    let compare a b =
      let str_a = pp_sharding_constraint a in
      let str_b = pp_sharding_constraint b in
      compare str_a str_b
  end

  module ShardingSummary = Set.Make (OrderedShardingConstraint)

  let pp_sharding summ =
    let scs = ShardingSummary.elements summ in
    List.fold_left
      (fun acc sc -> acc ^ "  " ^ pp_sharding_constraint sc ^ "\n")
      "" scs

  (* Type normalisation *)
  let rec et_is_val et =
    match et with
    | EVal _ -> true
    | ECompositeVal (a, b) -> et_is_val a || et_is_val b
    | _ -> false

  let et_is_known_fun et =
    match et with EFun (EFunDef (_, DefExpr _)) -> true | _ -> false

  let combine_seq (carda, opsa) (cardb, opsb) =
    (* This is NOT max(carda, cardb), but addition *)
    let card =
      match (carda, cardb) with
      (* Special cases for no contributions *)
      | NoContrib, b -> b
      | a, NoContrib -> a
      (* Any seq combination of contributions is NonLinear *)
      | _ -> NonLinearContrib
    in
    let ops = ContribOps.union opsa opsb in
    (card, ops)

  let combine_par (carda, opsa) (cardb, opsb) =
    let card = max_contrib_card carda cardb in
    let ops = ContribOps.union opsa opsb in
    (card, ops)

  let combine_product (carda, opsa) (cardb, opsb) =
    let card = product_contrib_card carda cardb in
    let ops = ContribOps.union opsa opsb in
    (* ?cond is only allowable op if card = NoContrib *)
    let ops =
      match card with
      | NoContrib -> ContribOps.inter ops (ContribOps.singleton Conditional)
      | _ -> ops
    in
    (card, ops)

  (* Only works on EVals and ECompVals *)
  let rec et_compose f eta etb =
    match (eta, etb) with
    | EVal (psa, contra), EVal (psb, contrb) ->
        let ps' = min_precision psa psb in
        let contr' = Contrib.union f contra contrb in
        pure @@ EVal (ps', contr')
    (* Compose each part independently *)
    | ECompositeVal (afull, asp), ECompositeVal (bfull, bsp) ->
        let%bind full = et_compose f afull bfull in
        let%bind sp = et_compose f asp bsp in
        pure @@ ECompositeVal (full, sp)
    (* This shouldn't happen *)
    | _ ->
        fail0
          (Printf.sprintf
             "Sharding analysis: trying to et_compose non-EVal types %s and %s"
             (pp_expr_type eta) (pp_expr_type etb))

  let et_seq_compose = et_compose (fun _ a b -> Some (combine_seq a b))

  let et_par_compose = et_compose (fun _ a b -> Some (combine_par a b))

  (* WARNING: only guaranteed accurate for fully normalised types *)
  let et_equal eta etb =
    match (eta, etb) with
    | EVal (psa, contra), EVal (psb, contrb) ->
        let ps_eq = psa = psb in
        let contr_eq =
          Contrib.equal
            (fun (cca, copa) (ccb, copb) ->
              cca = ccb && ContribOps.equal copa copb)
            contra contrb
        in
        ps_eq && contr_eq
    (* Give it our best shot *)
    | _ -> String.compare (pp_expr_type eta) (pp_expr_type etb) = 0

  (* For all the contributions in etc, add cond Op in et *)
  let add_conditional etc et same_variables =
    (* Convention that must be respected by sa_expr *)
    let spurious = et_equal etc et_nothing in
    match (etc, et) with
    | EVal (_, ccontr), EVal (ps, contr) ->
        let ps' =
          min_precision
            (if spurious || same_variables then Exactly else SubsetOf)
            ps
        in
        (* Some (cc, ContribOps.add Conditional cops) *)
        let contr' =
          Contrib.merge
            (fun _ cond contr ->
              match (cond, contr) with
              | None, None -> None
              | None, Some csumm -> Some csumm
              (* contribution_source in conditional, but not contribution *)
              | Some _, None ->
                  (* Have to store it anyway, but mark as not contributing *)
                  Some (NoContrib, ContribOps.singleton Conditional)
              (* contribution_source in both cond and contr *)
              | Some _, Some (cc, cops) ->
                  Some (cc, ContribOps.add Conditional cops))
            ccontr contr
        in
        pure @@ EVal (ps', contr')
    | _ -> fail0 "Sharding analysis: add_conditional non-EVal type"

  let create_unknown_fun ~num_arrows =
    let rec cuf_aux na fp =
      if na = 1 then EFun (EFunDef ([ fp ], DefExpr EUnknown))
      else EFun (EFunDef ([ fp ], DefExpr (cuf_aux (na - 1) (fp + 1))))
    in
    cuf_aux num_arrows 0

  let rec efun_depth et =
    match et with
    | EFun (EFunDef (_, DefExpr expr)) -> 1 + efun_depth expr
    | EFun (EFunDef (_, (DefFormalParameter _ | DefProcParameter _))) -> 1
    | _ -> 1

  (* Anything that has EUnknown/UnknownSource within it is Unknown *)
  let rec et_is_unknown et =
    match et with
    | EUnknown -> true
    | EVal (_, kc) -> Contrib.mem UnknownSource kc
    | ECompositeVal (full, special) ->
        et_is_unknown full || et_is_unknown special
    | EFun (EFunDef (_, (DefFormalParameter _ | DefProcParameter _))) -> false
    | EOp (_, expr) -> et_is_unknown expr
    | EComposeSequence etl -> List.exists et_is_unknown etl
    | EComposeParallel (c, etl) -> List.exists et_is_unknown (c :: etl)
    | EFun (EFunDef (_, DefExpr expr)) -> et_is_unknown expr
    | EApp (EFunDef (_, DefExpr expr), etl) ->
        List.exists et_is_unknown (expr :: etl)
    | EApp (_, etl) -> List.exists et_is_unknown etl

  let differ_only_in_constants (val_etl : expr_type list) =
    let collect_variables et =
      match et with
      | EVal (_, contr) ->
          fst @@ List.split @@ Contrib.bindings
          @@ Contrib.filter
               (fun cs _ ->
                 match cs with
                 | ConstantLiteral _ | ConstantContractParameter _ -> false
                 | _ -> true)
               contr
      | _ -> []
    in
    let clauses_vars =
      List.map (fun et -> ContribSources.of_list (collect_variables et)) val_etl
    in
    (* Union of the variables in all clauses *)
    let all_variables =
      List.fold_left
        (fun acc cl_vars -> ContribSources.union acc cl_vars)
        ContribSources.empty clauses_vars
    in
    (* Are the variables in all clauses equal? *)
    List.for_all
      (fun cl_vars -> ContribSources.equal cl_vars all_variables)
      clauses_vars

  let rec et_normalise (et : expr_type) =
    match et with
    (* Nothing to do *)
    | EUnknown | EVal _ -> pure @@ et
    | ECompositeVal (full, spc) ->
        let%bind nfull = et_normalise full in
        let%bind nspc = et_normalise spc in
        pure @@ ECompositeVal (nfull, nspc)
    | EOp (op, expr) -> (
        let%bind nexpr = et_normalise expr in
        match nexpr with
        | EVal (ps, contrs) ->
            (* Distribute operation over contributions *)
            let contrs' =
              Contrib.map
                (fun (cc, cops) -> (cc, ContribOps.add op cops))
                contrs
            in
            let kc = (ps, contrs') in
            pure @@ EVal kc
        (* Cannot perform operation, but normalisation might simplify expr *)
        | _ -> pure @@ EOp (op, nexpr) )
    | EComposeSequence etl ->
        let%bind netl = mapM ~f:et_normalise etl in
        let all_vals = List.for_all et_is_val netl in
        if all_vals then
          match netl with
          | x :: netl' -> foldM ~f:et_seq_compose ~init:x netl'
          | _ -> pure @@ et_nothing
        else pure @@ EComposeSequence netl
    | EComposeParallel (xet, cl_etl) ->
        let%bind nxet = et_normalise xet in
        let%bind ncl_etl = mapM ~f:et_normalise cl_etl in
        let all_vals = et_is_val nxet && List.for_all et_is_val ncl_etl in
        if all_vals then
          (* Don't want to mix et_nothing in and lose precision *)
          (* Guaranteed to have at least one clauses by the typechecker *)
          let fc = List.hd ncl_etl in
          let%bind cl_et = foldM ~f:et_par_compose ~init:fc ncl_etl in
          (* If clauses have the same non-constants, do not reduce precision,
             since precision only tracks variable contributions *)
          let same_variables = differ_only_in_constants ncl_etl in
          add_conditional nxet cl_et same_variables
        else pure @@ EComposeParallel (nxet, ncl_etl)
    (* Normalise within function bodies *)
    | EFun (EFunDef (dbl, DefExpr expr)) ->
        let%bind nexpr = et_normalise expr in
        pure @@ EFun (EFunDef (dbl, DefExpr nexpr))
    (* Cannot normalise unknown functions *)
    | EFun (EFunDef (_, DefFormalParameter _)) -> pure @@ et
    | EFun (EFunDef (_, DefProcParameter _)) -> pure @@ et
    (* Normalise when EApp referent is known *)
    | EApp (EFunDef (dbls, DefExpr fde), etl) ->
        let%bind nfde = et_normalise fde in
        let%bind netl = mapM ~f:et_normalise etl in
        (* All arguments are known *)
        let all_known =
          List.for_all et_is_val netl || List.for_all et_is_known_fun netl
        in
        if all_known then
          (* There is a mismatch between Fun and App. Fun takes a single
             parameter, whereas App takes multiple arguments, i.e. length dbl = 1.
             As such, we apply arguments one by one *)
          let rec subst pid netl nfden =
            let arg_et = List.hd netl in
            let%bind nfde = substitute_argument pid arg_et nfden in
            (* TODO: is this necessary? *)
            (* let%bind nfde = et_normalise nfde in *)
            match netl with
            (* This was our last argument *)
            | [ _ ] -> pure @@ nfde
            (* More arguments exist, we have more substitution to do *)
            | _ :: rem_netl ->
                let%bind next = pid_next pid in
                subst next rem_netl nfde
            (* This can't happen *)
            | _ -> fail0 "Sharding analysis: EApp argument list is empty??"
          in
          (* Scilla type checking guarantees this is safe *)
          let dbl = List.hd dbls in
          let%bind substituted = subst (FormalParameter dbl) netl nfde in
          et_normalise substituted
        else if et_is_unknown fde then
          (* Special case: applying EUnknown function, which we can do no
              matter what the arguments are. It would be helpful to give this
              the appropriate type (i.e. it might need to be a function that
              returns EUnknown), but that's hard. It would imply us having a
              type sytem for our type system. Rather than do that, we give
              values the appropriate type when the needed type becomes known (at
              function application time) *)
          pure @@ EUnknown
        else pure @@ EApp (EFunDef (dbls, DefExpr nfde), netl)
    | EApp (EFunDef (_, DefFormalParameter _), _) -> pure @@ et
    | EApp (EFunDef (_, DefProcParameter _), _) -> pure @@ et

  (* Parameter identifier *)
  and pid_idx_eq idx cs =
    match cs with
    | FormalParameter i -> idx = i
    | ProcParameter i -> idx = i
    | _ -> false

  and pid_next cs =
    match cs with
    | FormalParameter i -> pure @@ FormalParameter (i + 1)
    | ProcParameter i -> pure @@ ProcParameter (i + 1)
    | _ -> fail0 "Sharding analysis: wrong argument to pid_next"

  and substitute_argument pid this in_this =
    let combine_param_arg (fd_ps, fd_contr) (arg_ps, arg_contr) =
      let opt_fpc = Contrib.find_opt pid fd_contr in
      match opt_fpc with
      | Some fpc ->
          let ps = min_precision arg_ps fd_ps in
          (* Compute contributions due to the argument *)
          let acontr = Contrib.map (fun c -> combine_product c fpc) arg_contr in
          (* Add them to fd_contr instead of old value *)
          let fd_contr = Contrib.remove pid fd_contr in
          let contr =
            Contrib.union (fun _ a b -> Some (combine_seq a b)) acontr fd_contr
          in
          EVal (ps, contr)
      | None ->
          (* If the formal parameter is not used, argument is not used,
                 i.e. nothing changes *)
          in_this
    in
    let cont et = substitute_argument pid this et in
    let%bind result =
      match in_this with
      | EUnknown -> pure @@ EUnknown
      | EVal fd -> (
          (* Combine parameters's contributions with those of the argument, i.e.
             arg_contr. *)
          match this with
          | EVal arg -> pure @@ combine_param_arg fd arg
          | ECompositeVal (EVal full_arg, EVal special_arg) ->
              pure
              @@ ECompositeVal
                   ( combine_param_arg fd full_arg,
                     combine_param_arg fd special_arg )
          (* Do partial evaluation if possible *)
          (* TODO: think about this; make sure it's correct *)
          (* The intuition is we would only get here if one of the branches
             would eventually evaluate to EUnknown *)
          | ECompositeVal (EVal full_arg, b) ->
              pure @@ ECompositeVal (combine_param_arg fd full_arg, b)
          | ECompositeVal (a, EVal special_arg) ->
              pure @@ ECompositeVal (a, combine_param_arg fd special_arg)
          | ECompositeVal (full, spc) ->
              let%bind sfull = cont full in
              let%bind sspc = cont spc in
              pure @@ ECompositeVal (sfull, sspc)
          (* TODO FIXME: this is dodgy and not robust in the face of change *)
          (* We should have a reliable way to express when substitution needs to happen *)
          | _ -> pure @@ in_this )
      | ECompositeVal (full, spc) -> (
          match this with
          | ECompositeVal (tfull, tspc) ->
              (* If subst'ing a CompositeVal into a CompositeVal, do it pairwise *)
              let%bind sfull = substitute_argument pid tfull full in
              let%bind sspc = substitute_argument pid tspc spc in
              pure @@ ECompositeVal (sfull, sspc)
          | _ ->
              let%bind sfull = cont full in
              let%bind sspc = cont spc in
              pure @@ ECompositeVal (sfull, sspc) )
      | EOp (op, expr) ->
          let%bind sexpr = cont expr in
          pure @@ EOp (op, sexpr)
      | EComposeSequence etl ->
          let%bind setl = mapM ~f:cont etl in
          pure @@ EComposeSequence setl
      | EComposeParallel (c, etl) ->
          let%bind sc = cont c in
          let%bind setl = mapM ~f:cont etl in
          pure @@ EComposeParallel (sc, setl)
      | EFun (EFunDef (dbl, DefExpr fd)) ->
          (* Functions are well-scoped, so we can safely substitute inside
             their definitions, i.e. the nesting protects us from mistakes. *)
          let%bind sfd = cont fd in

          (* All our functions have just one parameter *)
          let fp = List.hd dbl in

          if pid_idx_eq fp pid then
            (* If substituting the formal parameter, we only return the body *)
            pure @@ sfd
          else
            (* Otherwise, retain function *)
            pure @@ EFun (EFunDef (dbl, DefExpr sfd))
      (* This substitutes returned functions *)
      | EFun (EFunDef (_, DefFormalParameter i))
      | EFun (EFunDef (_, DefProcParameter i)) ->
          if pid_idx_eq i pid then
            match this with
            (* TODO: should do this only for DefExpr? *)
            | EFun _ -> pure @@ this
            | _ -> fail0 "Sharding analysis: substituting non-EFun into EFun"
          else
            (* Not the function we're looking for; nothing to do *)
            pure @@ in_this
      (* Substitute referents in function applications *)
      | EApp (EFunDef (fbl, DefFormalParameter i), etl) ->
          let%bind setl = mapM ~f:cont etl in
          if pid_idx_eq i pid then
            match this with
            | EFun fd -> pure @@ EApp (fd, setl)
            | _ -> fail0 "Sharding analysis: substituting non-EFun into EFun"
          else pure @@ EApp (EFunDef (fbl, DefFormalParameter i), setl)
      | EApp (EFunDef (dbl, DefProcParameter i), etl) ->
          let%bind setl = mapM ~f:cont etl in
          if pid_idx_eq i pid then
            match this with
            | EFun fd -> pure @@ EApp (fd, setl)
            | _ -> fail0 "Sharding analysis: substituting non-EFun into EFun"
          else pure @@ EApp (EFunDef (dbl, DefProcParameter i), setl)
      | EApp (EFunDef (dbl, DefExpr expr), etl) ->
          let%bind setl = mapM ~f:cont etl in
          pure @@ EApp (EFunDef (dbl, DefExpr expr), setl)
    in
    pure @@ result

  (* For each contract component, we keep track of the operations it performs.
     This gives us enough information to tell whether two transitions have disjoint
     footprints and thus commute. *)
  type component_operation =
    (* Read of cfield, with map keys which are comp_params if field is a map *)
    | Read of pseudofield
    | Write of pseudofield * expr_type
    | AcceptMoney
    | ConditionOn of expr_type
    | EmitEvent of expr_type
    | SendMessages of expr_type
    (* Top element -- in case of ambiguity, be conservative *)
    | AlwaysExclusive of ErrorUtils.loc option * string

  let pp_operation op =
    match op with
    | Read pf -> "Read " ^ pp_pseudofield pf
    | Write (pf, kc) ->
        "Write " ^ pp_pseudofield pf ^ " (" ^ pp_expr_type kc ^ ")"
    | AcceptMoney -> "AcceptMoney"
    | ConditionOn kc -> "ConditionOn " ^ pp_expr_type kc
    | EmitEvent kc -> "EmitEvent " ^ pp_expr_type kc
    | SendMessages kc -> "SendMessages " ^ pp_expr_type kc
    | AlwaysExclusive (opt_loc, msg) ->
        let loc_str =
          match opt_loc with
          | Some loc -> "line " ^ string_of_int loc.lnum
          | None -> ""
        in
        let msg_str =
          (if String.length loc_str > 0 then ": " else "")
          ^ if String.length msg > 0 then msg else ""
        in
        "AlwaysExclusive (" ^ loc_str ^ msg_str ^ ")"

  module OrderedComponentOperation = struct
    type t = component_operation

    (* XXX: This is super hacky, but works *)
    let compare a b =
      let str_a = pp_operation a in
      let str_b = pp_operation b in
      compare str_a str_b
  end

  (* A component's summary is the set of the operations it performs *)
  module ComponentSummary = Set.Make (OrderedComponentOperation)

  let pp_summary summ =
    let ops = ComponentSummary.elements summ in
    List.fold_left (fun acc op -> acc ^ "  " ^ pp_operation op ^ "\n") "" ops

  type component_summary = ComponentSummary.t

  module PCMStatus = Set.Make (String)

  (* set of pcm_identifiers for which ident is the unit of the PCM *)
  type pcm_status = PCMStatus.t

  let pp_pcm_status ps = String.concat " " (PCMStatus.elements ps)

  type signature =
    (* ComponentSig: comp_params * component_summary *)
    | ComponentSig of (ER.rep ident * typ) list * component_summary
    (* Within a transition, we assign an identifier to all field values, i.e. we
       only treat final writes as proper writes, with all others being "global"
       bindings. This lets us track multiple reads/writes to a field in a
       transition in the same way we track expressions.*)
    | IdentSig of ident_shadow_status * pcm_status * expr_type

  let pp_sig k sgn =
    match sgn with
    | ComponentSig (comp_params, comp_summ) ->
        let ns = "Effect footprint for " ^ k in
        let ps =
          String.concat ", " @@ List.map (fun (i, _) -> get_id i) comp_params
        in
        let cs = pp_summary comp_summ in
        ns ^ "(" ^ ps ^ "): \n" ^ cs
    | IdentSig (_, pcm, et) ->
        let ns = "Signature for " ^ k ^ ": " in
        let is_unit = PCMStatus.cardinal pcm > 0 in
        let pcm_str =
          if is_unit then "PCM unit for: (" ^ pp_pcm_status pcm ^ ")" else ""
        in
        ns ^ pp_expr_type et ^ pcm_str

  module SAEnv = struct
    open AssocDictionary

    (* A map from identifier strings to their signatures. *)
    type t = signature dict

    (* Make an empty environment. *)
    let mk = make_dict

    (* In env, add mapping id => s *)
    let addS env id s = insert id s env

    (* Return None if key doesn't exist *)
    let lookupS env id = lookup id env

    (* In env, resolve id => s and return s (fails if cannot resolve). *)
    let resolvS ?(lopt = None) env id =
      match lookup id env with
      | Some s -> pure s
      | None ->
          let sloc =
            match lopt with Some l -> ER.get_loc l | None -> dummy_loc
          in
          fail1
            (Printf.sprintf
               "Couldn't resolve the identifier in sharding analysis: %s.\n" id)
            sloc

    (* retain only those entries "k" for which "f k" is true. *)
    let filterS env ~f = filter ~f env

    (* is "id" in the environment. *)
    let existsS env id =
      match lookup id env with Some _ -> true | None -> false

    (* add entries from env' into env. *)
    let appendS env env' =
      let kv = to_list env' in
      List.fold_left (fun acc (k, v) -> addS acc k v) env kv

    let pp env =
      let l = List.rev @@ to_list env in
      List.fold_left (fun acc (k, sgn) -> acc ^ pp_sig k sgn ^ "\n") "" l
  end

  type pcm_ident = string

  module type PCM = sig
    val pcm_identifier : pcm_ident

    val is_applicable_type : typ list -> bool

    val is_unit_literal : expr -> bool

    val is_unit : SAEnv.t -> expr -> bool

    val is_op : contrib_op -> bool

    val is_op_expr : expr -> ER.rep ident -> ER.rep ident -> bool

    val is_spurious_conditional_expr' :
      SAEnv.t -> ER.rep ident -> (pattern * expr_annot) list -> bool

    val is_spurious_conditional_stmt' :
      expr_type -> ER.rep ident -> (pattern * stmt_annot list) list -> bool
  end

  (* BEGIN functions to do with detecting spurious match exprs/stmts  *)
  let sc_option_check pcm_is_applicable_type x clauses =
    let cond_type = (ER.get_type (get_rep x)).tp in
    let is_integer_option =
      match cond_type with
      | ADT (Ident ("Option", _), typs) -> pcm_is_applicable_type typs
      | _ -> false
    in
    let have_two_clauses = List.length clauses = 2 in
    is_integer_option && have_two_clauses

  let sc_get_clauses clauses =
    let detect_clause cls ~f =
      let detected =
        List.filter
          (fun (pattern, _) ->
            let binders = get_pattern_bounds pattern in
            let matches = f binders in
            matches)
          cls
      in
      if List.length detected > 0 then Some (List.hd detected) else None
    in
    let some_branch =
      detect_clause clauses ~f:(fun binders -> List.length binders = 1)
    in
    let none_branch =
      detect_clause clauses ~f:(fun binders -> List.length binders = 0)
    in
    (some_branch, none_branch)

  (* Given a match expression, determine whether it is "spurious", i.e. would
     not have to exist if we had monadic operations on option types. This
     function is PCM-specific. *)
  let sc_expr pcm_is_applicable_type pcm_is_unit pcm_is_op senv x clauses =
    let is_integer_option = sc_option_check pcm_is_applicable_type x clauses in
    if is_integer_option then
      let some_branch, none_branch = sc_get_clauses clauses in
      match (some_branch, none_branch) with
      | Some some_branch, Some none_branch ->
          let some_p, (some_expr, _) = some_branch in
          let _, (none_expr, _) = none_branch in
          (* e.g. match (option int) with | Some int => int | None => 0 *)
          let clauses_form_pcm_unit =
            let some_pcm_unit =
              let b = List.hd (get_pattern_bounds some_p) in
              match some_expr with Var q -> equal_id b q | _ -> false
            in
            let none_pcm_unit = pcm_is_unit senv none_expr in
            some_pcm_unit && none_pcm_unit
          in
          (* e.g. match (option int) with | Some int => PCM_op int X | None => X *)
          let clauses_form_pcm_op =
            let none_ident =
              match none_expr with Var q -> Some q | _ -> None
            in
            match none_ident with
            | None -> false
            | Some none_ident ->
                let some_ident = List.hd (get_pattern_bounds some_p) in
                pcm_is_op some_expr some_ident none_ident
          in
          clauses_form_pcm_unit || clauses_form_pcm_op
      | _ -> false
    else false

  let sc_stmt pcm_is_applicable_type pcm_is_op xc x
      (clauses : (pattern * stmt_annot list) list) =
    let is_integer_option = sc_option_check pcm_is_applicable_type x clauses in
    if is_integer_option then
      let some_branch, none_branch = sc_get_clauses clauses in
      match (some_branch, none_branch) with
      | Some some_branch, Some none_branch ->
          let some_p, some_stmts = some_branch in
          let _, none_stmts = none_branch in
          (* e.g.
             opt_x <- map[key1][key2];
             match opt_x with
               | Some x => q = PCM_op x diff; map[key1][key2] := q
               | None => map[key1][key2] := diff
             Make sure you check it's map[key1][key2] in both branches! *)
          let ok = List.length none_stmts = 1 && List.length some_stmts = 2 in
          ok
          &&
          let clauses_form_pcm_op =
            (* What is diff? *)
            let none_ident, none_ps =
              let none_stmt, _ = List.hd none_stmts in
              match none_stmt with
              | MapUpdate (m, klist, Some i) ->
                  (Some i, Pseudofield (m, Some klist))
              (* TODO XXX: this pseudofield is junk; should probably use an option *)
              | _ -> (None, Pseudofield (x, None))
            in

            (* Make sure opt_x is Exactly {map[key1][key2], Linear, }*)
            let cs =
              Contrib.singleton none_ps (LinearContrib, ContribOps.empty)
            in
            let expected_et = EVal (Exactly, cs) in
            let good_et = et_equal xc expected_et in
            good_et
            &&
            (* Make sure the some branch is well-formed *)
            match none_ident with
            | None -> false
            | Some none_ident -> (
                let some_ident = List.hd (get_pattern_bounds some_p) in
                match some_stmts with
                | (Bind (q, (expr, _)), _) :: (st, _) :: _ -> (
                    let is_op = pcm_is_op expr some_ident none_ident in
                    is_op
                    &&
                    match st with
                    | MapUpdate (m, klist, Some i) ->
                        equal_id q i
                        (* f[keys] := q *)
                        && OrderedContribSource.compare none_ps
                             (Pseudofield (m, Some klist))
                           = 0
                    | _ -> false )
                | _ -> false )
          in
          clauses_form_pcm_op
      | _ -> false
    else false

  (* END functions to do with detecting spurious match exprs/stmts  *)

  (* TODO: move PCMs into a separate file *)
  (* This is a "special" PCM, which does not follow the structure of others *)
  module State_Split_PCM = struct
    let pcm_identifier = "owner_overwrites"
  end

  (* Generic addition PCM for all signed and unsigned types *)
  module Integer_Addition_PCM = struct
    let pcm_identifier = "integer_add"

    (* Can PCM values have this type? *)
    let is_applicable_type typs =
      let is_single = List.compare_length_with typs 1 = 0 in
      if is_single then
        let typ = List.hd typs in
        PrimTypes.is_int_type typ || PrimTypes.is_uint_type typ
      else false

    let is_unit_literal expr =
      match expr with
      | Literal (IntLit l) -> String.equal (PrimTypes.string_of_int_lit l) "0"
      | Literal (UintLit l) -> String.equal (PrimTypes.string_of_uint_lit l) "0"
      | _ -> false

    let is_unit (senv : signature AssocDictionary.dict) expr =
      is_unit_literal expr
      ||
      match expr with
      | Var i -> (
          let opt_isig = SAEnv.lookupS senv (get_id i) in
          match opt_isig with
          | Some (IdentSig (_, pcms, _)) -> PCMStatus.mem pcm_identifier pcms
          | _ -> false )
      | _ -> false

    let is_op op = match op with BuiltinOp Builtin_add -> true | _ -> false

    let is_op_expr expr ida idb =
      match expr with
      | Builtin ((Builtin_add, _), actuals) ->
          let a_uses =
            List.length @@ List.filter (fun k -> equal_id k ida) actuals
          in
          let b_uses =
            List.length @@ List.filter (fun k -> equal_id k idb) actuals
          in
          a_uses = 1 && b_uses = 1
      | _ -> false

    let is_spurious_conditional_expr' =
      sc_expr is_applicable_type is_unit is_op_expr

    let is_spurious_conditional_stmt' = sc_stmt is_applicable_type is_op_expr
  end

  let int_add_pcm = (module Integer_Addition_PCM : PCM)

  let enabled_pcms = [ int_add_pcm ]

  let pcm_unit senv expr =
    let unit_of =
      List.filter (fun (module P : PCM) -> P.is_unit senv expr) enabled_pcms
    in
    PCMStatus.of_list
    @@ List.map (fun (module P : PCM) -> P.pcm_identifier) unit_of

  let is_spurious_conditional_expr senv x clauses =
    List.exists
      (fun (module P : PCM) -> P.is_spurious_conditional_expr' senv x clauses)
      enabled_pcms

  let is_spurious_conditional_stmt xc x clauses =
    List.exists
      (fun (module P : PCM) -> P.is_spurious_conditional_stmt' xc x clauses)
      enabled_pcms

  let identify_pcm_for_op (op : contrib_op) =
    let candidate =
      List.find_opt (fun (module P : PCM) -> P.is_op op) enabled_pcms
    in
    match candidate with
    | Some (module P : PCM) -> Some P.pcm_identifier
    | _ -> None

  let is_comm_write op constant_fields =
    match op with
    | Write (wp, et) -> (
        match et with
        | EVal (ps, kc) -> (
            let field_contribs =
              Contrib.filter
                (fun cs _ ->
                  match cs with
                  | Pseudofield (f, _) ->
                      (* non-constant field contribution *)
                      not @@ is_mem_id f constant_fields
                  | _ -> false)
                kc
            in
            (* There is one non-constant field contribution *)
            let exactly_one =
              ps = Exactly && Contrib.cardinal field_contribs = 1
            in
            if not exactly_one then (false, None)
            else
              let ocs = Contrib.find_opt (Pseudofield wp) field_contribs in
              match ocs with
              (* From the field we're writing to *)
              | Some (card, ops) -> (
                  (* The contribution is Linear and has one operation applied to it *)
                  let linear_op =
                    card = LinearContrib && ContribOps.cardinal ops = 1
                  in
                  if not linear_op then (false, None)
                  else
                    (* And that operation is a PCM operation for some PCM *)
                    let op = ContribOps.choose ops in
                    match identify_pcm_for_op op with
                    | Some pcm_id -> (true, Some pcm_id)
                    | None -> (false, None) )
              | _ -> (false, None) )
        | _ -> (false, None) )
    | _ -> (false, None)

  (* Does the given contrib_source show up in known & normalised expr_type? *)
  let rec cs_in_known_et cs et =
    match et with
    | EVal (_, kc) -> (
        match Contrib.find_opt cs kc with Some _ -> true | _ -> false )
    | ECompositeVal (full, _) -> cs_in_known_et cs full
    | _ -> false

  let pseudofields_in_known_et et =
    match et with
    | EVal (_, kc) ->
        let sources, _ = List.split @@ Contrib.bindings kc in
        List.flatten
        @@ List.map
             (fun cs -> match cs with Pseudofield pf -> [ pf ] | _ -> [])
             sources
    | _ -> []

  let translate_proc_idx_to_ident comp idx =
    let implicit_params = SCU.append_implict_comp_params [] in
    let params, _ = List.split @@ implicit_params @ comp.comp_params in
    match List.nth_opt params idx with
    | Some ident -> pure @@ ident
    | None ->
        fail0
          (Printf.sprintf
             "Sharding analysis: procedure %s argument %d doesn't exist"
             (get_id comp.comp_name) idx)

  let rec proc_args_in_et comp et =
    match et with
    | EVal (_, kc) ->
        let sources, _ = List.split @@ Contrib.bindings kc in
        let%bind x =
          mapM
            ~f:(fun cs ->
              match cs with
              | ProcParameter i ->
                  let%bind id = translate_proc_idx_to_ident comp i in
                  pure @@ [ id ]
              | _ -> pure @@ [])
            sources
        in
        pure @@ List.flatten x
    | ECompositeVal (_, special) -> proc_args_in_et comp special
    | _ -> pure @@ []

  (* Returns a list of pairs of keys which are dangerous if they alias *)
  (* TODO FIXME: make this O(n * log n) rather than O(n^2) *)
  let get_dangerous_alias_keys comp_summ =
    let map_rws =
      ComponentSummary.elements
      @@ ComponentSummary.filter
           (fun op ->
             match op with
             | Read (_, Some _) | Write ((_, Some _), _) -> true
             | _ -> false)
           comp_summ
    in
    let discordances_in keys1 keys2 =
      let ks = List.combine keys1 keys2 in
      List.filter (fun (k1, k2) -> not (get_id k1 = get_id k2)) ks
    in
    (* Order within a pair does not matter *)
    let pair_compare (a1, b1) (a2, b2) =
      let ida1, idb1 = (get_id a1, get_id b1) in
      let ida2, idb2 = (get_id a2, get_id b2) in
      if (ida1 = ida2 && idb1 = idb2) || (ida1 = idb2 && idb1 = ida2) then 0
      else compare (a1, b1) (a2, b2)
    in

    List.sort_uniq pair_compare
    @@ List.flatten
    @@ List.map
         (fun op1 ->
           match op1 with
           | Read (m1, Some keys1) | Write ((m1, Some keys1), _) ->
               List.flatten
               @@ List.map
                    (fun op2 ->
                      match op2 with
                      | Read (m2, Some keys2) | Write ((m2, Some keys2), _) ->
                          if get_id m1 = get_id m2 then
                            discordances_in keys1 keys2
                          else []
                      | _ -> [])
                    map_rws
           | _ -> [])
         map_rws

  let is_spurious_read op context cws constant_fields =
    match op with
    | Read (f, keys) ->
        let read_is_used =
          ComponentSummary.exists
            (fun user_op ->
              match user_op with
              (* A read is used if it flows into a non-commutative write or into
                 a write to a different field *)
              | Write (pf, et) ->
                  let is_cw = ComponentSummary.mem user_op cws in
                  let same_field = pp_compare (f, keys) pf = 0 in
                  if is_cw && same_field then false
                  else
                    cs_in_known_et (Pseudofield (f, keys)) et
                    || et_is_unknown et
              (* For EmitEvent and SendMessages, we inspect the FULL part of the
                 ECompositeVal. If any value is Unknown, we are conservative. *)
              | ConditionOn et | EmitEvent et | SendMessages et ->
                  cs_in_known_et (Pseudofield (f, keys)) et || et_is_unknown et
              | Read _ | AcceptMoney | AlwaysExclusive _ -> false)
            context
        in
        is_mem_id f constant_fields || not read_is_used
    | _ -> false

  let env_bind_component senv comp (sgn : signature) =
    let i = comp.comp_name in
    SAEnv.addS senv (get_id i) sgn

  let env_bind_ident_map senv idlist sgn =
    let idlist = List.mapi (fun i k -> (i, k)) idlist in
    List.fold_left
      (fun acc_senv (idx, (i, t)) ->
        SAEnv.addS acc_senv (get_id i) (sgn idx i t))
      senv idlist

  let contrib_pseudofield (f, opt_keys) =
    let csumm = (LinearContrib, ContribOps.empty) in
    let csrc = Pseudofield (f, opt_keys) in
    Contrib.singleton csrc csumm

  let et_pseudofield (f, opt_keys) = (Exactly, contrib_pseudofield (f, opt_keys))

  let et_literal l =
    EVal
      ( Exactly,
        Contrib.singleton (ConstantLiteral l) (LinearContrib, ContribOps.empty)
      )

  let et_contract_param id =
    EVal
      ( Exactly,
        Contrib.singleton (ConstantContractParameter id)
          (LinearContrib, ContribOps.empty) )

  let is_bottom_level_access m klist =
    let mt = (ER.get_type (get_rep m)).tp in
    let nindices = List.length klist in
    let map_access = nindices < TU.map_depth mt in
    not map_access

  let all_keys_are_parameters senv klist =
    let is_component_parameter k senv =
      let m = SAEnv.lookupS senv (get_id k) in
      match m with
      | None -> false
      | Some m_sig -> (
          match m_sig with
          | IdentSig (ComponentParameter, _, _) -> true
          | _ -> false )
    in
    List.for_all (fun k -> is_component_parameter k senv) klist

  let map_access_can_be_summarised senv m klist =
    is_bottom_level_access m klist && all_keys_are_parameters senv klist

  let rec et_field_keys et =
    let remove_dups = List.sort_uniq compare_id in
    match et with
    | EUnknown -> []
    | EVal (_, contr) ->
        let contrib_sources = fst @@ List.split @@ Contrib.bindings contr in
        let res =
          remove_dups @@ List.flatten
          @@ List.map
               (fun cs ->
                 match cs with Pseudofield (_, Some keys) -> keys | _ -> [])
               contrib_sources
        in
        res
    | ECompositeVal (full, _) -> remove_dups @@ et_field_keys full
    | EOp (_, _) -> remove_dups @@ et_field_keys et
    | EComposeSequence etl ->
        remove_dups @@ List.flatten @@ List.map et_field_keys etl
    | EComposeParallel (ec, etl) ->
        remove_dups @@ List.flatten
        @@ (et_field_keys ec :: List.map et_field_keys etl)
    | EFun (EFunDef (_, DefExpr fd)) -> remove_dups @@ et_field_keys fd
    | EApp (EFunDef (_, DefExpr fd), etl) ->
        remove_dups @@ List.flatten
        @@ (et_field_keys fd :: List.map et_field_keys etl)
    | EApp (EFunDef (_, (DefFormalParameter _ | DefProcParameter _)), etl) ->
        remove_dups @@ List.flatten @@ List.map et_field_keys etl
    | EFun (EFunDef (_, (DefFormalParameter _ | DefProcParameter _))) -> []

  let int_range a b =
    let rec int_range_rec l a b =
      if a > b then l else int_range_rec (b :: l) a (b - 1)
    in
    int_range_rec [] a b

  let is_fun t = match t with FunType _ -> true | _ -> false

  let rec count_arrows t =
    match t with FunType (_, ret) -> 1 + count_arrows ret | _ -> 0

  (* Get the expr_type to assign to function formal parameters *)
  let get_fp_et fp_count fp_typ =
    let primitive = not (is_fun fp_typ) in
    if primitive then
      EVal
        ( Exactly,
          Contrib.singleton (FormalParameter fp_count)
            (LinearContrib, ContribOps.empty) )
    else
      let nargs = count_arrows fp_typ in
      let fps = int_range 0 (nargs - 1) in
      (* See comment attached to efun_desc explaining why we don't need to do
         this recursively if fp takes functions as parameters as well *)
      EFun (EFunDef (fps, DefFormalParameter fp_count))

  (* Get the expr_type to assign to procedure parameters *)
  let get_pp_et arg_idx typ =
    if is_fun typ then
      let nargs = count_arrows typ in
      let fps = int_range 0 (nargs - 1) in
      EFun (EFunDef (fps, DefProcParameter arg_idx))
    else
      EVal
        ( Exactly,
          Contrib.singleton (ProcParameter arg_idx)
            (LinearContrib, ContribOps.empty) )

  (* Return the parameters actually used to in the given ComponentSig summary *)
  let idents_used_as_map_keys (proc_sig : signature) =
    let idents_in_op op =
      match op with
      | Read (_, Some keys) -> keys
      | Write ((_, Some keys), et) -> keys @ et_field_keys et
      | Write ((_, None), et) | EmitEvent et | SendMessages et | ConditionOn et
        ->
          et_field_keys et
      | Read (_, None) | AcceptMoney | AlwaysExclusive (_, _) -> []
    in
    match proc_sig with
    | ComponentSig (_, proc_summ) ->
        let idents_in_summ =
          List.sort_uniq compare_id @@ List.flatten
          @@ List.map idents_in_op (ComponentSummary.elements proc_summ)
        in
        pure @@ idents_in_summ
    | _ -> fail0 "Sharding analysis: procedure summary is not of the right type"

  let rec translate_et_field_keys et key_mapping =
    (* WARNING: we need to be very careful with this. While it may look
       superficially similar to the map_keys in translate_op (which is always
       safe), this is NOT the same. Keys that are not arguments may flow into
       expr_types. We don't need to translate those, i.e. they come from our
       caller and are already valid for our caller. And we wouldn't know how to
       translate them anyway. *)
    let map_keys keys =
      List.map
        (fun k ->
          match List.assoc_opt (get_id k) key_mapping with
          (* Translate if we know how *)
          | Some x -> x
          (* If we don't know how, this contrib_source is already valid for our caller *)
          | None -> k)
        keys
    in
    let tt_contrib_source cs =
      match cs with
      | Pseudofield (f, Some keys) -> Pseudofield (f, Some (map_keys keys))
      (* This is only applied to pseudofields *)
      | _ -> cs
    in
    let translate_comp_contribs contribs =
      let c_keys, c_values = List.split @@ Contrib.bindings contribs in
      let new_keys = List.map tt_contrib_source c_keys in
      let new_bindings = List.combine new_keys c_values in
      Contrib.of_seq (List.to_seq new_bindings)
    in
    let cont expr = translate_et_field_keys expr key_mapping in
    match et with
    | EUnknown -> EUnknown
    | EVal (ps, contr) -> EVal (ps, translate_comp_contribs contr)
    | EOp (op, expr) -> EOp (op, cont expr)
    | EComposeSequence etl ->
        let setl = List.map cont etl in
        EComposeSequence setl
    | EComposeParallel (ec, etl) ->
        let setl = List.map cont etl in
        EComposeParallel (cont ec, setl)
    | EFun (EFunDef (dbl, DefExpr fd)) ->
        EFun (EFunDef (dbl, DefExpr (cont fd)))
    | EApp (EFunDef (dbl, DefExpr fd), etl) ->
        let setl = List.map cont etl in
        EApp (EFunDef (dbl, DefExpr (cont fd)), setl)
    | _ -> et

  let et_can_be_summarised senv et =
    let can_summarise c =
      match c with
      | Pseudofield (m, Some klist) -> map_access_can_be_summarised senv m klist
      | Pseudofield (_, None) -> true
      | ConstantLiteral _ | ConstantContractParameter _ -> true
      | UnknownSource | FormalParameter _ | ProcParameter _ -> true
    in
    match et with
    | EVal (_, kc) ->
        let c_keys, _ = List.split @@ Contrib.bindings kc in
        List.for_all can_summarise c_keys
    | _ -> false

  (* Rewrite an operation written in terms of proc_params into an operation
     written in terms of call_args. We need to rewrite both the map keys
     and the expr_types in the operation. *)
  let translate_op op proc_params call_args arg_ets =
    let pp_names, _ =
      List.split @@ List.map (fun (i, t) -> (get_id i, t)) proc_params
    in
    let pp_css = List.mapi (fun i _ -> ProcParameter i) proc_params in
    let key_mapping = List.combine pp_names call_args in
    let cs_to_et_mapping = List.combine pp_css arg_ets in
    (* The assoc will fail only if there's a bug *)
    let map_keys keys =
      List.map (fun k -> List.assoc (get_id k) key_mapping) keys
    in
    (* FIXME TODO: make this more efficient!! *)
    let translate_comp_et et =
      let substituted =
        foldM
          ~f:(fun in_this (pid, this) -> substitute_argument pid this in_this)
          ~init:et cs_to_et_mapping
      in
      match substituted with
      | Ok sub -> (
          let res = et_normalise sub in
          match res with
          | Ok r ->
              (* We need to rewrite field keys in the expr_type as well! *)
              translate_et_field_keys r key_mapping
          | Error _ -> et )
      | Error _ -> et
    in

    (* TODO: currently, if the translated_comp_et is et_nothing, the operation
       still exists. This is slightly annoying, e.g. for ConditionOn *)
    match op with
    | Read (f, Some keys) -> Read (f, Some (map_keys keys))
    | Write ((f, None), et) -> Write ((f, None), translate_comp_et et)
    | Write ((f, Some keys), et) ->
        Write ((f, Some (map_keys keys)), translate_comp_et et)
    | ConditionOn et -> ConditionOn (translate_comp_et et)
    | EmitEvent et -> EmitEvent (translate_comp_et et)
    | SendMessages et -> SendMessages (translate_comp_et et)
    | Read (_, None) | AcceptMoney | AlwaysExclusive _ -> op

  let procedure_call_summary senv p (proc_sig : signature) arglist arg_ets =
    let implicit_params = SCU.append_implict_comp_params [] in
    let ip_vals, _ = List.split implicit_params in
    (* Scilla typechecker ensures arg types are correct; we don't need them *)
    let arglist = ip_vals @ arglist in
    let implicit_ets =
      List.mapi (fun idx (_, typ) -> get_pp_et idx typ) implicit_params
    in
    let arg_ets = implicit_ets @ arg_ets in
    match proc_sig with
    | ComponentSig (proc_params, proc_summ) ->
        let proc_params = implicit_params @ proc_params in
        let pp_vals, _ = List.split @@ proc_params in
        (* To summarise the procedure call: all idents used as map keys in
           the called procedure MUST be parameters of the caller component *)
        let%bind idents_used_as_keys = idents_used_as_map_keys proc_sig in
        (* Does the called procedure use non-parameters as map keys? If yes,
           then we can't summarise it. I believe this check is redundant given the
           et_can_be_summarised check in MatchStmt, but better safe than sorry.*)
        let exist_non_params_used_as_keys =
          List.exists
            (fun i -> not @@ List.exists (fun q -> compare_id i q = 0) pp_vals)
            idents_used_as_keys
        in
        let%bind args_used_as_keys =
          (* XXX: Is there a way to do this that's easier to read? *)
          mapM
            ( List.filter (fun k ->
                  match k with Some _ -> true | None -> false)
            (* If the parameter (p) is used, the corresponding argument (a) is used *)
            @@ List.map2
                 (fun p a ->
                   (* Be very careful with List.mem and such -- they don't work with idents *)
                   if
                     List.exists
                       (fun q -> compare_id p q = 0)
                       idents_used_as_keys
                   then Some a
                   else None)
                 pp_vals arglist )
            (* This can't fail *)
            ~f:(fun k -> match k with Some a -> pure @@ a | None -> fail0 "")
        in
        let can_summarise =
          (not exist_non_params_used_as_keys)
          && all_keys_are_parameters senv args_used_as_keys
        in
        if can_summarise then
          pure
          @@ ComponentSummary.map
               (fun op -> translate_op op proc_params arglist arg_ets)
               proc_summ
        else
          let loc = SR.get_loc (get_rep p) in
          let proc_name = get_id p in
          pure
          @@ ComponentSummary.singleton
               (AlwaysExclusive (Some loc, "CallProc " ^ proc_name))
    | _ -> fail0 "Sharding analysis: procedure summary is not of the right type"

  let get_ident_et senv i =
    let%bind isig = SAEnv.resolvS senv (get_id i) in
    match isig with
    | IdentSig (_, _, c) -> pure @@ c
    (* If this happens, it's a bug *)
    | _ -> fail0 "Sharding analysis: ident does not have a signature"

  (* Add a new identifier to the environment, keeping track of whether it
     shadows a component parameter *)
  let env_new_ident i ?pcms et senv =
    let pcms = match pcms with Some ps -> ps | None -> PCMStatus.empty in
    let id = get_id i in
    let opt_shadowed = SAEnv.lookupS senv id in
    let new_id_sig =
      match opt_shadowed with
      | None -> IdentSig (DoesNotShadow, pcms, et)
      | Some shadowed_sig -> (
          match shadowed_sig with
          | IdentSig (ComponentParameter, pcms, _) ->
              IdentSig (ShadowsComponentParameter, pcms, et)
          | _ -> IdentSig (DoesNotShadow, pcms, et) )
    in
    SAEnv.addS senv id new_id_sig

  let get_fun_sig senv f loc =
    let%bind fs = SAEnv.resolvS senv (get_id f) in
    match fs with
    | IdentSig (_, _, c) -> pure @@ c
    | _ ->
        fail1
          (Printf.sprintf
             "Sharding analysis: applied function %s does not have IdentSig"
             (get_id f))
          loc

  let get_eapp_referent senv f num_args loc =
    let%bind et = get_fun_sig senv f loc in
    match et with
    | EFun fdesc -> pure @@ fdesc
    | _ ->
        if et_is_unknown et then
          (* Hack to support evaluating Unknown functions. num_args tells us what the
             type of the function should be, so we just make it up *)
          let artificial = create_unknown_fun ~num_arrows:num_args in
          match artificial with
          | EFun fdesc -> pure @@ fdesc
          | _ -> fail1 "Sharding analysis: unknown EApp bug?" loc
        else
          fail1
            (Printf.sprintf
               "Sharding analysis: applied fun %s doesn't have EFun type (%s)"
               (get_id f) (pp_expr_type et))
            loc

  (* TODO: might want to track pcm_status for expressions *)
  (* fp_count keeps track of how many function formal parameters we've encountered *)
  let rec sa_expr senv fp_count (erep : expr_annot) =
    let cont senv expr = sa_expr senv fp_count expr in
    let e, rep = erep in
    match e with
    | Literal l -> pure @@ et_literal l
    | Var i ->
        let%bind ic = get_ident_et senv i in
        pure @@ ic
    | Builtin ((b, _), actuals) ->
        let%bind arg_ets = mapM actuals ~f:(fun i -> get_ident_et senv i) in
        pure @@ EOp (BuiltinOp b, EComposeSequence arg_ets)
    | Message bs ->
        (* Get the "real"/full expression type *)
        let get_payload_et pld =
          match pld with
          | MLit l -> pure @@ et_literal l
          | MVar i -> get_ident_et senv i
        in
        let _, plds = List.split bs in
        let%bind pld_ets = mapM ~f:get_payload_et plds in
        (* Don't really care about linearity for msgs, but Par fits better than Seq *)
        let full_et = EComposeParallel (et_nothing, pld_ets) in
        (* Get the "special", _recipient and _amount, expression type *)
        (* High-level idea: encode in the expr_type of messages who they are
            sent to and whether money is sent or not *)
        let get_special_payload_et (label, pld) =
          if String.compare label MP.amount_label = 0 then
            (* Sent amount must be zero for the message send to be shardable *)
            match pld with
            | MLit l ->
                if Integer_Addition_PCM.is_unit_literal (Literal l) then
                  pure @@ et_nothing
                else pure @@ et_sends_money
            | MVar i ->
                if Integer_Addition_PCM.is_unit senv (Var i) then
                  pure @@ et_nothing
                else pure @@ et_sends_money
          else if String.compare label MP.recipient_label = 0 then
            (* We report back what idents flow into _recipient, and the
               blockchain code can decide whether they are contract or
               non-contract addresses *)
            match pld with
            | MLit l -> pure @@ et_literal l
            | MVar i -> get_ident_et senv i
          else get_payload_et pld
        in
        (* For "special" et, we only care about _recipient and _amount labels *)
        let special_labels = [ MP.recipient_label; MP.amount_label ] in
        let special_plds =
          List.filter (fun (label, _) -> List.mem label special_labels) bs
        in
        let%bind special_pld_ets =
          if List.length special_plds = 0 then pure @@ [ et_nothing ]
          else mapM ~f:get_special_payload_et special_plds
        in
        let special_et = EComposeParallel (et_nothing, special_pld_ets) in
        pure @@ ECompositeVal (full_et, special_et)
    | Constr (_, _, actuals) ->
        let%bind arg_ets = mapM actuals ~f:(fun i -> get_ident_et senv i) in
        pure @@ EComposeSequence arg_ets
    | Let (i, _, lhs, rhs) ->
        let%bind lhs_et = cont senv lhs in
        let%bind lhs_et = et_normalise lhs_et in
        let senv' = env_new_ident i lhs_et senv in
        cont senv' rhs
    (* Our expr_types do not depend on Scilla types; just analyse as if
       monomorphic *)
    | TFun (_, body) -> cont senv body
    | TApp (tf, _) -> get_ident_et senv tf
    (* The cases below are the interesting ones *)
    | Fun (formal, ftyp, body) ->
        (* Formal parameters are given a linear contribution when producing
           function summaries. Arguments (see App) might be nonlinear. If the
           parameter is a function, we make it EFun = Unknown *)
        let fp_et = get_fp_et fp_count ftyp in
        let senv' = env_new_ident formal fp_et senv in
        let%bind body_et = sa_expr senv' (fp_count + 1) body in
        pure @@ EFun (EFunDef ([ fp_count ], DefExpr body_et))
    | App (f, actuals) ->
        (* This is here so we can make up an unknown function if required *)
        let num_args = List.length actuals in
        let%bind eapp_ref =
          get_eapp_referent senv f num_args (ER.get_loc rep)
        in
        let%bind arg_ets = mapM actuals ~f:(fun i -> get_ident_et senv i) in
        pure @@ EApp (eapp_ref, arg_ets)
    | MatchExpr (x, clauses) ->
        let%bind xc = get_ident_et senv x in
        let clause_et (pattern, cl_expr) =
          let binders = get_pattern_bounds pattern in
          let senv' =
            List.fold_left
              (* Each binder in the pattern gets the full contributions of x *)
                (fun env_acc id -> env_new_ident id xc env_acc)
              senv binders
          in
          cont senv' cl_expr
        in
        let%bind cl_ets = mapM ~f:clause_et clauses in
        let spurious = is_spurious_conditional_expr senv x clauses in
        (* Convention: et_nothing if spurious *)
        let cond = if spurious then et_nothing else EOp (Conditional, xc) in
        pure @@ EComposeParallel (cond, cl_ets)
    | Fixpoint (_, _, _) ->
        fail0 "Sharding analysis: somehow encountered a fixpoint??"

  let sa_expr_wrapper senv erep = sa_expr senv 0 erep

  let read_after_write summary read =
    let opt_keys_eq oa ob =
      match (oa, ob) with
      | None, None -> true
      | Some la, Some lb ->
          List.length la = List.length lb
          && List.for_all2 (fun a b -> get_id a = get_id b) la lb
      | _ -> false
    in
    match read with
    | Read (rf, rkeys) ->
        ComponentSummary.exists
          (fun op ->
            match op with
            | Write ((wf, wkeys), _) ->
                get_id rf = get_id wf && opt_keys_eq rkeys wkeys
            | _ -> false)
          summary
    | _ -> false

  (* Precondition: senv contains the component parameters, appropriately marked *)
  let rec sa_stmt senv summary (stmts : stmt_annot list) ct =
    (* Helpers to continue after
       accumulating an operation *)
    let cont senv summary sts = sa_stmt senv summary sts ct in
    (* Perform an operation *)
    let cont_op op summary sts =
      let summary' = ComponentSummary.add op summary in
      cont senv summary' sts
    in
    (* Introduce a new identifier *)
    let cont_ident ident contrib summary sts =
      let senv' = env_new_ident ident contrib senv in
      cont senv' summary sts
    in
    (* Perform an operation and introduce an identifier *)
    let cont_ident_op ident contrib op summary sts =
      let senv' = env_new_ident ident contrib senv in
      let summary' = ComponentSummary.add op summary in
      cont senv' summary' sts
    in
    match stmts with
    | [] -> pure summary
    | (s, _) :: sts -> (
        match s with
        (* Reads and Writes *)
        | Load (x, f) ->
            (* If the value we're reading is not fresh, mark this Load as exclusive *)
            let et, op =
              if read_after_write summary (Read (f, None)) then
                ( EUnknown,
                  AlwaysExclusive
                    ( Some (ER.get_loc (get_rep x)),
                      pp_operation (Read (f, None))
                      ^ " comes after write to same location." ) )
              else (EVal (et_pseudofield (f, None)), Read (f, None))
            in
            cont_ident_op x et op summary sts
        | Store (f, i) ->
            let%bind ic = get_ident_et senv i in
            cont_op (Write ((f, None), ic)) summary sts
        | MapGet (x, m, klist, _) ->
            let et, op =
              if map_access_can_be_summarised senv m klist then
                if read_after_write summary (Read (m, Some klist)) then
                  ( EUnknown,
                    AlwaysExclusive
                      ( Some (ER.get_loc (get_rep x)),
                        pp_operation (Read (m, Some klist))
                        ^ " comes after write to same location." ) )
                else
                  (EVal (et_pseudofield (m, Some klist)), Read (m, Some klist))
              else
                ( EVal (et_pseudofield (m, Some klist)),
                  AlwaysExclusive
                    ( Some (ER.get_loc (get_rep m)),
                      pp_operation (Read (m, Some klist))
                      ^ " cannot be summarised." ) )
            in
            cont_ident_op x et op summary sts
        | MapUpdate (m, klist, opt_i) ->
            let%bind ic =
              match opt_i with
              | Some i -> get_ident_et senv i
              | None -> pure @@ et_nothing
            in
            let op =
              if map_access_can_be_summarised senv m klist then
                Write ((m, Some klist), ic)
              else
                AlwaysExclusive
                  ( Some (ER.get_loc (get_rep m)),
                    pp_operation (Write ((m, Some klist), ic)) )
            in
            cont_op op summary sts
        (* Accept, Send, Event, ReadFromBC *)
        | AcceptPayment -> cont_op AcceptMoney summary sts
        | SendMsgs i ->
            let%bind deps = get_ident_et senv i in
            cont_op (SendMessages deps) summary sts
        | CreateEvnt i ->
            let%bind deps = get_ident_et senv i in
            cont_op (EmitEvent deps) summary sts
        (* TODO: Do we want to track blockchain reads? *)
        | ReadFromBC (x, _) -> cont_ident x et_nothing summary sts
        (* Plugging into the expression language *)
        | Bind (x, expr) ->
            let%bind expr_contrib = sa_expr_wrapper senv expr in
            let%bind expr_contrib = et_normalise expr_contrib in
            cont_ident x expr_contrib summary sts
        | MatchStmt (x, clauses) ->
            let%bind xc = get_ident_et senv x in
            let summarise_clause (pattern, cl_sts) =
              let binders = get_pattern_bounds pattern in
              let senv' =
                List.fold_left
                  (* Each binder in the pattern gets the full contributions of x *)
                    (fun env_acc id -> env_new_ident id xc env_acc)
                  senv binders
              in
              cont senv' summary cl_sts
            in
            let spurious = is_spurious_conditional_stmt xc x clauses in
            let%bind summary' =
              if spurious then
                (* Only the Some branch "really" contributes if spurious *)
                let%bind some_summary =
                  mapM ~f:summarise_clause
                    (List.filter
                       (fun (p, _) -> List.length (get_pattern_bounds p) = 1)
                       clauses)
                in
                foldM
                  ~f:(fun acc_summ cl_summ ->
                    pure @@ ComponentSummary.union acc_summ cl_summ)
                  ~init:summary some_summary
              else
                (* If not spurious, more things happen *)
                let%bind cond = et_normalise @@ EOp (Conditional, xc) in
                let cond_op =
                  if et_can_be_summarised senv cond then ConditionOn cond
                  else
                    AlwaysExclusive
                      ( Some (ER.get_loc (get_rep x)),
                        pp_operation (ConditionOn cond) )
                in
                let summary_with_conds = ComponentSummary.add cond_op summary in
                let%bind cl_summaries = mapM ~f:summarise_clause clauses in
                (* TODO: least upper bound? *)
                foldM
                  ~f:(fun acc_summ cl_summ ->
                    pure @@ ComponentSummary.union acc_summ cl_summ)
                  ~init:summary_with_conds cl_summaries
            in
            cont senv summary' sts
        | CallProc (p, arglist) -> (
            let%bind arg_ets = mapM arglist ~f:(fun i -> get_ident_et senv i) in
            let opt_proc_sig = SAEnv.lookupS senv (get_id p) in
            match opt_proc_sig with
            | Some proc_sig ->
                let%bind call_summ =
                  procedure_call_summary senv p proc_sig arglist arg_ets
                in
                let summary' = ComponentSummary.union summary call_summ in
                cont senv summary' sts
            (* If this occurs, it's a bug. Type checking should prevent it. *)
            | _ ->
                fail1
                  "Sharding analysis: calling procedure that was not analysed"
                  (SR.get_loc (get_rep p)) )
        | Iterate (l, _) ->
            let op =
              AlwaysExclusive (Some (ER.get_loc (get_rep l)), "Iterate")
            in
            cont_op op summary sts
        | Throw _ ->
            (* Throwing cancels all effects. All effects happening is a correct
               over-approximation. *)
            cont senv summary sts )

  let sa_component_summary senv (comp : component) =
    let all_params = SCU.append_implict_comp_params comp.comp_params in
    (* Add component parameters to the analysis environment *)
    let senv' =
      (* Give proper type to procedure functions *)
      env_bind_ident_map senv all_params (fun idx _ t ->
          (* Transition parameters are constants. Procedure parameters are not
             necessarily, i.e. reads can flow into them. *)
          let et =
            match comp.comp_type with
            (* TODO: might want not to track this for transitions, since
               parameters are constants *)
            | CompTrans -> get_pp_et idx t
            | CompProc -> get_pp_et idx t
          in
          IdentSig (ComponentParameter, PCMStatus.empty, et))
    in
    sa_stmt senv' ComponentSummary.empty comp.comp_body comp.comp_type

  let sa_analyze_folds senv =
    let folds =
      [ "nat_fold"; "nat_foldk"; "list_foldl"; "list_foldr"; "list_foldk" ]
    in
    (* Example: "('T -> Nat -> 'T) -> 'T -> Nat -> 'T" *)
    let fold_et = create_unknown_fun ~num_arrows:3 in
    List.fold_left
      (fun senv s ->
        SAEnv.addS senv s (IdentSig (DoesNotShadow, PCMStatus.empty, fold_et)))
      senv folds

  let sa_libentries senv (lel : lib_entry list) =
    foldM
      ~f:(fun senv le ->
        match le with
        | LibVar (lname, _, lexp) ->
            let%bind esig = sa_expr_wrapper senv lexp in
            let%bind esig = et_normalise esig in
            let e, _ = lexp in
            let pcms = pcm_unit senv e in
            pure
            @@ SAEnv.addS senv (get_id lname)
                 (IdentSig (DoesNotShadow, pcms, esig))
        | LibTyp _ -> pure senv)
      ~init:senv lel

  let base_constraints_for (meta : component * ComponentSummary.t) =
    let comp, comp_summ = meta in

    (* If there is an AlwaysExclusive operation, no way to shard this transition *)
    let exists_exclusive =
      ComponentSummary.exists
        (fun op -> match op with AlwaysExclusive _ -> true | _ -> false)
        comp_summ
    in
    (* If an unknown message is sent, no way to shard this transition  *)
    let sends_unknown_message =
      ComponentSummary.exists
        (fun op ->
          match op with
          | SendMessages et -> (
              match et with ECompositeVal (_, EVal _) -> false | _ -> true )
          | _ -> false)
        comp_summ
    in
    (* If a message is sent to an address that is not a transition parameter, we
       _choose_ not to shard this transition. We could conceivably do it for
       contract parameters and constants. *)
    let sends_non_parameter_addr =
      ComponentSummary.exists
        (fun op ->
          match op with
          | SendMessages et -> (
              match et with
              | ECompositeVal (_, EVal (_, contr)) ->
                  Contrib.for_all
                    (fun cs _ ->
                      match cs with ProcParameter _ -> false | _ -> true)
                    contr
              | _ -> false )
          | _ -> false)
        comp_summ
    in
    if exists_exclusive || sends_unknown_message || sends_non_parameter_addr
    then pure @@ ShardingSummary.singleton CUnsat
    else
      let ss = ShardingSummary.empty in
      (* Accepting money *)
      let may_accept_money =
        ComponentSummary.exists
          (fun op -> match op with AcceptMoney -> true | _ -> false)
          comp_summ
      in
      (* If you accept money, the transaction must be processed in the sender's
         shard to prevent double-spends *)
      let ss =
        if may_accept_money then ShardingSummary.add CSenderShard ss else ss
      in
      (* Sending messages *)
      let sent_messages =
        ComponentSummary.filter
          (fun op -> match op with SendMessages _ -> true | _ -> false)
          comp_summ
      in
      (* see comment on et_send_money *)
      let may_send_money =
        ComponentSummary.exists
          (fun op ->
            match op with
            | SendMessages et -> (
                match et with EVal (ps, _) -> ps = SubsetOf | _ -> false )
            | _ -> false)
          sent_messages
      in
      (* If you send money, you must own _balance to prevent double-spends *)
      let ss =
        if may_send_money then ShardingSummary.add CContractShard ss else ss
      in
      (* If you send messages, the recipients must be non-contracts *)
      let%bind ras =
        mapM ~f:(fun op ->
            match op with
            | SendMessages et -> proc_args_in_et comp et
            | _ -> pure @@ [])
        @@ ComponentSummary.elements sent_messages
      in
      let recipient_addresses = List.flatten ras in
      let ss =
        List.fold_left
          (fun acc addr -> ShardingSummary.add (CMustBeUserAddr addr) acc)
          ss recipient_addresses
      in
      (* Prevent duplicates for parameters used as keys for the same field and
         at the same map-level. *)
      let dangerous_keys = get_dangerous_alias_keys comp_summ in
      let ss =
        if List.length dangerous_keys > 0 then
          ShardingSummary.add (CMustNotHaveDuplicates dangerous_keys) ss
        else ss
      in
      pure @@ ss

  let exists_unsat ss =
    ShardingSummary.exists
      (fun c -> match c with CUnsat -> true | _ -> false)
      ss

  (* TODO: make this more type safe *)
  let compose_sd_identifier base extra = base ^ "+" ^ extra

  (* TODO: make this more type safe *)
  let is_pcm_compatible this with_this =
    List.mem this (String.split_on_char '+' with_this)

  let get_reads comp_summ =
    let ops = ComponentSummary.elements comp_summ in
    let reads =
      List.flatten
      @@ List.map (fun op -> match op with Read pf -> [ pf ] | _ -> []) ops
    in
    reads

  (* Given a component summary and a list of contract fields held constant,
     return the commutative writes and spurious reads within the component *)
  let comm_writes_spurious_reads comp_summ constant_fields =
    (* Step 1: detect commutative writes (CWs) *)
    let comm_writes =
      ComponentSummary.filter
        (fun op -> fst @@ is_comm_write op constant_fields)
        comp_summ
    in
    (* Step 2: Detect corresponding spurious reads *)
    (* A read is spurious if it is from a constant field or if it only flows
       into a commutative write into the same field (or in nothing) *)
    let spurious_reads =
      ComponentSummary.filter
        (fun op -> is_spurious_read op comp_summ comm_writes constant_fields)
        comp_summ
    in
    (comm_writes, spurious_reads)

  let get_local_pcm_info comp_summ comm_writes spurious_reads constant_fields =
    let%bind cw_pcms =
      mapM ~f:(fun op ->
          match (op, is_comm_write op constant_fields) with
          | Write ((m, _), _), (_, Some pcm) -> pure @@ (m, pcm)
          | _ -> fail0 "Sharding analysis: PCM detection bug")
      @@ ComponentSummary.elements comm_writes
    in
    let%bind sr_pseudofields =
      mapM ~f:(fun op ->
          match op with
          | Read pf -> pure @@ pf
          | _ -> fail0 "Sharding analysis: PCM detection bug")
      @@ ComponentSummary.elements spurious_reads
    in
    let nc_wr =
      ComponentSummary.filter
        (fun op ->
          match op with
          | Write _ -> not @@ ComponentSummary.mem op comm_writes
          | _ -> false)
        comp_summ
    in
    let%bind noncomm_writes =
      mapM ~f:(fun op ->
          match op with
          | Write ((m, _), _) -> pure @@ m
          | _ -> fail0 "Sharding analysis : noncomm_writes bug")
      @@ ComponentSummary.elements nc_wr
    in

    pure @@ (noncomm_writes, cw_pcms, sr_pseudofields)

  let list_distribute (l : 'a * 'b list) =
    let a, bs = l in
    List.map (fun b -> (a, b)) bs

  let list_split3 (l : ('a * 'b * 'c) list) =
    let a, b = List.split @@ List.map (fun (a, b, _) -> (a, b)) l in
    let c = List.map (fun (_, _, c) -> c) l in
    (a, b, c)

  let allocate_field_pcms local_pcms =
    (* Detect any (field, PCM) global inconsistencies *)
    let pcms =
      List.sort_uniq
        (fun (ida, pcma) (idb, pcmb) ->
          let ic = compare_id ida idb in
          let pc = String.compare pcma pcmb in
          if ic = 0 then pc else ic)
        (List.flatten local_pcms)
    in
    let fields, _ = List.split @@ pcms in
    (* TODO: if there are multiple valid choices, we don't want to give up *)
    let no_duplicates = List.compare_lengths pcms fields = 0 in
    if no_duplicates then Some pcms else None

  let validate_transitions input all =
    List.filter (fun t -> List.mem t input) all

  (* This function collates the possible PCMs from each transition
     and makes a global PCM allocation decision informed by user input,
     i.e. for each contract field it decides which PCM to assign out of
     the (many) possibilities. If user input leads to incosistencies,
     the chosen PCM is state_split for ALL contract fields. *)
  let assign_field_pcms cmod selected_transitions accepted_weak_reads
      constant_fields selected_info =
    let selected_comp_summ = List.map (fun (summ, _) -> summ) selected_info in
    let selected_shard_constr =
      List.map (fun (_, (_, sh)) -> sh) selected_info
    in
    (* Identify, for each transition separately, valid PCM for commutative
       writes and spurious reads. *)
    let%bind local_pcmsr =
      mapM
        ~f:(fun (summ, ((cw, sr), _)) ->
          get_local_pcm_info summ cw sr constant_fields)
        selected_info
    in
    let local_nc_wr, local_pcms, local_srs = list_split3 local_pcmsr in
    (* Globally allocate PCMs to fields; give up if inconsistencies exist *)
    let pcms = allocate_field_pcms local_pcms in
    let default_assignment =
      List.map
        (fun (f, t, _) -> (get_id f, (State_Split_PCM.pcm_identifier, t)))
        cmod.contr.cfields
    in
    let assigned_field_pcms =
      match pcms with
      | Some pcms -> (
          (* Helper functions *)
          let flatten_reads (rs : pseudofield list list) =
            List.flatten @@ List.map list_distribute
            @@ List.combine selected_transitions rs
          in
          let is_mem_read (t, pf) rs =
            List.exists
              (fun (t', pf') ->
                String.compare t t' = 0 && pp_compare pf pf' = 0)
              rs
          in
          (* Detect any non-spurious read that must be accepted as weak and isn't *)
          let spurious_reads = flatten_reads local_srs in
          Printf.eprintf "%s\n" @@ "Spurious reads: "
          ^ String.concat ", "
              (List.map
                 (fun (t, pf) -> t ^ ": " ^ pp_pseudofield pf)
                 spurious_reads);
          let commutative_writes = List.map fst pcms in
          let noncomm_writes =
            List.sort_uniq compare_id @@ List.flatten local_nc_wr
          in
          let reads = flatten_reads @@ List.map get_reads selected_comp_summ in
          let maybe_shardable =
            let trs = List.combine selected_transitions selected_shard_constr in
            let may_shard =
              List.filter
                (fun (_, sc) -> not @@ ShardingSummary.mem CUnsat sc)
                trs
            in
            List.map fst may_shard
          in
          (* Must accept non-spurious reads that are commutatively written to,
             if those reads appear in a potentially shardable transition *)
          let must_accept_weak =
            List.filter
              (fun (t, pf) ->
                let f, _ = pf in
                List.mem t maybe_shardable
                && is_mem_id f commutative_writes
                && (not @@ is_mem_read (t, pf) spurious_reads))
              reads
          in
          Printf.eprintf "%s\n" @@ "Must accept weak reads: "
          ^ String.concat ", "
              (List.map
                 (fun (t, pf) -> t ^ ": " ^ pp_pseudofield pf)
                 must_accept_weak);
          Printf.eprintf "%s\n" @@ "Accepted weak reads: "
          ^ String.concat ", "
              (List.map
                 (fun (t, pf) -> t ^ ": " ^ pp_pseudofield pf)
                 accepted_weak_reads);
          let all_weak_reads_accepted =
            let wr_compare (ta, pfa) (tb, pfb) =
              let tc = String.compare ta tb in
              let pfc = pp_compare pfa pfb in
              if tc = 0 then pfc else tc
            in
            let sort_wr wr = List.sort_uniq wr_compare wr in
            let must_accept = sort_wr must_accept_weak in
            let accepted = sort_wr accepted_weak_reads in
            if List.compare_lengths must_accept accepted <> 0 then false
            else
              let combined = List.combine must_accept accepted in
              List.for_all (fun (a, b) -> wr_compare a b = 0) combined
          in
          Printf.eprintf "%s\n" @@ "All weak reads accepted: "
          ^ string_of_bool all_weak_reads_accepted;
          let pcm_strs = List.map (fun (f, p) -> (get_id f, p)) pcms in
          match all_weak_reads_accepted with
          | true ->
              (* Assign PCMs to all fields *)
              let assignment =
                List.map
                  (fun (f, t, _) ->
                    (* the same field can be written to both commutatively and non-commutatively *)
                    let has_cw = is_mem_id f commutative_writes in
                    let has_non_cw = is_mem_id f noncomm_writes in
                    let pcm =
                      match (has_non_cw, has_cw) with
                      | _, false -> State_Split_PCM.pcm_identifier
                      | false, true -> List.assoc (get_id f) pcm_strs
                      | true, true ->
                          let cw_pcm = List.assoc (get_id f) pcm_strs in
                          compose_sd_identifier State_Split_PCM.pcm_identifier
                            cw_pcm
                    in
                    (get_id f, (pcm, t)))
                  cmod.contr.cfields
              in
              Printf.eprintf "%s\n" @@ "Global PCM assignment: "
              ^ String.concat ", "
                  (List.map (fun (f, (pcm, _)) -> f ^ ": " ^ pcm) assignment);
              assignment
          (* Revert to always-OK state splitting strategy if fancier strategies don't pan out *)
          | false -> default_assignment )
      | None -> default_assignment
    in
    pure @@ assigned_field_pcms

  (*  *)
  let get_transition_state_constraints comp_summ local_cws srs sh_constr
      field_pcms constant_fields =
    (* Filter out accesses due to spurious reads or commutative writes under the
       global PCM *)
    let access_ops =
      ComponentSummary.filter
        (fun op ->
          match op with
          (* Non-spurious reads are exclusive accesses *)
          | Read _ -> not @@ ComponentSummary.mem op srs
          (* Non-commutative writes are exclusive accesses *)
          | Write ((f, _), _) -> (
              if not (ComponentSummary.mem op local_cws) then true
              else
                (* This is a comutative write; we need to ensure it's under the global PCM *)
                match is_comm_write op constant_fields with
                | true, Some local_pcm ->
                    let global_pcm = fst @@ List.assoc (get_id f) field_pcms in
                    (* It's an exclusive access if it's not compatible with the global PCM *)
                    not @@ is_pcm_compatible local_pcm global_pcm
                (* If somehow this isn't commutative, there's a bug somewhere *)
                | _ -> assert false )
          | _ -> false)
        comp_summ
    in
    let state_accessed =
      List.flatten
      @@ List.map (fun op ->
             match op with
             | Read pf -> [ pf ]
             | Write (pf, _) -> [ pf ]
             | _ -> [])
      @@ ComponentSummary.elements access_ops
    in
    List.fold_left
      (fun acc pf -> ShardingSummary.add (CAccess pf) acc)
      sh_constr state_accessed

  let get_sharding_info ?(selected_transitions : string list = [])
      ?(accepted_weak_reads : (string * pseudofield) list = []) cmod summaries =
    let all_transitions =
      List.map (fun (comp, _, _) -> get_id comp.comp_name) summaries
    in
    let selected_transitions =
      (* If user is not selective, try to shard all transitions *)
      if selected_transitions = [] then all_transitions
        (* Important: selected_transitions must actually exist in contract AND
           appear in the order they are defined in contract. *)
      else validate_transitions selected_transitions all_transitions
    in
    Printf.eprintf "%s\n" @@ "Selected transitions: "
    ^ String.concat ", " selected_transitions;
    let selected_summaries =
      List.filter
        (fun (comp, _, _) ->
          List.mem (get_id comp.comp_name) selected_transitions)
        summaries
    in
    let selected_comp_summ =
      List.map (fun (_, summ, _) -> summ) selected_summaries
    in
    let selected_shard_constr =
      List.map (fun (_, _, constr) -> constr) selected_summaries
    in
    (* Determine which fields are constant in the shard phase *)
    let contract_fields = List.map (fun (x, _, _) -> x) cmod.contr.cfields in
    (* A field is constant if it isn't written to *)
    let field_is_constant f =
      List.for_all
        (fun summ ->
          not
          @@ ComponentSummary.exists
               (fun op ->
                 match op with
                 | Write ((wf, _), _) -> get_id f = get_id wf
                 | _ -> false)
               summ)
        selected_comp_summ
    in
    let constant_fields =
      List.filter (fun f -> field_is_constant f) contract_fields
    in
    Printf.eprintf "%s\n" @@ "Constant fields: "
    ^ String.concat ", " (List.map get_id constant_fields);
    (* Locally compute CWs and SRs for each selected transition *)
    let selected_cw, selected_sr =
      List.split
      @@ List.map
           (fun s -> comm_writes_spurious_reads s constant_fields)
           selected_comp_summ
    in
    let selected_info =
      List.combine selected_comp_summ
        (List.combine
           (List.combine selected_cw selected_sr)
           selected_shard_constr)
    in
    (* Consolidate the PCMs globally and assign a global PCM per field *)
    let%bind field_pcms =
      assign_field_pcms cmod selected_transitions accepted_weak_reads
        constant_fields selected_info
    in
    (* Given global PCM allocation, determine constraints for each selected transition *)
    let constraints =
      (* Need to own anything that's not a spurious read OR a commutative write
         _for the global PCM_. *)
      List.map
        (fun (summ, ((cws, srs), sh)) ->
          get_transition_state_constraints summ cws srs sh field_pcms
            constant_fields)
        selected_info
    in
    (* If there's CUnsat in any constraint, just replace the whole thing with CUnsat *)
    let constraints =
      List.map
        (fun sh ->
          if ShardingSummary.mem CUnsat sh then ShardingSummary.singleton CUnsat
          else sh)
        constraints
    in
    let sharding_constraints = List.combine selected_transitions constraints in
    Printf.eprintf "\n%s\n"
    @@ String.concat "\n"
         (List.map
            (fun (t, sc) -> t ^ ": \n" ^ pp_sharding sc)
            sharding_constraints);
    pure @@ (sharding_constraints, field_pcms)

  module StringSet = Set.Make (String)

  let good_enough sharding_constraints =
    let k = List.length sharding_constraints in
    let is_sat ss = not @@ ShardingSummary.mem CUnsat ss in
    let hogged_fields ss =
      ShardingSummary.filter
        (fun sc -> match sc with CAccess (_, None) -> true | _ -> false)
        ss
    in
    if k = 1 then
      let ss = snd @@ List.hd sharding_constraints in
      is_sat ss && ShardingSummary.cardinal (hogged_fields ss) = 0
    else
      let hfs =
        List.map (fun (_, ss) -> hogged_fields ss) sharding_constraints
      in
      let num_hogged =
        List.fold_left ( + ) 0 (List.map ShardingSummary.cardinal hfs)
      in
      let union_hfs =
        List.fold_left ShardingSummary.union ShardingSummary.empty hfs
      in
      let all_sat =
        List.for_all (fun (_, ss) -> is_sat ss) sharding_constraints
      in
      let have_conflicting_access =
        ShardingSummary.cardinal union_hfs < num_hogged
      in
      all_sat && not have_conflicting_access

  let gen_goodenough_table ?(accepted_weak_reads = []) cmod summaries =
    let all_transitions =
      List.map (fun (comp, _, _) -> get_id comp.comp_name) summaries
    in
    let max_k = List.length all_transitions + 1 in
    let subsets xs =
      List.filter (fun ys ->
          List.compare_length_with ys 0 <> 0
          && List.compare_length_with ys max_k <> 1)
      @@ List.fold_right
           (fun x rest -> rest @ List.map (fun ys -> x :: ys) rest)
           xs [ [] ]
    in
    let filter_proper_subsets xs =
      let xs = List.map StringSet.of_list xs in
      let is_maximal x =
        not
        @@ List.exists (fun y -> compare x y <> 0 && StringSet.subset x y) xs
      in
      List.map StringSet.elements @@ List.filter is_maximal xs
    in

    let possible_selections = subsets all_transitions in
    let get_sc sel =
      match
        get_sharding_info ~selected_transitions:sel ~accepted_weak_reads cmod
          summaries
      with
      | Ok (sc, _) -> sc
    in
    let good_enough_selections =
      List.filter (fun sel -> good_enough @@ get_sc sel) possible_selections
    in
    let counts =
      let c l =
        List.length
        @@ List.filter
             (fun xs -> List.compare_length_with xs l = 0)
             good_enough_selections
      in
      let lengths = int_range 1 max_k in
      List.map c lengths
    in
    let maximal_selections = filter_proper_subsets good_enough_selections in
    let max_ge_size =
      List.fold_left max 0 (List.map List.length maximal_selections)
    in
    let max_ge_num = List.length maximal_selections in
    let num_transitions = List.length all_transitions in
    let sharding_ratio =
      float_of_int max_ge_size /. float_of_int num_transitions
    in
    let csv = String.concat ", " (List.map string_of_int counts) in
    let maximal_str =
      String.concat " OR "
        (List.map (fun xs -> String.concat "; " xs) maximal_selections)
    in

    let str =
      Printf.sprintf "%d, %d, %.2f, %d, SEP, %s, SEP, %s\n" num_transitions
        max_ge_size sharding_ratio max_ge_num csv maximal_str
    in
    Printf.printf "[GoodEnough] %s" @@ str;
    str

  let sa_module selected_transitions weak_reads_str (cmod : cmodule)
      (elibs : libtree list) (gen_goodenough : bool) =
    let senv = SAEnv.mk () in

    let senv = sa_analyze_folds senv in

    (* Analyze external libraries  *)
    let%bind senv =
      let rec recurser libl =
        foldM
          ~f:(fun senv lib ->
            let%bind senv_deps = recurser lib.deps in
            let%bind senv_lib = sa_libentries senv_deps lib.libn.lentries in
            (* Retain only _this_ library's entries in env, not the deps' *)
            let senv_lib' =
              SAEnv.filterS senv_lib ~f:(fun name ->
                  List.exists
                    (function
                      | LibTyp _ -> false | LibVar (i, _, _) -> get_id i = name)
                    lib.libn.lentries)
            in
            pure @@ SAEnv.appendS senv senv_lib')
          ~init:senv libl
      in
      recurser elibs
    in

    (* Analyze contract libraries *)
    let%bind senv =
      match cmod.libs with
      | Some l -> sa_libentries senv l.lentries
      | None -> pure @@ senv
    in

    (* Bind contract parameters *)
    let senv =
      let all_params = SCU.append_implict_contract_params cmod.contr.cparams in
      env_bind_ident_map senv all_params (fun _ id _ ->
          IdentSig (DoesNotShadow, PCMStatus.empty, et_contract_param id))
    in

    (* This is a combined map and fold: fold for senv', map for summaries *)
    let%bind _, summaries =
      foldM
        ~f:(fun (senv_acc, summ_acc) comp ->
          let%bind comp_summ = sa_component_summary senv_acc comp in
          let senv' =
            env_bind_component senv_acc comp
              (ComponentSig (comp.comp_params, comp_summ))
          in
          (* We only want transitions in the output *)
          let%bind summaries =
            if comp.comp_type = CompTrans then
              let%bind const = base_constraints_for (comp, comp_summ) in
              pure @@ ((comp, comp_summ, const) :: summ_acc)
            else pure @@ summ_acc
          in
          pure @@ (senv', summaries))
        ~init:(senv, []) cmod.contr.ccomps
    in

    let summaries = List.rev summaries in
    (* SECURITY / UNTRUSTED INPUT: validate command line arguments *)
    (* Important: selected_transitions must actually exist in contract AND
       appear in the order they are defined in contract *)
    let all_transitions =
      List.map (fun (comp, _, _) -> get_id comp.comp_name) summaries
    in
    let selected_transitions =
      validate_transitions selected_transitions all_transitions
    in
    let%bind accepted_weak_reads = mapM ~f:weak_read_of_str weak_reads_str in
    let%bind sharding_constraints, field_pcms =
      get_sharding_info ~selected_transitions ~accepted_weak_reads cmod
        summaries
    in
    let sharding_constraints =
      List.map
        (fun (t, ss) -> (t, ShardingSummary.elements ss))
        sharding_constraints
    in
    let benchmark_results =
      match gen_goodenough with
      | true -> Some (gen_goodenough_table ~accepted_weak_reads cmod summaries)
      | false -> None
    in
    (* pure summaries *)
    (* pure senv *)
    (* Printf.eprintf "%s\n" @@ SAEnv.pp senv; *)
    (* Printf.eprintf "%s\n"
       @@ String.concat "\n\n"
            (List.map
               (fun (c, x, _) -> get_id c.comp_name ^ ": \n" ^ pp_summary x)
               summaries); *)
    pure (sharding_constraints, field_pcms, benchmark_results)
end
