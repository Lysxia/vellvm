(* begin hide *)
From Coq Require Import
     List.
Import ListNotations.

From Vellvm Require Import
     Numeric.Coqlib
     Utils.Util
     Utils.Tactics
     Syntax.LLVMAst
     Syntax.CFG
     Syntax.TypToDtyp.

From ExtLib Require Import List.
(* end hide *)

(** * Scoping
    We define through this file several functions and predicates having to do with the scope
    of VIR programs, w.r.t. both block identifiers and local variables.
    We unfortunately inherit from LLVM IR a fully named representation of variables, forcing
    on us fairly heavy sanity checks.
    - [inputs]: input labels of an [ocfg]
    - [outputs]: output labels of an [ocfg]
    - [wf_ocfg_bid]: no duplicate block identifiers


 *)

(** * Well-formedness w.r.t. block identifiers
    An [ocfg] should not admit any collisions w.r.t. to its labels.
 *)
Section LABELS_OPERATIONS.

  Context {T : Set}.

  (** * inputs
     Collect the list of input labels in an open control flow graph.
     Denoting an [ocfg] starting from a label out of this static list
     always results in the identity.
   *)
  Definition inputs (ocfg : @ocfg T) :=
    map blk_id ocfg.

  (** * outputs
     Collect the list of output labels in an open control flow graph.
     Denoting an [ocfg] starting from a label that belongs to its [inputs]
     will always result in a label in the static [output] list, or in a value.
   *)
  Definition terminator_outputs (term : terminator T) : list block_id
    := match term with
       | TERM_Ret v => []
       | TERM_Ret_void => []
       | TERM_Br v br1 br2 => [br1; br2]
       | TERM_Br_1 br => [br]
       | TERM_Switch v default_dest brs => default_dest :: map snd brs
       | TERM_IndirectBr v brs => brs
       | TERM_Resume v => []
       | TERM_Invoke fnptrval args to_label unwind_label => [to_label; unwind_label]

       (** VV: Merging the unreachable constructor, should do nothing? *)
       | TERM_Unreachable => []
       end.

  Definition successors (bk : block T) : list block_id :=
    terminator_outputs (blk_term bk).

  Definition outputs (bks : ocfg T) : list block_id
    := fold_left (fun acc bk => acc ++ successors bk) bks [].

  (** * well-formed
      All labels in an open cfg are distinct.
      Quite natural sanity condition ensuring that despite the representation of
      the open cfg as a list of block, the order of the blocks in this list is
      irrelevant.
   *)
  Definition wf_ocfg_bid (bks : ocfg T) : Prop :=
    list_norepet (inputs bks).

  (** * no reentrance
      Generally speaking, all blocks in an open cfg are mutually recursive,
      we therefore can never discard part of the graph without further assumption.
      We would however still like to capture the idea that two parts of the graph
      represent two distinct computations that are executed in sequence.
      This is expressed by observing that the second sub-graph cannot jump back
      into the first one, i.e. that the [outputs] of the former do not intersect
      with the [inputs] of the latter.

      Under this assumption, the first part of the graph can be safely discarded
      once the second part is reached: cf [DenotationTheory.denote_ocfg_app_no_edges] 
      notably.
   *)
  Definition no_reentrance (bks1 bks2 : ocfg T) : Prop :=
    outputs bks2 ⊍ inputs bks1.

  (** * no_duplicate_bid
      Checks that the inputs of two sub-graphs are disjoint. This condition ensures
      that the well formedness of the two computations entails the one of their join.
   *)
  Definition no_duplicate_bid (bks1 bks2 : ocfg T) : Prop :=
    inputs bks1 ⊍ inputs bks2.

  (** * independent
      While [no_reentrance] captures two sequential computations,
      [independent_flows] captures two completely disjoint sub-graphs.
      This typically allows us to reason in a modular fashion about
      the branches of a conditional.
   *)
  Definition independent_flows (bks1 bks2 : ocfg T) : Prop :=
    no_reentrance bks1 bks2 /\ 
    no_reentrance bks2 bks1 /\
    no_duplicate_bid bks1 bks2.

  Definition free_in_cfg (cfg : ocfg T ) (id : block_id) : Prop :=
    not (In id (inputs cfg)).

