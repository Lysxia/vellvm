From Vellvm Require Import
     Numeric.Coqlib
     Numeric.Integers
     Numeric.Floats
     Utils.Tactics
     Utils.Util
     Utils.Error
     Utils.ListUtil
     Utils.NonEmpty
     Utils.NMaps
     Syntax.LLVMAst
     Syntax.DynamicTypes
     Syntax.DataLayout
     Semantics.DynamicValues
     Semantics.Denotation
     Semantics.MemoryAddress
     Semantics.Memory.Sizeof
     Semantics.LLVMEvents.

From ExtLib Require Import
     Core.RelDec
     Structures.Monads
     Data.Monads.EitherMonad.

Require Import Lia.


Import ListNotations.
Import MonadNotation.

(* TODO: move this? *)
Module Type PTOI(Addr:MemoryAddress.ADDRESS).  
  Parameter ptr_to_int : Addr.addr -> Z.
End PTOI.

(* TODO: move this? *)
Module Type PROVENANCE(Addr:MemoryAddress.ADDRESS).
  Parameter Prov : Set.
  Parameter wildcard_prov : Prov.
  Parameter nil_prov : Prov.
  Parameter address_provenance : Addr.addr -> Prov.
End PROVENANCE.

(* TODO: move this? *)
Module Type ITOP(Addr:MemoryAddress.ADDRESS)(PROV:PROVENANCE(Addr)).
  Parameter int_to_ptr : Z -> PROV.Prov -> Addr.addr.
End ITOP.

