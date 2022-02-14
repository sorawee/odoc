(*
 * Copyright (c) 2014 Leo White <lpw25@cl.cam.ac.uk>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Odoc_model

module Paths = Odoc_model.Paths

let point_of_pos { Lexing.pos_lnum; pos_bol; pos_cnum; _ } =
  let column = pos_cnum - pos_bol in
  { Odoc_model.Location_.line = pos_lnum; column }

let read_location { Location.loc_start; loc_end; _ } =
  {
    Odoc_model.Location_.file = loc_start.pos_fname;
    start = point_of_pos loc_start;
    end_ = point_of_pos loc_end;
  }

let empty_body = []

let empty : Odoc_model.Comment.docs = empty_body

let load_payload = function
  | Parsetree.PStr [{pstr_desc =
      Pstr_eval ({pexp_desc =
#if OCAML_VERSION < (4,3,0)
        Pexp_constant (Const_string (text, _))
#elif OCAML_VERSION < (4,11,0)
        Pexp_constant (Pconst_string (text, _))
#else
        Pexp_constant (Pconst_string (text, _, _))
#endif
   ; pexp_loc = loc; _}, _); _}] ->
     Some (text, loc)
  | _ -> None

#if OCAML_VERSION >= (4,8,0)
let attribute_unpack = function
  | { Parsetree.attr_name = { Location.txt = name; _ }; attr_payload; attr_loc } ->
      (name, attr_payload, attr_loc)
#else
let attribute_unpack = function
  | { Location.txt = name; loc }, attr_payload -> (name, attr_payload, loc)
#endif

type payload = string * Location.t

let parse_attribute :
    Parsetree.attribute ->
    ([ `Text of payload | `Deprecated of payload option ] * Location.t) option =
 fun attr ->
  let name, attr_payload, attr_loc = attribute_unpack attr in
  match name with
  | "text" | "ocaml.text" -> (
      match load_payload attr_payload with
      | Some p -> Some (`Text p, attr_loc)
      | None -> assert false)
  | "deprecated" | "ocaml.deprecated" ->
      Some (`Deprecated (load_payload attr_payload), attr_loc)
  | _ -> None

let is_stop_comment attr =
  match parse_attribute attr with Some (`Text ("/*", _), _) -> true | _ -> false

let pad_loc loc =
  { loc.Location.loc_start with pos_cnum = loc.loc_start.pos_cnum + 3 }

let ast_to_comment ~internal_tags parent ast_docs alerts =
  Odoc_model.Semantics.ast_to_comment ~internal_tags ~sections_allowed:`All
    ~parent_of_sections:parent ast_docs alerts
  |> Error.raise_warnings

let parse_deprecated_payload ~loc p =
  let p = match p with Some (p, _) -> Some p | None -> None in
  let elt = `Tag (`Alert ("deprecated", p)) in
  let span = read_location loc in
  Location_.at span elt

let attached internal_tags parent attrs =
  let rec loop acc_docs acc_alerts = function
    | attr :: rest -> (
        let name, attr_payload, attr_loc = attribute_unpack attr in
        match (name, load_payload attr_payload) with
        | ("doc" | "ocaml.doc"), Some (str, loc) ->
            let ast_docs =
              Odoc_parser.parse_comment ~location:(pad_loc loc) ~text:str
              |> Error.raise_parser_warnings
            in
            loop (List.rev_append ast_docs acc_docs) acc_alerts rest
        | ("deprecated" | "ocaml.deprecated"), p ->
            let elt = parse_deprecated_payload ~loc:attr_loc p in
            loop acc_docs (elt :: acc_alerts) rest
        | _ -> loop acc_docs acc_alerts rest)
    | [] -> (List.rev acc_docs, List.rev acc_alerts)
  in
  let ast_docs, alerts = loop [] [] attrs in
  ast_to_comment ~internal_tags parent ast_docs alerts

let attached_no_tag parent attrs =
  let x, () = attached Semantics.Expect_none parent attrs in
  x

let read_string internal_tags parent location str =
  Odoc_model.Semantics.parse_comment
    ~internal_tags
    ~sections_allowed:`All
    ~containing_definition:parent
    ~location
    ~text:str
  |> Odoc_model.Error.raise_warnings

let read_string_comment internal_tags parent loc str =
  read_string internal_tags parent (pad_loc loc) str

let page parent loc str =
  let doc, () =
    read_string Odoc_model.Semantics.Expect_none parent loc.Location.loc_start
      str
  in
  `Docs doc

let standalone parent (attr : Parsetree.attribute) :
    Odoc_model.Comment.docs_or_stop option =
  match parse_attribute attr with
  | Some (`Text ("/*", _loc), _) -> Some `Stop
  | Some (`Text (str, loc), _) ->
      let doc, () = read_string_comment Semantics.Expect_none parent loc str in
      Some (`Docs doc)
  | Some (`Deprecated _, attr_loc) ->
      let w =
        Error.make "Deprecated attribute not expected here."
          (read_location attr_loc)
      in
      Error.raise_warning w;
      None
  | _ -> None

let standalone_multiple parent attrs =
  let coms =
    List.fold_left
      (fun acc attr ->
        match standalone parent attr  with
         | None -> acc
         | Some com -> com :: acc)
      [] attrs
  in
    List.rev coms

let split_docs docs =
  let rec inner first x =
    match x with
    | { Location_.value = `Heading _; _ } :: _ -> List.rev first, x
    | x :: y -> inner (x::first) y
    | [] -> List.rev first, []
  in
  inner [] docs

let extract_top_comment internal_tags ~classify parent items =
  let classify x =
    match classify x with
    | Some (`Attribute attr) -> (
        match parse_attribute attr with
        | Some ((`Text _ as p), _) -> p
        | Some (`Deprecated p, attr_loc) ->
            let p = match p with Some (p, _) -> Some p | None -> None in
            let attr_loc = read_location attr_loc in
            (`Alert (Location_.at attr_loc (`Tag (`Alert ("deprecated", p)))))
        | None -> `Skip)
    | Some `Open -> `Skip
    | None -> `Stop
  in
  let rec extract_tail_alerts acc = function
    (* Accumulate the alerts after the top-comment. Stop at the next comment. *)
    | hd :: tl as items -> (
        match classify hd with
        | `Text _ | `Stop -> (items, acc)
        | `Alert alert -> extract_tail_alerts (alert :: acc) tl
        | `Skip -> extract_tail_alerts acc tl)
    | [] -> ([], acc)
  and extract = function
    (* Extract the first comment and accumulate the alerts before and after
       it. *)
    | hd :: tl as items -> (
        match classify hd with
        | `Text (text, loc) ->
            let ast_docs =
              Odoc_parser.parse_comment ~location:(pad_loc loc) ~text
              |> Error.raise_parser_warnings
            in
            let items, alerts = extract_tail_alerts [] tl in
            (items, ast_docs, alerts)
        | `Alert alert ->
            let items, ast_docs, alerts = extract tl in
            (items, ast_docs, alert :: alerts)
        | `Skip ->
            let items, ast_docs, alerts = extract tl in
            (hd :: items, ast_docs, alerts)
        | `Stop -> (items, [], []))
    | [] -> ([], [], [])
  in
  let items, ast_docs, alerts = extract items in
  let docs, tags =
    ast_to_comment ~internal_tags
      (parent : Paths.Identifier.Signature.t :> Paths.Identifier.LabelParent.t)
      ast_docs alerts
  in
  (items, split_docs docs, tags)

let extract_top_comment_class items =
  match items with
  | Lang.ClassSignature.Comment (`Docs doc) :: tl -> (tl, split_docs doc)
  | _ -> items, (empty,empty)