End LABELS_OPERATIONS.

Section DEF_SITES_OPERATIONS.

  Context {T : Set}.

  Definition def_sites_instr_id (id : instr_id) : list raw_id :=
    match id with
    | IId id => [id]
    | _ => []
    end.

  Definition def_sites_code (c : code T) : list raw_id :=
    List.fold_left (fun acc '(id,_) => match id with | IId id => id :: acc | _ => acc end) c [].

End DEF_SITES_OPERATIONS.

Section LABELS_THEORY.

  Context {T : Set}.

  Lemma inputs_app: forall (l l' : ocfg T),
      @inputs T (l ++ l') = inputs l ++ inputs l'.
  Proof.
    intros.
    unfold inputs at 1.
    rewrite map_app; auto. 
  Qed.

  Lemma inputs_cons: forall b (l : ocfg T),
      @inputs T (b :: l) = blk_id b :: inputs l.
  Proof.
    intros.
    rewrite list_cons_app, inputs_app; reflexivity.
  Qed.

  Lemma outputs_acc: forall (bks: ocfg T) acc,
      fold_left (fun acc bk => acc ++ successors bk) bks acc =
      acc ++ fold_left (fun acc bk => acc ++ successors bk) bks [].
  Proof.
    induction bks using list_rev_ind; intros; cbn.
    - rewrite app_nil_r; reflexivity.
    - rewrite 2 fold_left_app, IHbks.
      cbn.
      rewrite app_assoc.
      reflexivity.
  Qed.

  Lemma outputs_app: forall (l l' : ocfg T),
      @outputs T (l ++ l') = outputs l ++ outputs l'.
  Proof.
    intros.
    unfold outputs at 1.
    rewrite fold_left_app, outputs_acc.
    reflexivity.
  Qed.

  Lemma outputs_cons: forall b (l : ocfg T),
      @outputs T (b :: l) = successors b ++ outputs l.
  Proof.
    intros.
    rewrite list_cons_app, outputs_app; reflexivity.
  Qed.

  Lemma wf_ocfg_bid_nil:
    wf_ocfg_bid (T := T) []. 
  Proof.
    intros; apply list_norepet_nil.
  Qed.

  Lemma wf_ocfg_bid_cons :
    forall (b : block T) (bs : ocfg T),
      wf_ocfg_bid (b :: bs) ->
      wf_ocfg_bid bs.
  Proof.
    intros * NOREP; inv NOREP; eauto.
  Qed.

  Lemma wf_ocfg_bid_cons_not_in :
    forall (b : block T) (bs : ocfg T),
      wf_ocfg_bid (b :: bs) ->
      not (In (blk_id b) (inputs bs)).
  Proof.
    intros * NOREP; inv NOREP; eauto.
  Qed.

  Lemma wf_ocfg_bid_app_r :
    forall (bs1 bs2 : ocfg T), 
      wf_ocfg_bid (bs1 ++ bs2) ->
      wf_ocfg_bid bs2.
  Proof.
    intros * NR.
    eapply list_norepet_append_right.
    unfold wf_ocfg_bid in NR.
    rewrite inputs_app in NR.
    eauto.
  Qed.

  Lemma wf_ocfg_bid_app_l :
    forall (bs1 bs2 : ocfg T), 
      wf_ocfg_bid (bs1 ++ bs2) ->
      wf_ocfg_bid bs1.
  Proof.
    intros * NR.
    eapply list_norepet_append_left.
    unfold wf_ocfg_bid in NR.
    rewrite inputs_app in NR.
    eauto.
  Qed.

  Lemma blk_id_convert_typ :
    forall env b,
      blk_id (convert_typ env b) = blk_id b.
  Proof.
    intros ? []; reflexivity.
  Qed.

  Lemma inputs_convert_typ : forall σ bks,
      inputs (convert_typ σ bks) = inputs bks.
  Proof.
    induction bks as [| bk bks IH]; cbn; auto.
    f_equal; auto.
  Qed.

  (* TODO: Show symmetric case *)
  Lemma wf_ocfg_bid_app_not_in_l :
    forall id (bs bs' : ocfg T),
      In id (inputs bs) ->
      wf_ocfg_bid (bs' ++ bs) ->
      not (In id (inputs bs')).
  Proof.
    intros. destruct bs.
    inversion H.
    inv H.
    apply wf_ocfg_bid_cons_not_in.
    unfold wf_ocfg_bid in *.
    rewrite inputs_app in H0.
    rewrite inputs_cons. rewrite inputs_cons in H0.
    rewrite list_cons_app in H0.
    rewrite app_assoc in H0.
    apply list_norepet_append_left in H0.
    rewrite list_cons_app.
    rewrite list_norepet_app in *.
    intuition. apply list_disjoint_sym. auto.
    unfold wf_ocfg_bid in H0.
    rewrite inputs_app in H0. rewrite inputs_cons in H0. rewrite list_cons_app in H0.
    apply list_norepet_append_commut in H0. rewrite <- app_assoc in H0.
    apply list_norepet_append_right in H0.
    rewrite list_norepet_app in H0.
    destruct H0 as (? & ? & ?).
    red in H2. intro. eapply H2; eauto.
  Qed.

  (* TODO: Show symmetric case *)
  Lemma wf_ocfg_app_not_in_r :
    forall id (bs bs' : ocfg T),
      In id (inputs bs) ->
      wf_ocfg_bid (bs' ++ bs) ->
      not (In id (inputs bs')).
  Proof.
    intros. destruct bs.
    inversion H.
    inv H.
    apply wf_ocfg_bid_cons_not_in.
    unfold wf_ocfg_bid in *.
    rewrite inputs_app in H0.
    rewrite inputs_cons. rewrite inputs_cons in H0.
    rewrite list_cons_app in H0.
    rewrite app_assoc in H0.
    apply list_norepet_append_left in H0.
    rewrite list_cons_app.
    rewrite list_norepet_app in *.
    intuition. apply list_disjoint_sym. auto.
    unfold wf_ocfg_bid in H0.
    rewrite inputs_app in H0. rewrite inputs_cons in H0. rewrite list_cons_app in H0.
    apply list_norepet_append_commut in H0. rewrite <- app_assoc in H0.
    apply list_norepet_append_right in H0.
    rewrite list_norepet_app in H0.
    destruct H0 as (? & ? & ?).
    red in H2. intro. eapply H2; eauto.
  Qed.

  Lemma In_bk_outputs: forall bid br (b: block T) (l : ocfg T),
      In br (successors b) ->
      find_block l bid = Some b ->
      In br (outputs l). 
  Proof.
    induction l as [| ? l IH].
    - cbn; intros ? abs; inv abs.
    - intros IN FIND.
      cbn in FIND.
      flatten_hyp FIND; inv FIND.
      + flatten_hyp Heq; inv Heq.
        rewrite outputs_cons.
        apply in_or_app; left; auto.
      + flatten_hyp Heq; inv Heq. 
        rewrite outputs_cons.
        apply in_or_app; right.
        auto.
  Qed.

  Lemma find_block_in_inputs :
    forall {T} to (bks : ocfg T),
      In to (inputs bks) ->
      exists bk, find_block bks to = Some bk.
  Proof.
    induction bks as [| id ocfg IH]; cbn; intros IN; [inv IN |].
    flatten_goal; flatten_hyp Heq; intuition; eauto.
  Qed.

  Lemma no_reentrance_not_in (bks1 bks2 : ocfg T) :
    no_reentrance bks1 bks2 ->
    forall x, In x (outputs bks2) -> ~ In x (inputs bks1).
  Proof.
    intros; eauto using Coqlib.list_disjoint_notin.
  Qed.

  Lemma no_reentrance_app_l :
    forall (bks1 bks1' bks2 : ocfg T),
      no_reentrance (bks1 ++ bks1') bks2 <->
      no_reentrance bks1 bks2 /\ no_reentrance bks1' bks2.
  Proof.
    intros; unfold no_reentrance; split; [intros H | intros [H1 H2]].
    - rewrite inputs_app, list_disjoint_app_r in H; auto.
    - rewrite inputs_app, list_disjoint_app_r; auto.
  Qed.

  Lemma no_reentrance_app_r :
    forall (bks1 bks2 bks2' : ocfg T),
      no_reentrance bks1 (bks2 ++ bks2')%list <->
      no_reentrance bks1 bks2 /\ no_reentrance bks1 bks2'.
  Proof.
    intros; unfold no_reentrance; split; [intros H | intros [H1 H2]].
    - rewrite outputs_app,list_disjoint_app_l in H; auto.
    - rewrite outputs_app, list_disjoint_app_l; auto.
  Qed.

  Lemma no_duplicate_bid_not_in_l (bks1 bks2 : ocfg T) :
    no_duplicate_bid bks1 bks2 ->
    forall x, In x (inputs bks2) -> ~ In x (inputs bks1).
  Proof.
    intros; eauto using Coqlib.list_disjoint_notin, Coqlib.list_disjoint_sym.
  Qed.

  Lemma no_duplicate_bid_not_in_r (bks1 bks2 : ocfg T) :
    no_duplicate_bid bks1 bks2 ->
    forall x, In x (inputs bks1) -> ~ In x (inputs bks2).
  Proof.
    intros; eauto using Coqlib.list_disjoint_notin, Coqlib.list_disjoint_sym.
  Qed.

  Lemma independent_flows_no_reentrance_l (bks1 bks2 : ocfg T):
    independent_flows bks1 bks2 ->
    no_reentrance bks1 bks2.
  Proof.
    intros INDEP; apply INDEP; auto.
  Qed.

  Lemma independent_flows_no_reentrance_r (bks1 bks2 : ocfg T):
    independent_flows bks1 bks2 ->
    no_reentrance bks2 bks1.
  Proof.
    intros INDEP; apply INDEP; auto.
  Qed.

  Lemma independent_flows_no_duplicate_bid (bks1 bks2 : ocfg T):
    independent_flows bks1 bks2 ->
    no_duplicate_bid bks1 bks2.
  Proof.
    intros INDEP; apply INDEP; auto.
  Qed.

  Lemma find_block_not_in_inputs:
    forall bid (l : ocfg T),
      ~ In bid (inputs l) ->
      find_block l bid = None.
  Proof.
    induction l as [| bk l IH]; intros NIN; auto.
    cbn.
    flatten_goal.
    - exfalso.
      flatten_hyp Heq; [| inv Heq].
      apply NIN.
      left; rewrite e; reflexivity.
    - flatten_hyp Heq; [inv Heq |].
      apply IH.
      intros abs; apply NIN.
      right; auto.
  Qed.

  Lemma wf_ocfg_bid_singleton : forall (b : _ T), wf_ocfg_bid [b].
  Proof.
    intros.
    red.
    eapply list_norepet_cons; eauto.
    eapply list_norepet_nil.
  Qed.

  Lemma wf_ocfg_bid_cons' : forall (b : _ T) (bks : ocfg T),
      not (In (blk_id b) (inputs bks)) ->
      wf_ocfg_bid bks ->
      wf_ocfg_bid (b :: bks).
  Proof.
    intros.
    eapply list_norepet_cons; eauto.
  Qed.

  Lemma free_in_cfg_app : forall (bks1 bks2 : ocfg T) b,
      free_in_cfg (bks1 ++ bks2) b <->
      (free_in_cfg bks1 b /\ free_in_cfg bks2 b).
  Proof.
    intros; split; unfold free_in_cfg; intro FREE.
    - split; intros abs; eapply FREE; rewrite inputs_app; eauto using in_or_app. 
    - rewrite inputs_app; intros abs; apply in_app_or in abs; destruct FREE as [FREEL FREER]; destruct abs; [eapply FREEL | eapply FREER]; eauto.
  Qed.

  Lemma wf_ocfg_bid_distinct_labels :
    forall (bks1 bks2 : ocfg T) b1 b2,
      wf_ocfg_bid (bks1 ++ bks2) ->
      In b1 (inputs bks1) ->
      In b2 (inputs bks2) ->
      b1 <> b2.
  Proof.
    intros * WF IN1 IN2.
    eapply wf_ocfg_bid_app_not_in_l in IN2; eauto.
    destruct (Eqv.eqv_dec_p b1 b2).
    rewrite e in IN1; contradiction IN2; auto.
    auto.
  Qed.

End LABELS_THEORY.

Section FIND_BLOCK.

  Context {T : Set}.

  Lemma find_block_app_r_wf :
    forall (x : block_id) (b : block T) (bs1 bs2 : ocfg T),
      wf_ocfg_bid (bs1 ++ bs2)  ->
      find_block bs2 x = Some b ->
      find_block (bs1 ++ bs2) x = Some b.
  Proof.
    intros x b; induction bs1 as [| hd bs1 IH]; intros * NOREP FIND.
    - rewrite app_nil_l; auto.
    - cbn; break_inner_match_goal.
      + cbn in NOREP; apply wf_ocfg_bid_cons_not_in in NOREP. 
        exfalso; apply NOREP.
        rewrite e.
        apply find_some in FIND as [FIND EQ].
        clear - FIND EQ. 
        rewrite inputs_app; eapply in_or_app; right.
        break_match; [| intuition].
        rewrite <- e.
        eapply in_map; auto.
      + cbn in NOREP; apply wf_ocfg_bid_cons in NOREP.
        apply IH; eauto.
  Qed.

  Lemma find_block_app_l_wf :
    forall (x : block_id) (b : block T) (bs1 bs2 : ocfg T),
      wf_ocfg_bid (bs1 ++ bs2)  ->
      find_block bs1 x = Some b ->
      find_block (bs1 ++ bs2) x = Some b.
  Proof.
    intros x b; induction bs1 as [| hd bs1 IH]; intros * NOREP FIND.
    - inv FIND.
    - cbn in FIND |- *.
      break_inner_match; auto.
      apply IH; eauto.
      eapply wf_ocfg_bid_cons, NOREP.
  Qed.

  Lemma find_block_tail_wf :
    forall (x : block_id) (b b' : block T) (bs : ocfg T),
      wf_ocfg_bid (b :: bs)  ->
      find_block bs x = Some b' ->
      find_block (b :: bs) x = Some b'.
  Proof.
    intros.
    rewrite list_cons_app.
    apply find_block_app_r_wf; auto.
  Qed.

  Lemma free_in_cfg_cons:
    forall b (bs : ocfg T) id,
      free_in_cfg (b::bs) id ->
      free_in_cfg bs id .
  Proof.
    intros * FR abs; apply FR; cbn.
    destruct (Eqv.eqv_dec_p (blk_id b) id); [rewrite e; auto | right; auto].
  Qed.

  Lemma find_block_free_id :
    forall (cfg : ocfg T) id,
      free_in_cfg cfg id ->
      find_block cfg id = None.
  Proof.
    induction cfg as [| b bs IH]; cbn; intros * FREE; auto.
    break_inner_match_goal.
    + exfalso; eapply FREE.
      cbn; rewrite e; auto.
    + apply IH.
      apply free_in_cfg_cons in FREE; auto.
  Qed.

  Lemma find_block_nil:
    forall b,
      @find_block T [] b = None.
  Proof.
    reflexivity.
  Qed.

  Lemma find_block_eq:
    forall x (b : block T) (bs : ocfg T),
      blk_id b = x ->
      find_block (b:: bs) x = Some b.
  Proof.
    intros; cbn.
    rewrite H.
    destruct (Eqv.eqv_dec_p x x).
    reflexivity.
    contradiction n; reflexivity.
  Qed.

  Lemma find_block_ineq: 
    forall x (b : block T) (bs : ocfg T),
      blk_id b <> x ->
      find_block (b::bs) x = find_block bs x. 
  Proof.
    intros; cbn.
    destruct (Eqv.eqv_dec_p (blk_id b)) as [EQ | INEQ].
    unfold Eqv.eqv, AstLib.eqv_raw_id in *; intuition.
    reflexivity.
  Qed.

  Lemma find_block_none_app:
    forall (bks1 bks2 : ocfg T) bid,
      find_block bks1 bid = None ->
      find_block (bks1 ++ bks2) bid = find_block bks2 bid.
  Proof.
    intros; apply find_none_app; auto.
  Qed.

  Lemma find_block_some_app:
    forall (bks1 bks2 : ocfg T) (bk : block T) bid,
      find_block bks1 bid = Some bk ->
      find_block (bks1 ++ bks2) bid = Some bk.
  Proof.
    intros; apply find_some_app; auto.
  Qed.

  Lemma find_block_Some_In_inputs : forall (bks : ocfg T) b bk,
      find_block bks b = Some bk ->
      In b (inputs bks).
  Proof.
    induction bks as [| hd bks IH].
    - intros * H; inv H.
    - intros * FIND.
      destruct (Eqv.eqv_dec_p (blk_id hd) b).
      cbn; rewrite e; auto.
      right; eapply IH.
      erewrite <- find_block_ineq; eauto. 
  Qed.

  Lemma wf_ocfg_bid_find_None_app_l :
    forall (bks1 bks2 : ocfg T) b bk,
      wf_ocfg_bid (bks1 ++ bks2)%list ->
      find_block bks2 b = Some bk ->
      find_block bks1 b = None.
  Proof.
    induction bks1 as [| b bks1 IH]; intros * WF FIND.
    reflexivity.
    destruct (Eqv.eqv_dec_p (blk_id b) b0).
    - exfalso.
      cbn in WF; eapply wf_ocfg_bid_cons_not_in in WF.
      apply WF.
      rewrite inputs_app. 
      apply in_or_app; right.
      rewrite e.
      apply find_block_Some_In_inputs in FIND; auto.
    - rewrite find_block_ineq; auto.
      eapply IH; eauto using wf_ocfg_bid_cons.
  Qed.    

End FIND_BLOCK.

From Vellvm Require Import Syntax.TypToDtyp.

Section DTyp.

  Lemma convert_typ_terminator_outputs : forall t,
    terminator_outputs (convert_typ [] t) = terminator_outputs t.
  Proof.
    intros []; cbn; try reflexivity.
    - induction brs as [| [τ i] brs IH]; cbn; auto.
      do 2 f_equal.
      inv IH; auto.
    - induction brs; cbn; auto; f_equal; auto. 
  Qed. 

  Lemma convert_typ_outputs : forall (bks : ocfg typ),
      outputs (convert_typ [] bks) = outputs bks.
  Proof.
    induction bks as [| bk bks IH]; [reflexivity |].
    unfold convert_typ.
    simpl ConvertTyp_list.
    rewrite !outputs_cons, <- IH.
    f_equal.
    destruct bk; cbn.
    unfold successors.
    rewrite <- convert_typ_terminator_outputs.
    reflexivity.
  Qed.

  Lemma inputs_convert_typ : forall env bs,
      inputs (convert_typ env bs) = inputs bs.
  Proof.
    induction bs as [| b bs IH]; cbn; auto.
    f_equal; auto.
  Qed.

  Lemma wf_ocfg_bid_convert_typ :
    forall env (bs : ocfg typ),
      wf_ocfg_bid bs ->
      wf_ocfg_bid (convert_typ env bs).
  Proof.
    induction bs as [| b bs IH].
    - cbn; auto.
    - intros NOREP.
      change (wf_ocfg_bid (convert_typ env b :: convert_typ env bs)).
      apply list_norepet_cons.
      + apply wf_ocfg_bid_cons_not_in in NOREP.
        cbn. 
        rewrite inputs_convert_typ; auto.
      + eapply IH, wf_ocfg_bid_cons; eauto.
  Qed.

End DTyp. 