Module Make(Addr:MemoryAddress.ADDRESS)(LLVMIO: LLVM_INTERACTIONS(Addr))(SIZEOF: Sizeof)(PTOI:PTOI(Addr))(PROVENANCE:PROVENANCE(Addr))(ITOP:ITOP(Addr)(PROVENANCE)).

  Import LLVMIO.
  Import SIZEOF.
  Import PTOI.
  Import PROVENANCE.
  Import ITOP.
  Import DV.
  Open Scope list.

  Variable ptr_size : nat.
  Variable datalayout : DataLayout.

  Definition addr := Addr.addr.

  (* TODO: move this? *)
  Inductive SByte :=
  | UByte (uv : uvalue) (dt : dtyp) (idx : uvalue) (sid : store_id) : SByte.
  

  Definition endianess : Endianess
    := dl_endianess datalayout.

  (* Given a little endian list of bytes, match the endianess of `e` *)
  Definition correct_endianess {BYTES : Type} (e : Endianess) (bytes : list BYTES)
    := match e with
       | ENDIAN_BIG => rev bytes
       | ENDIAN_LITTLE => bytes
       end.

  (* Converts an integer [x] to its byte representation over [n] bytes.
     The representation is little endian. In particular, if [n] is too small,
     only the least significant bytes are returned.
   *)
  Fixpoint bytes_of_int_little_endian (n: nat) (x: Z) {struct n}: list byte :=
    match n with
    | O => nil
    | S m => Byte.repr x :: bytes_of_int_little_endian m (x / 256)
    end.

  Definition bytes_of_int (e : Endianess) (n : nat) (x : Z) : list byte :=
    correct_endianess e (bytes_of_int_little_endian n x).

  (*
  Definition sbytes_of_int (e : Endianess) (count:nat) (z:Z) : list SByte :=
    List.map Byte (bytes_of_int e count z). *)

    (** ** Size of a dynamic type
      Computes the byte size of a [dtyp]. *)
    Fixpoint sizeof_dtyp (ty:dtyp) : N :=
      match ty with
      | DTYPE_I 1          => 1 (* TODO: i1 sizes... *)
      | DTYPE_I 8          => 1
      | DTYPE_I 32         => 4
      | DTYPE_I 64         => 8
      | DTYPE_I _          => 0 (* Unsupported integers *)
      | DTYPE_IPTR         => N.of_nat ptr_size
      | DTYPE_Pointer      => N.of_nat ptr_size
      | DTYPE_Packed_struct l
      | DTYPE_Struct l     => fold_left (fun acc x => (acc + sizeof_dtyp x)%N) l 0%N
      | DTYPE_Vector sz ty'
      | DTYPE_Array sz ty' => sz * sizeof_dtyp ty'
      | DTYPE_Float        => 4
      | DTYPE_Double       => 8
      | DTYPE_Half         => 4
      | DTYPE_X86_fp80     => 10 (* TODO: Unsupported, currently modeled by Float32 *)
      | DTYPE_Fp128        => 16 (* TODO: Unsupported, currently modeled by Float32 *)
      | DTYPE_Ppc_fp128    => 16 (* TODO: Unsupported, currently modeled by Float32 *)
      | DTYPE_Metadata     => 0
      | DTYPE_X86_mmx      => 8 (* TODO: Unsupported *)
      | DTYPE_Opaque       => 0 (* TODO: Unsupported *)
      | _                  => 0 (* TODO: add support for more types as necessary *)
      end.

    Definition uvalue_bytes_little_endian (uv :  uvalue) (dt : dtyp) (sid : store_id) : list uvalue
      := map (fun n => UVALUE_ExtractByte uv dt (UVALUE_IPTR (Z.of_N n)) sid) (Nseq 0 ptr_size).
 
   Definition uvalue_bytes (e : Endianess) (uv :  uvalue) (dt : dtyp) (sid : store_id) : list uvalue
      := correct_endianess e (uvalue_bytes_little_endian uv dt sid).

    Definition to_ubytes (uv :  uvalue) (dt : dtyp) (sid : store_id) : list SByte
      := map (fun n => UByte uv dt (UVALUE_IPTR (Z.of_N n)) sid) (Nseq 0 (N.to_nat (sizeof_dtyp dt))).

    Definition ubyte_to_extractbyte (byte : SByte) : uvalue
      := match byte with
         | UByte uv dt idx sid => UVALUE_ExtractByte uv dt idx sid
         end.

    (* Is a uvalue a concrete integer equal to i? *)
    Definition uvalue_int_eq_Z (uv : uvalue) (i : Z)
      := match uv with
         | UVALUE_I1 x
         | UVALUE_I8 x
         | UVALUE_I32 x
         | UVALUE_I64 x => Z.eqb (unsigned x) i
         | UVALUE_IPTR x => Z.eqb x i
         | _ => false
         end.

    Definition dvalue_int_unsigned (dv : dvalue) : Z
      := match dv with
         | DVALUE_I1 x => unsigned x
         | DVALUE_I8 x => unsigned x
         | DVALUE_I32 x => unsigned x
         | DVALUE_I64 x => unsigned x
         | DVALUE_IPTR x => x (* TODO: unsigned???? *)
         | _ => 0
         end.

    Definition guard_opt (x : bool) : option unit
      := if x then Some tt else None.

    Fixpoint all_bytes_from_uvalue_helper (idx' : Z) (sid' : store_id) (parent : uvalue) (bytes : list SByte) : option uvalue
      := match bytes with
         | [] => Some parent
         | (UByte uv dt idx sid)::bytes =>
           guard_opt (uvalue_int_eq_Z idx idx');;
           guard_opt (RelDec.rel_dec uv parent);;
           guard_opt (N.eqb sid sid');;
           all_bytes_from_uvalue_helper (Z.succ idx') sid' parent bytes
         end.

    Definition all_bytes_from_uvalue (bytes : list SByte) : option uvalue
      := match bytes with
         | nil => None
         | cons (UByte uv dt idx sid) xs =>
           all_bytes_from_uvalue_helper 0 sid uv bytes
         end.

    (* TODO: move this *)
    Definition dtyp_eqb (dt1 dt2 : dtyp) : bool
      := match @dtyp_eq_dec dt1 dt2 with
         | left x => true
         | right x => false
         end.

    Fixpoint all_extract_bytes_from_uvalue_helper (idx' : Z) (sid' : store_id) (dt' : dtyp) (parent : uvalue) (bytes : list uvalue) : option uvalue
      := match bytes with
         | [] => Some parent
         | (UVALUE_ExtractByte uv dt idx sid)::bytes =>
           guard_opt (uvalue_int_eq_Z idx idx');;
           guard_opt (RelDec.rel_dec uv parent);;
           guard_opt (N.eqb sid sid');;
           guard_opt (dtyp_eqb dt dt');;
           all_extract_bytes_from_uvalue_helper (Z.succ idx') sid' dt' parent bytes
         | _ => None
         end.

    (* Check that store ids, uvalues, and types match up, as well as
       that the extract byte indices are in the right order *)
    Definition all_extract_bytes_from_uvalue (bytes : list uvalue) : option uvalue
      := match bytes with
         | nil => None
         | (UVALUE_ExtractByte uv dt idx sid)::xs =>
           all_extract_bytes_from_uvalue_helper 0 sid dt uv bytes
         | _ => None
         end.

    Definition from_ubytes (bytes : list SByte) (dt : dtyp) : uvalue
      :=
        match N.eqb (N.of_nat (length bytes)) (sizeof_dtyp dt), all_bytes_from_uvalue bytes with
        | true, Some uv => uv
        | _, _ => UVALUE_ConcatBytes (map ubyte_to_extractbyte bytes) dt
        end.

    (* TODO: move to utils? *)
    Definition from_option {A} (def : A) (opt : option A) : A
      := match opt with
         | Some x => x
         | None => def
         end.

    Definition fp_alignment (bits : N) : option Alignment :=
      let fp_map := dl_floating_point_alignments datalayout
      in NM.find bits fp_map.

    Definition option_pick_large {A} (leq : A -> A -> bool) (a b : option A) : option A
      := match a, b with
         | Some x, Some y =>
           if leq x y then b else a
         | Some a, _      => Some a
         | _, Some b      => Some b
         | None, None     => None
         end.

    Definition option_pick_small {A} (leq : A -> A -> bool) (a b : option A) : option A
      := match a, b with
         | Some x, Some y =>
           if leq x y then a else b
         | Some a, _      => Some a
         | _, Some b      => Some b
         | None, None     => None
         end.

    Definition maximumBy {A} (leq : A -> A -> bool) (def : A) (l : list A) : A :=
      fold_left (fun a b => if leq a b then b else a) l def.

    Definition maximumByOpt {A} (leq : A -> A -> bool) (l : list A) : option A :=
      fold_left (option_pick_large leq) (map Some l) None.

    Definition nextLargest {A} (leq : A -> A -> bool) (n : A) (def : A) (l : list A) : A :=
      fold_left (fun a b => if leq n a && leq a b then a else b) l def.

    Definition nextOrMaximum {A} (leq : A -> A -> bool) (n : A) (def : A) (l : list A) : A :=
      let max := maximumBy leq def l
      in fold_left (fun a b => if leq n b && leq a b then a else b) l max.

    Definition nextOrMaximumOpt {A} (leq : A -> A -> bool) (n : A) (l : list A) : option A :=
      let max := maximumByOpt leq l
      in fold_left (fun a b => if leq n b then option_pick_small leq a (Some b) else a) l max.

    Definition int_alignment (bits : N) : option Alignment :=
      let int_map := dl_integer_alignments datalayout
      in match NM.find bits int_map with
         | Some align => Some align
         | None =>
           let keys  := map fst (NM.elements int_map) in
           let bits' := nextOrMaximumOpt N.leb bits keys 
           in match bits' with
              | Some bits => NM.find bits int_map
              | None => None
              end
         end.

    (* TODO: Finish this function *)
    (* Fixpoint dtyp_alignment (dt : dtyp) : option Alignment := *)
    (*   match dt with *)
    (*   | DTYPE_I sz => *)
    (*     int_alignment sz *)
    (*   | DTYPE_IPTR => *)
    (*     (* TODO: should these have the same alignments as pointers? *) *)
    (*     int_alignment (N.of_nat ptr_size * 4)%N *)
    (*   | DTYPE_Pointer => *)
    (*     (* TODO: address spaces? *) *)
    (*     Some (ps_alignment (head (dl_pointer_alignments datalayout))) *)
    (*   | DTYPE_Void => *)
    (*     None *)
    (*   | DTYPE_Half => *)
    (*     fp_alignment 16 *)
    (*   | DTYPE_Float => *)
    (*     fp_alignment 32 *)
    (*   | DTYPE_Double => *)
    (*     fp_alignment 64 *)
    (*   | DTYPE_X86_fp80 => *)
    (*     fp_alignment 80 *)
    (*   | DTYPE_Fp128 => *)
    (*     fp_alignment 128 *)
    (*   | DTYPE_Ppc_fp128 => *)
    (*     fp_alignment 128 *)
    (*   | DTYPE_Metadata => *)
    (*     None *)
    (*   | DTYPE_X86_mmx => _ *)
    (*   | DTYPE_Array sz t => *)
    (*     dtyp_alignment t *)
    (*   | DTYPE_Struct fields => _ *)
    (*   | DTYPE_Packed_struct fields => _ *)
    (*   | DTYPE_Opaque => _ *)
    (*   | DTYPE_Vector sz t => _ *)
    (*   end. *)

    Definition dtyp_extract_fields (dt : dtyp) : err (list dtyp)
      := match dt with
         | DTYPE_Struct fields
         | DTYPE_Packed_struct fields =>
           ret fields
         | DTYPE_Array sz t
         | DTYPE_Vector sz t =>
           ret (repeat t (N.to_nat sz))
         | _ => inl "No fields."
         end.

    Definition extract_byte_to_ubyte (uv : uvalue) : err SByte
      := match uv with
         | UVALUE_ExtractByte uv dt idx sid =>
           ret (UByte uv dt idx sid)
         | _ => inl "extract_byte_to_ubyte invalid conversion."
         end.

    Import StateMonad.
    Definition ErrSID := eitherT string (state store_id).

    Definition lift_err {M A} `{MonadExc string M} `{Monad M} (e : err A) : (M A)
        := match e with
         | inl e => raise e
         | inr x => ret x
         end.

    Definition evalErrSID {A} (m : ErrSID A) (sid : store_id) : err A
      := evalState (unEitherT m) sid.

    Definition fresh_sid : ErrSID store_id
      := lift (modify N.succ).

    Definition sbyte_sid_match (a b : SByte) : bool
      := match a, b with
         | UByte uv dt idx sid, UByte uv' dt' idx' sid' =>
           N.eqb sid sid'
         end.

    Definition replace_sid (sid : store_id) (ub : SByte) : SByte
      := let '(UByte uv dt idx sid_old) := ub in
         UByte uv dt idx sid.

    Definition filter_sid_matches (byte : SByte) (sbytes : list (N * SByte)) : (list (N * SByte) * list (N * SByte))
      := filter_split (fun '(n, uv) => sbyte_sid_match byte uv) sbytes.

    (* TODO: move to some utility file? *)
    Fixpoint NM_find_many {A} (xs : list N) (nm : NMap A) : option (list A)
      := match xs with
         | [] => ret []
         | (x::xs) =>
           elt  <- NM.find x nm;;
           elts <- NM_find_many xs nm;;
           ret (elt :: elts)
         end.


    (* Assign fresh sids to ubytes while preserving entanglement *)
    Unset Guard Checking.
    Fixpoint re_sid_ubytes_helper (bytes : list (N * SByte)) (acc : NMap SByte) {struct bytes} : ErrSID (NMap SByte)
      := match bytes with
         | [] => ret acc
         | ((n, x)::xs) =>
           let '(UByte uv dt idx sid) := x in
           let '(ins, outs) := filter_sid_matches x xs in
           nsid <- fresh_sid;;
           let acc := @NM.add _ n (replace_sid nsid x) acc in
           (* Assign new sid to entangled bytes *)
           let acc := fold_left (fun acc '(n, ub) => @NM.add _ n (replace_sid nsid ub) acc) ins acc in
           re_sid_ubytes_helper outs acc
         end
    with
    re_sid_ubytes (bytes : list SByte) : ErrSID (list SByte)
      := let len := length bytes in
         byte_map <- re_sid_ubytes_helper (zip (Nseq 0 len) bytes) (@NM.empty _);;
         trywith "re_sid_ubytes: missing indices." (NM_find_many (Nseq 0 len) byte_map). 
    Set Guard Checking.

    (* This is mostly to_ubytes, except it will also unwrap concatbytes *)
  Fixpoint serialize_sbytes (uv : uvalue) (dt : dtyp) {struct uv} : ErrSID (list SByte)
    := match uv with
       (* Base types *)
       | UVALUE_Addr _
       | UVALUE_I1 _
       | UVALUE_I8 _
       | UVALUE_I32 _
       | UVALUE_I64 _
       | UVALUE_IPTR _
       | UVALUE_Float _
       | UVALUE_Double _
       | UVALUE_Undef _
       | UVALUE_Poison

       (* Padded aggregate types *)
       | UVALUE_Struct _

       (* Packed aggregate types *)
       | UVALUE_Packed_struct _
       | UVALUE_Array _
       | UVALUE_Vector _

       (* Expressions *)
       | UVALUE_IBinop _ _ _
       | UVALUE_ICmp _ _ _
       | UVALUE_FBinop _ _ _ _
       | UVALUE_FCmp _ _ _
       | UVALUE_Conversion _ _ _
       | UVALUE_GetElementPtr _ _ _
       | UVALUE_ExtractElement _ _
       | UVALUE_InsertElement _ _ _
       | UVALUE_ShuffleVector _ _ _
       | UVALUE_ExtractValue _ _
       | UVALUE_InsertValue _ _ _
       | UVALUE_Select _ _ _
       | UVALUE_Load _ _ _ =>
         sid <- fresh_sid;;
         ret (to_ubytes uv dt sid)

       | UVALUE_None => ret nil

       (* Byte manipulation. *)
       | UVALUE_ExtractByte uv dt' idx sid =>
         raise "serialize_sbytes: UVALUE_ExtractByte not guarded by UVALUE_ConcatBytes."
       | UVALUE_ConcatBytes bytes t =>
         (* TODO: should provide *new* sids... May need to make this function in a fresh sid monad *)
         bytes' <- lift_err (map_monad extract_byte_to_ubyte bytes);;
         re_sid_ubytes bytes'
       end.

  (* deserialize_sbytes takes a list of SBytes and turns them into a uvalue.

     This relies on the similar, but different, from_ubytes function
     which given a set of bytes checks if all of the bytes are from
     the same uvalue, and if so returns the original uvalue, and
     otherwise returns a UVALUE_ConcatBytes value instead.

     The reason we also have deserialize_sbytes is in order to deal
     with aggregate data types.
   *)
  Definition deserialize_sbytes (bytes : list SByte) (dt : dtyp) : err uvalue
    :=
      match dt with
       (* Base types *)
       | DTYPE_I _
       | DTYPE_IPTR
       | DTYPE_Pointer
       | DTYPE_Half
       | DTYPE_Float
       | DTYPE_Double
       | DTYPE_X86_fp80
       | DTYPE_Fp128
       | DTYPE_Ppc_fp128
       | DTYPE_X86_mmx
       | _ =>
         ret (from_ubytes bytes dt)
      end.

       (* serialize_sbytes does not take aggregate structures into
          account. We just extract individual bytes from aggregate
          uvalues. This was necessary for dealing with endianess and
          expressions which yield aggregate structures.

          That said, it would still be nice to be able to edit elements of
          arrays / structures and be able to load them back...

        *)

       (* TODO: should we bother with this? *)
       (* Array and vector types *)
       (* | DTYPE_Array sz t => *)
       (*   let size := sizeof_dtyp t in *)
       (*   let size_nat := N.to_nat size in *)
       (*   fields <- monad_fold_right (fun acc idx => uv <- deserialize_sbytes (between (idx*size) ((idx+1) * size) bytes) t;; ret (uv::acc)) (Nseq 0 size_nat) [];; *)
       (*   ret (UVALUE_Array fields) *)
       (* | DTYPE_Vector sz t => *)
       (*   let size := sizeof_dtyp t in *)
       (*   let size_nat := N.to_nat size in *)
       (*   fields <- monad_fold_right (fun acc idx => uv <- deserialize_sbytes (between (idx*size) ((idx+1) * size) bytes) t;; ret (uv::acc)) (Nseq 0 size_nat) [];; *)
       (*   ret (UVALUE_Vector fields) *)

       (* (* Padded aggregate types *) *)
       (* | DTYPE_Struct fields => *)
       (*   (* TODO: Add padding *) *)
       (*   match fields with *)
       (*   | [] => ret (UVALUE_Struct []) (* TODO: Not 100% sure about this. *) *)
       (*   | (dt::dts) => *)
       (*     let sz := sizeof_dtyp dt in *)
       (*     let init_bytes := take sz bytes in *)
       (*     let rest_bytes := drop sz bytes in *)
       (*     f <- deserialize_sbytes init_bytes dt;; *)
       (*     rest <- deserialize_sbytes rest_bytes (DTYPE_Struct dts);; *)
       (*     match rest with *)
       (*     | UVALUE_Struct fs => *)
       (*       ret (UVALUE_Struct (f::fs)) *)
       (*     | _ => *)
       (*       raise "deserialize_sbytes: DTYPE_Struct recursive call did not return a struct." *)
       (*     end *)
       (*   end *)

       (*   (* match fields with *) *)
       (*   (* | [] => ret (DVALUE_Struct []) *) *)
       (*   (* | (x::xs) => _ *) *)
       (*   (* end *) *)
       (*   (* inl "deserialize_sbytes: padded structures unimplemented." *) *)

       (* (* Structures with no padding *) *)
       (* | DTYPE_Packed_struct fields => *)
         
       (*   inl "deserialize_sbytes: unimplemented packed structs." *)

       (* (* Unimplemented *) *)
       (* | DTYPE_Void => *)
       (*   inl "deserialize_sbytes: attempting to deserialize void." *)
       (* | DTYPE_Metadata => *)
       (*   inl "deserialize_sbytes: metadata." *)

       (* | DTYPE_Opaque => *)
       (*   inl "deserialize_sbytes: opaque." *)
       (* end. *)

(* (* TODO: *)

(*   What is the difference between a pointer and an integer...? *)

(*   Primarily, it's that pointers have provenance and integers don't? *)

(*   So, if we do PVI is there really any difference between an address *)
(*   and an integer, and should we actually distinguish between them? *)

(*   Provenance in UVALUE_IPTR probably means we need provenance in *all* *)
(*   data types... i1, i8, i32, etc, and even doubles and floats... *)
(*  *) *)
  
(* (* TODO: *)

(*    Should uvalue have something like... UVALUE_ExtractByte which *)
(*    extracts a certain byte out of a uvalue? *)

(*    Will probably need an equivalence relation on UVALUEs, likely won't *)
(*    end up with a round-trip property with regular equality... *)
(* *) *)

    Definition default_dvalue_of_dtyp_i (sz : N) : err dvalue:=
      (if (sz =? 64) then ret (DVALUE_I64 (repr 0))
        else if (sz =? 32) then ret (DVALUE_I32 (repr 0))
            else if (sz =? 8) then ret (DVALUE_I8 (repr 0))
                  else if (sz =? 1) then ret (DVALUE_I1 (repr 0))
                       else failwith
              "Illegal size for generating default dvalue of DTYPE_I").


    (* Handler for PickE which concretizes everything to 0 *)
    Fixpoint default_dvalue_of_dtyp (dt : dtyp) : err dvalue :=
      match dt with
      | DTYPE_I sz => default_dvalue_of_dtyp_i sz
      | DTYPE_IPTR => ret (DVALUE_IPTR 0)
      | DTYPE_Pointer => ret (DVALUE_Addr Addr.null)
      | DTYPE_Void => ret DVALUE_None
      | DTYPE_Half => failwith "Unimplemented default type: half"
      | DTYPE_Float => ret (DVALUE_Float Float32.zero)
      | DTYPE_Double => ret (DVALUE_Double (Float32.to_double Float32.zero))
      | DTYPE_X86_fp80 => failwith "Unimplemented default type: x86_fp80"
      | DTYPE_Fp128 => failwith "Unimplemented default type: fp128"
      | DTYPE_Ppc_fp128 => failwith "Unimplemented default type: ppc_fp128"
      | DTYPE_Metadata => failwith "Unimplemented default type: metadata"
      | DTYPE_X86_mmx => failwith "Unimplemented default type: x86_mmx"
      | DTYPE_Opaque => failwith "Unimplemented default type: opaque"
      | DTYPE_Array sz t =>
        if (0 <=? sz) then
          v <- default_dvalue_of_dtyp t ;;
          (ret (DVALUE_Array (repeat v (N.to_nat sz))))
        else
          failwith ("Negative array length for generating default value" ++
          "of DTYPE_Array or DTYPE_Vector")

      (* Matching valid Vector types... *)
      (* Currently commented out unsupported ones *)
      (* | DTYPE_Vector sz (DTYPE_Half) => *)
      (*   if (0 <=? sz) then *)
      (*     (ret (DVALUE_Vector *)
      (*             (repeat (DVALUE_Float Float32.zero) (N.to_nat sz)))) *)
      (*   else *)
      (*     failwith ("Negative array length for generating default value" ++ *)
      (*     "of DTYPE_Array or DTYPE_Vector") *)
      | DTYPE_Vector sz (DTYPE_Float) =>
        if (0 <=? sz) then
          (ret (DVALUE_Vector
                  (repeat (DVALUE_Float Float32.zero) (N.to_nat sz))))
        else
          failwith ("Negative array length for generating default value" ++
          "of DTYPE_Array or DTYPE_Vector")
      | DTYPE_Vector sz (DTYPE_Double) =>
        if (0 <=? sz) then
          (ret (DVALUE_Vector
                  (repeat (DVALUE_Double (Float32.to_double Float32.zero))
                          (N.to_nat sz))))
        else
          failwith ("Negative array length for generating default value" ++
          "of DTYPE_Array or DTYPE_Vector")
      (* | DTYPE_Vector sz (DTYPE_X86_fp80) => *)
      (*   if (0 <=? sz) then *)
      (*     (ret (DVALUE_Vector *)
      (*             (repeat (DVALUE_Float Float32.zero) (N.to_nat sz)))) *)
      (*   else *)
      (*     failwith ("Negative array length for generating default value" ++ *)
      (*     "of DTYPE_Array or DTYPE_Vector") *)
      (* | DTYPE_Vector sz (DTYPE_Fp128) => *)
      (*   if (0 <=? sz) then *)
      (*     (ret (DVALUE_Vector *)
      (*             (repeat (DVALUE_Float Float32.zero) (N.to_nat sz)))) *)
      (*   else *)
      (*     failwith ("Negative array length for generating default value" ++ *)
      (*     "of DTYPE_Array or DTYPE_Vector") *)
      | DTYPE_Vector sz (DTYPE_I n) =>
        if (0 <=? sz) then
          v <- default_dvalue_of_dtyp_i n ;;
          (ret (DVALUE_Vector (repeat v (N.to_nat sz))))
        else
          failwith ("Negative array length for generating default value" ++
          "of DTYPE_Array or DTYPE_Vector")
      | DTYPE_Vector _ _ => failwith ("Non-valid vector type when" ++
          "generating default vector")
      | DTYPE_Struct fields =>
        v <- @map_monad err _ dtyp dvalue default_dvalue_of_dtyp fields;;
        ret (DVALUE_Struct v)
      | DTYPE_Packed_struct fields =>
        v <- @map_monad err _ dtyp dvalue default_dvalue_of_dtyp fields;;
        ret (DVALUE_Packed_struct v)
      end.


    Section Concretize.
 
      

      Variable endianess : Endianess.

      (* Convert a list of UVALUE_ExtractByte values into a dvalue of
         a given type.

         Assumes bytes are in little endian form...

         Note: I believe this function has to be endianess aware.

         This probably also needs to be mutually recursive with
         concretize_uvalue...

         Idea:

         For each byte in the list, find uvalues that are from the
         same store.

         - Can I have bytes that are from the same store, but
           different uvalues?  + Might not be possible, actually,
           because if I store a concatbytes I get the old sids...  +
           TODO: Getting the old sids might be a problem,
           though. Should be new, but entangled wherever they were
           entangled before. This needs to be changed in serialize...
           * I.e., If I load bytes from one store, and then store them
           beside them... It should have a different sid, allowing the
           bytes from that store to vary independently.  * ALSO bytes
           that are entangled should *stay* entangled.

         The above is largely an issue with serialize_sbytes...

         The idea here should be to take equal uvalues in our byte
         list with the same sid and concretize the uvalue exactly
         once.

         After all uvalues in our list are concretized we then need to
         convert the corresponding byte extractions into a single
         dvalue.

       *)

      (* TODO: probably move this *)
      (* TODO: Make these take endianess into account.

         Can probably use bitwidth from VInt to do big-endian...
       *)
      Definition extract_byte_vint {I} `{VInt I} (i : I) (idx : Z) : Z
        := unsigned (modu (shru i (repr (idx * 8))) (repr 256)).

      Fixpoint concat_bytes_vint {I} `{VInt I} (bytes : list I) : I
        := match bytes with
           | [] => repr 0
           | (byte::bytes) =>
             add byte (shl (concat_bytes_vint bytes) (repr 8))
           end.

      (* TODO: Endianess *)
      (* TODO: does this work correctly with negative x? *)
      Definition extract_byte_Z (x : Z) (idx : Z) : Z
        := (Z.shiftr x (idx * 8)) mod 256.

      (* TODO: Endianess *)
      Definition concat_bytes_Z_vint {I} `{VInt I} (bytes : list Z) : I
        := concat_bytes_vint (map repr bytes).

      (* TODO: Endianess *)
      Fixpoint concat_bytes_Z (bytes : list Z) : Z
        := match bytes with
           | [] => 0
           | (byte::bytes) =>
             byte + (Z.shiftl (concat_bytes_Z bytes) 8)
           end.

      (* TODO: Move this? *)
      Inductive Poisonable (A : Type) : Type :=
      | Unpoisoned : A -> Poisonable A
      | Poison : Poisonable A
      .

      Arguments Unpoisoned {A} a.
      Arguments Poison {A}.

      Global Instance MonadPoisonable : Monad Poisonable
        := { ret  := @Unpoisoned;
             bind := fun _ _ ma mab => match ma with
                                   | Poison => Poison
                                   | Unpoisoned v => mab v
                                    end
           }.

      Definition ErrPoison := eitherT string Poisonable.

      (* Walk through a list *)
      (* Returns field index + number of bytes remaining *)
      Fixpoint extract_field_byte_helper {M} `{Monad M} (fields : list dtyp) (field_idx : N) (byte_idx : N) : eitherT string M (dtyp * (N * N))
        := match fields with
           | [] =>
             raise "No fields left for byte-indexing..."
           | (x::xs) =>
             let sz := sizeof_dtyp x
             in if N.ltb byte_idx sz
                then ret (x, (field_idx, byte_idx))
                else extract_field_byte_helper xs (N.succ field_idx) (byte_idx - sz)
           end.

      Fixpoint extract_field_byte {M} `{Monad M} (fields : list dtyp) (byte_idx : N) : eitherT string M (dtyp * (N * N))
        := extract_field_byte_helper fields 0 byte_idx.
      
      (* Need the type of the dvalue in order to know how big fields and array elements are.

         It's not possible to use the dvalue alone, as DVALUE_Poison's
         size depends on the type.
       *)
      (* TODO: make termination checker happy *)
      Unset Guard Checking.
      Fixpoint dvalue_extract_byte (dv : dvalue) (dt : dtyp) (idx : Z) {struct dv}: ErrPoison Z
        := match dv with
           | DVALUE_I1 x
           | DVALUE_I8 x
           | DVALUE_I32 x
           | DVALUE_I64 x =>
             ret (extract_byte_vint x idx)
           | DVALUE_IPTR x =>
             ret (extract_byte_Z x idx)
           | DVALUE_Addr addr =>
             (* Note: this throws away provenance *)
             ret (extract_byte_Z (ptr_to_int addr) idx)
           | DVALUE_Float f =>
             ret (extract_byte_Z (unsigned (Float32.to_bits f)) idx)
           | DVALUE_Double d =>
             ret (extract_byte_Z (unsigned (Float.to_bits d)) idx)
           | DVALUE_Poison => lift Poison
           | DVALUE_None =>
             (* TODO: Not sure if this should be an error, poison, or what. *)
             raise "dvalue_extract_byte on DVALUE_None"
           (* TODO: Take padding into account. *)
           | DVALUE_Struct fields =>
             match dt with
             | DTYPE_Struct dts =>
               (* Step to field which contains the byte we want *)
               '(fdt, (field_idx, byte_idx)) <- extract_field_byte dts (Z.to_N idx) ;;
               match List.nth_error fields (N.to_nat field_idx) with
               | Some f =>
                 (* call dvalue_extract_byte recursively on the field *)
                 dvalue_extract_byte f fdt (Z.of_N byte_idx)
               | None =>
                 raise "dvalue_extract_byte: more fields in dvalue than in dtyp."
               end
             | _ => raise "dvalue_extract_byte: type mismatch on DVALUE_Struct."
             end
           | DVALUE_Packed_struct fields =>
             match dt with
             | DTYPE_Packed_struct dts =>
               (* Step to field which contains the byte we want *)
               '(fdt, (field_idx, byte_idx)) <- extract_field_byte dts (Z.to_N idx) ;;
               match List.nth_error fields (N.to_nat field_idx) with
               | Some f =>
                 (* call dvalue_extract_byte recursively on the field *)
                 dvalue_extract_byte f fdt (Z.of_N byte_idx)
               | None =>
                 raise "dvalue_extract_byte: more fields in dvalue than in dtyp."
               end
             | _ => raise "dvalue_extract_byte: type mismatch on DVALUE_Packed_struct."
             end
           | DVALUE_Array elts =>
             match dt with
             | DTYPE_Array sz dt =>
               let elmt_sz  := sizeof_dtyp dt in
               let elmt_idx := N.div (Z.to_N idx) elmt_sz in
               let byte_idx := (Z.to_N idx) mod elmt_sz in
               match List.nth_error elts (N.to_nat elmt_idx) with
               | Some elmt =>
                 (* call dvalue_extract_byte recursively on the field *)
                 dvalue_extract_byte elmt dt (Z.of_N byte_idx)
               | None =>
                 raise "dvalue_extract_byte: more fields in dvalue than in dtyp."
               end
             | _ =>
               raise "dvalue_extract_byte: type mismatch on DVALUE_Array."
             end
           | DVALUE_Vector elts =>
             match dt with
             | DTYPE_Vector sz dt =>
               let elmt_sz  := sizeof_dtyp dt in
               let elmt_idx := N.div (Z.to_N idx) elmt_sz in
               let byte_idx := (Z.to_N idx) mod elmt_sz in
               match List.nth_error elts (N.to_nat elmt_idx) with
               | Some elmt =>
                 (* call dvalue_extract_byte recursively on the field *)
                 dvalue_extract_byte elmt dt (Z.of_N byte_idx)
               | None =>
                 raise "dvalue_extract_byte: more fields in dvalue than in dtyp."
               end
             | _ =>
               raise "dvalue_extract_byte: type mismatch on DVALUE_Vector."
             end
           end.
      Set Guard Checking.

      (* Taking a byte out of a dvalue...

      Unlike UVALUE_ExtractByte, I don't think this needs an sid
      (store id). There should be no nondeterminism in this value. *)
      Inductive dvalue_byte : Type :=
      | DVALUE_ExtractByte (dv : dvalue) (dt : dtyp) (idx : N) : dvalue_byte
      .

      Definition dvalue_byte_value (db : dvalue_byte) : ErrPoison Z
        := match db with
           | DVALUE_ExtractByte dv dt idx =>
             dvalue_extract_byte dv dt (Z.of_N idx)
           end.

      (* TODO: probably satisfy the termination checker with length of xs... *)
      Unset Guard Checking.
      Fixpoint split_every {A} (n : N) (xs : list A) {struct xs} : (list (list A))
        := match xs with
           | [] => []
           | _ =>
             take n xs :: split_every n (drop n xs)
           end.
      Set Guard Checking.

      Unset Guard Checking.
      Fixpoint dvalue_bytes_to_dvalue (dbs : list dvalue_byte) (dt : dtyp) {struct dt} : ErrPoison dvalue
        := match dt with
           | DTYPE_I sz =>
             zs <- map_monad dvalue_byte_value dbs;;
             match sz with
             | 1 =>
               ret (DVALUE_I1 (concat_bytes_Z_vint zs))
             | 8 =>
               ret (DVALUE_I8 (concat_bytes_Z_vint zs))
             | 32 =>
               ret (DVALUE_I32 (concat_bytes_Z_vint zs))
             | 64 =>
               ret (DVALUE_I64 (concat_bytes_Z_vint zs))
             | _ => raise "Unsupported integer size."
             end
           | DTYPE_IPTR =>
             zs <- map_monad dvalue_byte_value dbs;;
             ret (DVALUE_IPTR (concat_bytes_Z zs))
           | DTYPE_Pointer =>
             (* TODO: not sure if this should be wildcard provenance.
                TODO: not sure if this should truncate iptr value...
              *)
             zs <- map_monad dvalue_byte_value dbs;;
             ret (DVALUE_Addr (int_to_ptr (concat_bytes_Z zs) wildcard_prov))
           | DTYPE_Void =>
             raise "dvalue_bytes_to_dvalue on void type."
           | DTYPE_Half =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_Half."
           | DTYPE_Float =>
             zs <- map_monad dvalue_byte_value dbs;;
             ret (DVALUE_Float (Float32.of_bits (concat_bytes_Z_vint zs)))
           | DTYPE_Double =>
             zs <- map_monad dvalue_byte_value dbs;;
             ret (DVALUE_Float (Float32.of_bits (concat_bytes_Z_vint zs)))
           | DTYPE_X86_fp80 =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_X86_fp80."
           | DTYPE_Fp128 =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_Fp128."
           | DTYPE_Ppc_fp128 =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_Ppc_fp128."
           | DTYPE_Metadata =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_Metadata."
           | DTYPE_X86_mmx =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_X86_mmx."
           | DTYPE_Array sz t =>
             let sz := sizeof_dtyp t in
             let elt_bytes := split_every sz dbs in
             elts <- map_monad (fun es => dvalue_bytes_to_dvalue es t) elt_bytes;;
             ret (DVALUE_Array elts)
           | DTYPE_Vector sz t =>
             let sz := sizeof_dtyp t in
             let elt_bytes := split_every sz dbs in
             elts <- map_monad (fun es => dvalue_bytes_to_dvalue es t) elt_bytes;;
             ret (DVALUE_Vector elts)
           | DTYPE_Struct fields =>
             match fields with
             | [] => ret (DVALUE_Struct []) (* TODO: Not 100% sure about this. *)
             | (dt::dts) =>
               let sz := sizeof_dtyp dt in
               let init_bytes := take sz dbs in
               let rest_bytes := drop sz dbs in
               f <- dvalue_bytes_to_dvalue init_bytes dt;;
               rest <- dvalue_bytes_to_dvalue rest_bytes (DTYPE_Struct dts);;
               match rest with
               | DVALUE_Struct fs =>
                 ret (DVALUE_Struct (f::fs))
               | _ =>
                 raise "dvalue_bytes_to_dvalue: DTYPE_Struct recursive call did not return a struct."
               end
             end
           | DTYPE_Packed_struct fields =>
             match fields with
             | [] => ret (DVALUE_Packed_struct []) (* TODO: Not 100% sure about this. *)
             | (dt::dts) =>
               let sz := sizeof_dtyp dt in
               let init_bytes := take sz dbs in
               let rest_bytes := drop sz dbs in
               f <- dvalue_bytes_to_dvalue init_bytes dt;;
               rest <- dvalue_bytes_to_dvalue rest_bytes (DTYPE_Struct dts);;
               match rest with
               | DVALUE_Packed_struct fs =>
                 ret (DVALUE_Packed_struct (f::fs))
               | _ =>
                 raise "dvalue_bytes_to_dvalue: DTYPE_Packed_struct recursive call did not return a struct."
               end
             end
           | DTYPE_Opaque =>
             raise "dvalue_bytes_to_dvalue: unsupported DTYPE_Opaque."
           end.
      Set Guard Checking.

      Definition uvalue_sid_match (a b : uvalue) : bool
        :=
          match a, b with
          | UVALUE_ExtractByte uv dt idx sid, UVALUE_ExtractByte uv' dt' idx' sid' =>
            RelDec.rel_dec uv uv' && N.eqb sid sid'
          | _, _ => false
          end.

      Definition filter_uvalue_sid_matches (byte : uvalue) (uvs : list (N * uvalue)) : (list (N * uvalue) * list (N * uvalue))
        := filter_split (fun '(n, uv) => uvalue_sid_match byte uv) uvs.


      Definition ErrPoison_to_undef_or_err_dvalue (ep : ErrPoison dvalue) : undef_or_err dvalue
        := match unEitherT ep with
           | Unpoisoned dv => lift dv
           | Poisoin => ret DVALUE_Poison
           end.

      (* TODO: satisfy the termination checker here. *)
      Unset Guard Checking.
      Fixpoint concretize_uvalue (u : uvalue) {struct u} : undef_or_err dvalue :=
        match u with
        | UVALUE_Addr a                          => ret (DVALUE_Addr a)
        | UVALUE_I1 x                            => ret (DVALUE_I1 x)
        | UVALUE_I8 x                            => ret (DVALUE_I8 x)
        | UVALUE_I32 x                           => ret (DVALUE_I32 x)
        | UVALUE_I64 x                           => ret (DVALUE_I64 x)
        | UVALUE_IPTR x                          => ret (DVALUE_IPTR x)
        | UVALUE_Double x                        => ret (DVALUE_Double x)
        | UVALUE_Float x                         => ret (DVALUE_Float x)
        | UVALUE_Undef t                         => lift (default_dvalue_of_dtyp t)
        | UVALUE_Poison                          => ret (DVALUE_Poison)
        | UVALUE_None                            => ret DVALUE_None
        | UVALUE_Struct fields                   => 'dfields <- map_monad concretize_uvalue fields ;;
                                                   ret (DVALUE_Struct dfields)
        | UVALUE_Packed_struct fields            => 'dfields <- map_monad concretize_uvalue fields ;;
                                                   ret (DVALUE_Packed_struct dfields)
        | UVALUE_Array elts                      => 'delts <- map_monad concretize_uvalue elts ;;
                                                   ret (DVALUE_Array delts)
        | UVALUE_Vector elts                     => 'delts <- map_monad concretize_uvalue elts ;;
                                                   ret (DVALUE_Vector delts)
        | UVALUE_IBinop iop v1 v2                => dv1 <- concretize_uvalue v1 ;;
                                                   dv2 <- concretize_uvalue v2 ;;
                                                   eval_iop iop dv1 dv2
        | UVALUE_ICmp cmp v1 v2                  => dv1 <- concretize_uvalue v1 ;;
                                                   dv2 <- concretize_uvalue v2 ;;
                                                   eval_icmp cmp dv1 dv2
        | UVALUE_FBinop fop fm v1 v2             => dv1 <- concretize_uvalue v1 ;;
                                                   dv2 <- concretize_uvalue v2 ;;
                                                   eval_fop fop dv1 dv2
        | UVALUE_FCmp cmp v1 v2                  => dv1 <- concretize_uvalue v1 ;;
                                                   dv2 <- concretize_uvalue v2 ;;
                                                   eval_fcmp cmp dv1 dv2
        | UVALUE_ConcatBytes bytes dt =>
          match N.eqb (N.of_nat (length bytes)) (sizeof_dtyp dt), all_extract_bytes_from_uvalue bytes with
          | true, Some uv => concretize_uvalue uv
          | _, _ => extractbytes_to_dvalue bytes dt
          end

        | UVALUE_ExtractByte byte dt idx sid =>
          (* TODO: maybe this is just an error? ExtractByte should be guarded by ConcatBytes? *)
          lift (failwith "Attempting to concretize UVALUE_ExtractByte, should not happen.")
        | UVALUE_Load dt uv mem =>
          UVALUE_Load dt

        | _ => (lift (failwith "Attempting to convert a partially non-reduced uvalue to dvalue. Should not happen"))

                
        end

      with

      (* Take a UVALUE_ExtractByte, and replace the uvalue with a given dvalue... 

         Note: this also concretizes the index.
       *)
      uvalue_byte_replace_with_dvalue_byte (uv : uvalue) (dv : dvalue) {struct uv} : undef_or_err dvalue_byte
        := match uv with
           | UVALUE_ExtractByte uv dt idx sid =>
             cidx <- concretize_uvalue idx;;
             ret (DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)))
           | _ => lift (failwith "uvalue_byte_replace_with_dvalue_byte called with non-UVALUE_ExtractByte value.")
           end

      with
      (* Concretize the uvalues in a list of UVALUE_ExtractBytes...

       *)
        (* Pick out uvalue bytes that are the same + have same sid 

         Concretize these identical uvalues...
         *)

      concretize_uvalue_bytes_helper (uvs : list (N * uvalue)) (acc : NMap dvalue_byte) {struct uvs} : undef_or_err (NMap dvalue_byte)
        := match uvs with
           | [] => ret acc
           | ((n, uv)::uvs) =>
             match uv with
             | UVALUE_ExtractByte byte_uv dt idx sid =>
               let '(ins, outs) := filter_uvalue_sid_matches uv uvs in
               (* Concretize first uvalue *)
               dv <- concretize_uvalue byte_uv;;
               cidx <- concretize_uvalue idx;;
               let dv_byte := DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)) in
               let acc := @NM.add _ n dv_byte acc in
               (* Concretize entangled bytes *)
               acc <- monad_fold_right (fun acc '(n, uv) =>
                                         dvb <- uvalue_byte_replace_with_dvalue_byte uv dv;;
                                         ret (@NM.add _ n dvb acc)) ins acc;;
               (* Concretize the rest of the bytes *)
               concretize_uvalue_bytes_helper outs acc
             | _ => lift (failwith "concretize_uvalue_bytes_helper: non-byte in uvs.")
             end
           end

      with
      concretize_uvalue_bytes (uvs : list uvalue) {struct uvs} : undef_or_err (list dvalue_byte)
        :=
          let len := length uvs in
          byte_map <- concretize_uvalue_bytes_helper (zip (Nseq 0 len) uvs) (@NM.empty _);;
          match NM_find_many (Nseq 0 len) byte_map with
          | Some dvbs => ret dvbs
          | None => lift (failwith "concretize_uvalue_bytes: missing indices.")
          end
      
      with
      extractbytes_to_dvalue (uvs : list uvalue) (dt : dtyp) {struct uvs} : undef_or_err dvalue
        := dvbs <- concretize_uvalue_bytes uvs;;
           ErrPoison_to_undef_or_err_dvalue (dvalue_bytes_to_dvalue dvbs dt).
      Set Guard Checking.

    End Concretize.

    (* Specifying the currently supported dynamic types.
       This is mostly to rule out:

       - arbitrary bitwidth integers
       - half
       - x86_fp80
       - fp128
       - ppc_fp128
       - metadata
       - x86_mmx
       - opaque
     *)
    (* TODO: stolen from Memory.v *)
    Inductive is_supported : dtyp -> Prop :=
    | is_supported_DTYPE_I1 : is_supported (DTYPE_I 1)
    | is_supported_DTYPE_I8 : is_supported (DTYPE_I 8)
    | is_supported_DTYPE_I32 : is_supported (DTYPE_I 32)
    | is_supported_DTYPE_I64 : is_supported (DTYPE_I 64)
    | is_supported_DTYPE_Pointer : is_supported (DTYPE_Pointer)
    | is_supported_DTYPE_Void : is_supported (DTYPE_Void)
    | is_supported_DTYPE_Float : is_supported (DTYPE_Float)
    | is_supported_DTYPE_Double : is_supported (DTYPE_Double)
    | is_supported_DTYPE_Array : forall sz τ, is_supported τ -> is_supported (DTYPE_Array sz τ)
    | is_supported_DTYPE_Struct : forall fields, Forall is_supported fields -> is_supported (DTYPE_Struct fields)
    | is_supported_DTYPE_Packed_struct : forall fields, Forall is_supported fields -> is_supported (DTYPE_Packed_struct fields)
    (* TODO: unclear if is_supported τ is good enough here. Might need to make sure it's a sized type *)
    | is_supported_DTYPE_Vector : forall sz τ, is_supported τ -> is_supported (DTYPE_Vector sz τ)
.

Ltac eval_nseq :=
  match goal with
  | |- context[Nseq ?start ?len] =>
    let HS := fresh "HS" in
    let HSeq := fresh "HSeq" in
    remember (Nseq start len) as HS eqn:HSeq;
    cbv in HSeq;
    subst HS
  end.

Ltac uvalue_eq_dec_refl_true :=
  rewrite rel_dec_eq_true; [|exact eq_dec_uvalue_correct|reflexivity].

Ltac solve_guards_all_bytes :=
  try rewrite N.eqb_refl; try rewrite Z.eqb_refl; try uvalue_eq_dec_refl_true; cbn.

Lemma all_bytes_helper_app :
  forall  sbytes sbytes2 start sid uv,
    all_bytes_from_uvalue_helper (Z.of_N start) sid uv sbytes = Some uv ->
    all_bytes_from_uvalue_helper (Z.of_N (start + N.of_nat (length sbytes))) sid uv sbytes2 = Some uv ->
    all_bytes_from_uvalue_helper (Z.of_N start) sid uv (sbytes ++ sbytes2) = Some uv.
Proof.
  induction sbytes;
    intros sbytes2 start sid uv INIT REST.
  - now rewrite N.add_0_r in REST.
  - cbn.
    destruct a.
    cbn in INIT.
    do 3 (break_match; [|solve [inv INIT]]).


    cbn in REST. auto.
    replace (Z.of_N (start + N.pos (Pos.of_succ_nat (Datatypes.length sbytes)))) with (Z.of_N (N.succ start + N.of_nat (Datatypes.length sbytes))) in REST by lia.

    rewrite <- N2Z.inj_succ in *.
    
    apply IHsbytes; auto.
Qed.

Lemma to_ubytes_all_bytes_from_uvalue_helper' :
  forall len uv dt sid sbytes start,
    is_supported dt ->
    map (fun n : N => UByte uv dt (UVALUE_IPTR (Z.of_N n)) sid) (Nseq start len) = sbytes ->
    all_bytes_from_uvalue_helper (Z.of_N start) sid uv sbytes = Some uv.
Proof.
  induction len;
    intros uv dt sid sbytes start SUP TO.
  - inv TO; reflexivity.
  - inv TO.
    rewrite Nseq_S.
    rewrite map_app.
    apply all_bytes_helper_app; eauto.
    + cbn.
      rewrite map_length.
      rewrite Nseq_length.
      solve_guards_all_bytes.
      reflexivity.
Qed.

Lemma to_ubytes_all_bytes_from_uvalue_helper :
  forall uv dt sid sbytes,
    is_supported dt ->
    to_ubytes uv dt sid = sbytes ->
    all_bytes_from_uvalue_helper 0 sid uv sbytes = Some uv.
Proof.  
  intros uv dt sid sbytes SUP TO.

  change 0%Z with (Z.of_N 0).
  eapply to_ubytes_all_bytes_from_uvalue_helper'; eauto.    
Qed.

Lemma to_ubytes_sizeof_dtyp :
  forall uv dt sid,  
    N.of_nat (length (to_ubytes uv dt sid)) = sizeof_dtyp dt.
Proof.
  intros uv dt sid.
  unfold to_ubytes.
  rewrite map_length, Nseq_length.
  lia.
Qed.

Lemma from_ubytes_to_ubytes :
  forall uv dt sid,
    is_supported dt ->
    sizeof_dtyp dt > 0 ->
    from_ubytes (to_ubytes uv dt sid) dt = uv.
Proof.
  intros uv dt sid SUP SIZE.

  unfold from_ubytes.
  unfold all_bytes_from_uvalue.

  rewrite to_ubytes_sizeof_dtyp.
  rewrite N.eqb_refl.

  break_inner_match.
  - (* Contradiction by size *)
    pose proof to_ubytes_sizeof_dtyp uv dt sid.
    rewrite Heql in H.

    cbn in *.
    lia.
  - destruct s.
    cbn in *.

    unfold to_ubytes in Heql.
    remember (sizeof_dtyp dt) as sz.
    destruct sz; [inv SIZE|].
    cbn in *.
    pose proof Pos2Nat.is_succ p as [sz Hsz].
    rewrite Hsz in Heql.
    rewrite <- cons_Nseq in Heql.

    cbn in Heql.
    inv Heql.
    cbn.

    solve_guards_all_bytes.

    cbn.
    change 1%Z with (Z.of_N 1).
    erewrite to_ubytes_all_bytes_from_uvalue_helper'; eauto.
Qed.

Lemma serialize_sbytes_deserialize_sbytes :
  forall uv dt sid sbytes ,
    uvalue_has_dtyp uv dt ->
    is_supported dt ->
    sizeof_dtyp dt > 0 ->
    evalErrSID (serialize_sbytes uv dt) sid = inr (sbytes) ->
    deserialize_sbytes sbytes dt = inr uv.
Proof.
  intros uv dt sid sbytes TYP SUP SIZE SER.
  induction TYP;
    try solve [unfold serialize_sbytes in SER;
               inv SER;
               unfold deserialize_sbytes;
               rewrite from_ubytes_to_ubytes; eauto
              | cbn in *;
                match goal with
                | |- deserialize_sbytes _ ?t = _ =>
                  cbn in *;
                  destruct t; cbn; inv SER;
                  rewrite from_ubytes_to_ubytes; eauto
                end
              ].
  - inv SUP; exfalso; apply H; constructor.
  - inv SIZE.
Qed.


Section ConcretizeInductive.

  Variable endianess : Endianess.

  Inductive concretize_u : uvalue -> undef_or_err dvalue -> Prop :=
  (* TODO: should uvalue_to_dvalue be modified to handle concatbytes? *)
  (* Concrete uvalue are concretized into their singleton *)
  | Pick_concrete             : forall uv (dv : dvalue), uvalue_to_dvalue uv = inr dv -> concretize_u uv (ret dv)
  | Pick_fail                 : forall uv v s, ~ (uvalue_to_dvalue uv = inr v)  -> concretize_u uv (lift (failwith s))
  (* Undef relates to all dvalue of the type *)
  | Concretize_Undef          : forall dt dv,
      dvalue_has_dtyp dv dt ->
      concretize_u (UVALUE_Undef dt) (ret dv)

  (* The other operations proceed non-deterministically *)
  | Concretize_IBinop : forall iop uv1 e1 uv2 e2,
      concretize_u uv1 e1 ->
      concretize_u uv2 e2 ->
      concretize_u (UVALUE_IBinop iop uv1 uv2)
                   (dv1 <- e1 ;;
                    dv2 <- e2 ;;
                    (eval_iop iop dv1 dv2))
                   
  | Concretize_ICmp : forall cmp uv1 e1 uv2 e2 ,
      concretize_u uv1 e1 ->
      concretize_u uv2 e2 ->
      concretize_u (UVALUE_ICmp cmp uv1 uv2)
                   (dv1 <- e1 ;;
                    dv2 <- e2 ;;
                    eval_icmp cmp dv1 dv2)

  | Concretize_FBinop : forall fop fm uv1 e1 uv2 e2,
      concretize_u uv1 e1 ->
      concretize_u uv2 e2 ->
      concretize_u (UVALUE_FBinop fop fm uv1 uv2)
                   (dv1 <- e1 ;;
                    dv2 <- e2 ;;
                    eval_fop fop dv1 dv2)

  | Concretize_FCmp : forall cmp uv1 e1 uv2 e2,
      concretize_u uv1 e1 ->
      concretize_u uv2 e2 ->
      concretize_u (UVALUE_FCmp cmp uv1 uv2)
                   (dv1 <- e1 ;;
                    dv2 <- e2 ;;
                    eval_fcmp cmp dv1 dv2)

  | Concretize_Struct_Nil     : concretize_u (UVALUE_Struct []) (ret (DVALUE_Struct []))
  | Concretize_Struct_Cons    : forall u e us es,
      concretize_u u e ->
      concretize_u (UVALUE_Struct us) es ->
      concretize_u (UVALUE_Struct (u :: us))
                   (d <- e ;;
                    vs <- es ;;
                    match vs with
                    | (DVALUE_Struct ds) => ret (DVALUE_Struct (d :: ds))
                    | _ => failwith "illegal Struct Cons"
                    end)


  | Concretize_Packed_struct_Nil     : concretize_u (UVALUE_Packed_struct []) (ret (DVALUE_Packed_struct []))
  | Concretize_Packed_struct_Cons    : forall u e us es,
      concretize_u u e ->
      concretize_u (UVALUE_Packed_struct us) es ->
      concretize_u (UVALUE_Packed_struct (u :: us))
                   (d <- e ;;
                    vs <- es ;;
                    match vs with
                    | (DVALUE_Packed_struct ds) => ret (DVALUE_Packed_struct (d :: ds))
                    | _ => failwith "illegal Packed_struct cons"
                    end)

  | Concretize_Array_Nil :
      concretize_u (UVALUE_Array []) (ret (DVALUE_Array []))

  | Concretize_Array_Cons : forall u e us es,
      concretize_u u e ->
      concretize_u (UVALUE_Array us) es ->
      concretize_u (UVALUE_Array (u :: us))
                   (d <- e ;;
                    vs <- es ;;
                    match vs with
                    | (DVALUE_Array ds) => ret (DVALUE_Array (d :: ds))
                    | _ => failwith "illegal Array cons"
                    end)

  | Concretize_Vector_Nil :
      concretize_u (UVALUE_Vector []) (ret (DVALUE_Vector []))

  | Concretize_Vector_Cons : forall u e us es,
      concretize_u u e ->
      concretize_u (UVALUE_Vector us) es ->
      concretize_u (UVALUE_Vector (u :: us))
                   (d <- e ;;
                    vs <- es ;;
                    match vs with
                    | (DVALUE_Vector ds) => ret (DVALUE_Vector (d :: ds))
                    | _ => failwith "illegal Vector cons"
                    end)

  (* The list of bytes contained here exactly match the serialization of a value of the data type.

     This means we can just take the corresponding uvalue, and concretize it.
   *)
  | Concretize_ConcatBytes_Exact :
      forall bytes dt uv dv,
        all_bytes_from_uvalue bytes = Some uv ->
        N.of_nat (List.length bytes) = sizeof_dtyp dt ->
        concretize_u uv dv ->
        concretize_u (UVALUE_ConcatBytes (map ubyte_to_extractbyte bytes) dt) dv
  (* with *)
  (*   concretize_u_dvalue_bytes : list uvalue -> NMap dvalue_byte -> undef_or_err (NMap dvalue_byte) -> Prop := *)
  (* | concretize_u_dvalue_bytes_nil : forall acc, concretize_u_dvalue_bytes [] acc (ret acc) *)
  (* | concretize_u_dvalue_bytes_cons : *)
  (*     forall uv byte_uv dt idx sid cidx dv ins outs, *)
  (*     uv = UVALUE_ExtractByte byte_uv dt idx sid -> *)
  (*     filter_uvalue_sid_matches uv uvs = (ins, outs) -> *)
  (*     concretize_u byte_uv dv -> *)
  (*     concretize_u idx cidx -> *)
  (*     dv_byte = DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)) -> *)
  (*     acc' = monad_fold_right (fun acc '(n, uv) => *)
  (*                              dvb <- uvalue_byte_replace_with_dvalue_byte . *)

  (* The list of bytes in the UVALUE_ConcatBytes does not correspond
     directly to the serialization of the data type. I.e., it is not a
     list of ExtractBytes that directly come from a value of the given
     type.

     This means we essentially have to read the raw byte values and
     combine them together in order to construct a dvalue. 
   *)
  (* | Concretize_ConcatBytes_Raw : *)
  (*     (* extractbytes_to_dvalue is used in concretize_uvalue *) *)
  (*     (* Need to find the entangled bytes *) *)
  (*     (* Concretize the entangled bytes *) *)
  (*     (* Put them back together... *) *)
  (*     uv = UVALUE_ExtractByte byte_uv dt idx sid -> *)
  (*     filter_uvalue_sid_matches uv uvs = (ins, outs) -> *)
  (*     concretize_u byte_uv dv -> *)
  (*     concretize_u idx cidx -> *)
  (*     dv_byte = DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)) -> *)
  (*     concretize_u_bytes bytes dvbs -> *)
  (*     blah dvbs dv *)
  (* . *)

  (* (* *)
  (*     concretize_uvalue_bytes_helper (uvs : list (N * uvalue)) (acc : NMap dvalue_byte) {struct uvs} : undef_or_err (NMap dvalue_byte) *)
  (*       := match uvs with *)
  (*          | [] => ret acc *)
  (*          | ((n, uv)::uvs) => *)
  (*            match uv with *)
  (*            | UVALUE_ExtractByte byte_uv dt idx sid => *)
  (*              let '(ins, outs) := filter_uvalue_sid_matches uv uvs in *)
  (*              (* Concretize first uvalue *) *)
  (*              dv <- concretize_uvalue byte_uv;; *)
  (*              cidx <- concretize_uvalue idx;; *)
  (*              let dv_byte := DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)) in *)
  (*              let acc := @NM.add _ n dv_byte acc in *)
  (*              (* Concretize entangled bytes *) *)
  (*              acc <- monad_fold_right (fun acc '(n, uv) => *)
  (*                                        dvb <- uvalue_byte_replace_with_dvalue_byte uv dv;; *)
  (*                                        ret (@NM.add _ n dvb acc)) ins acc;; *)
  (*              (* Concretize the rest of the bytes *) *)
  (*              concretize_uvalue_bytes_helper outs acc *)
  (*            | _ => lift (failwith "concretize_uvalue_bytes_helper: non-byte in uvs.") *)
  (*            end *)
  (*          end *)

  (*  *) *)

  
(* (*****************************) *)
(*       (* Take a UVALUE_ExtractByte, and replace the uvalue with a given dvalue...  *)

(*          Note: this also concretizes the index. *)
(*        *) *)
(*       uvalue_byte_replace_with_dvalue_byte (uv : uvalue) (dv : dvalue) {struct uv} : undef_or_err dvalue_byte *)
(*         := match uv with *)
(*            | UVALUE_ExtractByte uv dt idx sid => *)
(*              cidx <- concretize_uvalue idx;; *)
(*              ret (DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx))) *)
(*            | _ => lift (failwith "uvalue_byte_replace_with_dvalue_byte called with non-UVALUE_ExtractByte value.") *)
(*            end *)

(*       with *)
(*       (* Concretize the uvalues in a list of UVALUE_ExtractBytes... *)

(*        *) *)
(*         (* Pick out uvalue bytes that are the same + have same sid  *)

(*          Concretize these identical uvalues... *)
(*          *) *)

(*       concretize_uvalue_bytes_helper (uvs : list (N * uvalue)) (acc : NMap dvalue_byte) {struct uvs} : undef_or_err (NMap dvalue_byte) *)
(*         := match uvs with *)
(*            | [] => ret acc *)
(*            | ((n, uv)::uvs) => *)
(*              match uv with *)
(*              | UVALUE_ExtractByte byte_uv dt idx sid => *)
(*                let '(ins, outs) := filter_uvalue_sid_matches uv uvs in *)
(*                (* Concretize first uvalue *) *)
(*                dv <- concretize_uvalue byte_uv;; *)
(*                cidx <- concretize_uvalue idx;; *)
(*                let dv_byte := DVALUE_ExtractByte dv dt (Z.to_N (dvalue_int_unsigned cidx)) in *)
(*                let acc := @NM.add _ n dv_byte acc in *)
(*                (* Concretize entangled bytes *) *)
(*                acc <- monad_fold_right (fun acc '(n, uv) => *)
(*                                          dvb <- uvalue_byte_replace_with_dvalue_byte uv dv;; *)
(*                                          ret (@NM.add _ n dvb acc)) ins acc;; *)
(*                (* Concretize the rest of the bytes *) *)
(*                concretize_uvalue_bytes_helper outs acc *)
(*              | _ => lift (failwith "concretize_uvalue_bytes_helper: non-byte in uvs.") *)
(*              end *)
(*            end *)

(*       with *)
(*       concretize_uvalue_bytes (uvs : list uvalue) {struct uvs} : undef_or_err (list dvalue_byte) *)
(*         := *)
(*           let len := length uvs in *)
(*           byte_map <- concretize_uvalue_bytes_helper (zip (Nseq 0 len) uvs) (@NM.empty _);; *)
(*           match NM_find_many (Nseq 0 len) byte_map with *)
(*           | Some dvbs => ret dvbs *)
(*           | None => lift (failwith "concretize_uvalue_bytes: missing indices.") *)
(*           end *)
      
(*       with *)
(*       extractbytes_to_dvalue (uvs : list uvalue) (dt : dtyp) {struct uvs} : undef_or_err dvalue *)
(*         := dvbs <- concretize_uvalue_bytes uvs;; *)
(*            ErrPoison_to_undef_or_err_dvalue (dvalue_bytes_to_dvalue dvbs dt). *)
(*       Set Guard Checking. *)
(*****************************)
  (* | Concretize_ConcatBytes_Int : *)
  (*     forall bytes sz, *)
  (*       (forall byte, In byte bytes -> exists idx, byte = UVALUE_ExtractByte byte idx) *)
  (*         concretize_u (UVALUE_ConcatBytes bytes (DTYPE_I sz)) *)
  (*         _ *)
  (* . *)

  (* (* The thing that's bothering me... *) *)

  (* (*      Converting to DVALUE destroys information... *) *)

  (* (*      Maybe it doesn't matter, though... *) *)

  (* (*    *) *)

  (* (* May not concretize to anything. Should be a type error *) *)
  (* | Concretize_ExtractByte : *)
  (*     forall byte idx c_byte c_idx, *)
  (*       concretize_u byte c_byte -> *)
  (*       concretize_u idx  c_idx -> *)
  (*       concretize_u (UVALUE_ExtractByte byte idx) *)
  (*                    (c_byte' <- c_byte;; *)
  (*                     c_idx'  <- c_idx;; *)
  (*                     match c_byte' with *)
  (*                     | DVALUE_Addr a => _ *)
  (*                     | DVALUE_I1 x => _ *)
  (*                     | DVALUE_I8 x => _ *)
  (*                     | DVALUE_I32 x => _ *)
  (*                     | DVALUE_I64 x => _ *)
  (*                     | DVALUE_IPTR x => _ *)
  (*                     | DVALUE_Double x => _ *)
  (*                     | DVALUE_Float x => _ *)
  (*                     | DVALUE_Poison => _ *)
  (*                     | DVALUE_None => _ *)
  (*                     | DVALUE_Struct fields => _ *)
  (*                     | DVALUE_Packed_struct fields => _ *)
  (*                     | DVALUE_Array elts => _ *)
  (*                     | DVALUE_Vector elts => _ *)
  (*                     end *)
  (*                    ) *)
  (* | Concretize_ConcatBytes_Int : *)
  (*     forall bytes sz, *)
  (*       concretize_u (UVALUE_ConcatBytes bytes (DTYPE_I sz)) *)
  (*                    (ret DVALUE_None) *)
  .

  Definition concretize (uv: uvalue) (dv : dvalue) := concretize_u uv (ret dv).

  End ConcretizeInductive.
End Make.