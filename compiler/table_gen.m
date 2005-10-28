%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1997-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Main authors: zs, ohutch.
%
% This module transforms HLDS code to implement loop detection, memoing,
% minimal model evaluation, or I/O idempotence. The transformation involves
% adding calls to predicates defined in library/table_builtin.m and in
% runtime/mercury_minimal_model.c.
%
% The loop detection transformation adds code to a procedure that allows
% early detection of infinite loops. If such loops are detected the program
% will terminate with a helpful error message.
%
% The memo transformation adds code that allows a procedure to "memo"
% (remember) answers once they have been generated using program clause
% resolution.
%
% The minimal model transformation changes the semantics of the procedure
% being transformed. See the PhD thesis of K. Sagonas: `The SLG-WAM: A
% Search-Efficient Engine for Well-Founded Evaluation of Normal Logic
% Programs' from SUNY at Stony Brook in 1996 for a description of
% the semantics behind the transformation. Currently only SLGd is
% implemented.
%
% The current implementation attempts to detect cases where tabling has
% undesirable interactions with if-then-else, solutions, and (possibly)
% negated contexts in general. However, the detection is done at runtime,
% since there is no known way of doing this compile time.

%-----------------------------------------------------------------------------%

:- module transform_hlds__table_gen.

:- interface.

:- import_module hlds.hlds_module.

:- import_module io.

:- pred table_gen__process_module(module_info::in, module_info::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.
:- import_module backend_libs.rtti.
:- import_module check_hlds.det_analysis.
:- import_module check_hlds.inst_match.
:- import_module check_hlds.modes.
:- import_module check_hlds.mode_util.
:- import_module check_hlds.polymorphism.
:- import_module check_hlds.purity.
:- import_module check_hlds.type_util.
:- import_module hlds.code_model.
:- import_module hlds.goal_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_error_util.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_out.
:- import_module hlds.hlds_pred.
:- import_module hlds.instmap.
:- import_module hlds.passes_aux.
:- import_module hlds.quantification.
:- import_module libs.compiler_util.
:- import_module libs.globals.
:- import_module libs.options.
:- import_module ll_backend.
:- import_module ll_backend.continuation_info.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.error_util.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_mode.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.prog_util.
:- import_module transform_hlds.const_prop.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module require.
:- import_module set.
:- import_module std_util.
:- import_module string.
:- import_module term.
:- import_module varset.

%-----------------------------------------------------------------------------%

    % Values of this type map the pred_id of a minimal_model tabled
    % predicate to the pred_id of its generator variant.
    %
:- type generator_map   ==  map(pred_id, pred_id).

    % NOTE: following preds seem to duplicate the code in passes_aux.m.
    % The reason for this duplication is that this module needs a variant
    % of this code that is able to handle passing a module_info to
    % polymorphism and getting an updated module_info back.
    %
table_gen__process_module(!ModuleInfo, !IO) :-
    module_info_preds(!.ModuleInfo, Preds0),
    map__keys(Preds0, PredIds),
    map__init(GenMap0),
    table_gen__process_preds(PredIds, !ModuleInfo, GenMap0, _, !IO).

:- pred table_gen__process_preds(list(pred_id)::in,
    module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__process_preds([], !ModuleInfo, !GenMap, !IO).
table_gen__process_preds([PredId | PredIds], !ModuleInfo, !GenMap, !IO) :-
    table_gen__process_pred(PredId, !ModuleInfo, !GenMap, !IO),
    table_gen__process_preds(PredIds, !ModuleInfo, !GenMap, !IO).

:- pred table_gen__process_pred(pred_id::in, module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__process_pred(PredId, !ModuleInfo, !GenMap, !IO) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    ProcIds = pred_info_procids(PredInfo),
    table_gen__process_procs(PredId, ProcIds, !ModuleInfo, !GenMap, !IO).

:- pred table_gen__process_procs(pred_id::in, list(proc_id)::in,
    module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__process_procs(_PredId, [], !ModuleInfo, !GenMap, !IO).
table_gen__process_procs(PredId, [ProcId | ProcIds], !ModuleInfo, !GenMap,
        !IO) :-
    module_info_preds(!.ModuleInfo, PredTable),
    map__lookup(PredTable, PredId, PredInfo),
    pred_info_procedures(PredInfo, ProcTable),
    map__lookup(ProcTable, ProcId, ProcInfo0),
    table_gen__process_proc(PredId, ProcId, ProcInfo0, PredInfo,
        !ModuleInfo, !GenMap, !IO),
    table_gen__process_procs(PredId, ProcIds, !ModuleInfo, !GenMap, !IO).

:- pred table_gen__process_proc(pred_id::in, proc_id::in, proc_info::in,
    pred_info::in, module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__process_proc(PredId, ProcId, ProcInfo0, PredInfo0, !ModuleInfo,
        !GenMap, !IO) :-
    proc_info_eval_method(ProcInfo0, EvalMethod),
    ( eval_method_requires_tabling_transform(EvalMethod) = yes ->
        table_gen__transform_proc_if_possible(EvalMethod, PredId,
            ProcId, ProcInfo0, _, PredInfo0, _, !ModuleInfo, !GenMap, !IO)
    ;
        module_info_get_globals(!.ModuleInfo, Globals),
        globals__lookup_bool_option(Globals, trace_table_io, yes),
        proc_info_has_io_state_pair(!.ModuleInfo, ProcInfo0,
            _InArgNum, _OutArgNum)
    ->
        proc_info_interface_code_model(ProcInfo0, CodeModel),
        ( CodeModel = model_det ->
            true
        ;
            pred_id_to_int(PredId, PredIdInt),
            Msg = string__format("I/O procedure pred id %d not model_det",
                [i(PredIdInt)]),
            unexpected(this_file, Msg)
        ),
        globals__lookup_bool_option(Globals, trace_table_io_all, TransformAll),
        globals__lookup_bool_option(Globals, trace_table_io_require, Require),
        proc_info_goal(ProcInfo0, BodyGoal),
        predicate_module(!.ModuleInfo, PredId, PredModuleName),
        should_io_procedure_be_transformed(TransformAll, Require, BodyGoal,
            PredModuleName, AnnotationIsMissing, TransformPrimitive),
        (
            AnnotationIsMissing = yes,
            report_missing_tabled_for_io(!.ModuleInfo, PredInfo0,
                PredId, ProcId, !IO),
            module_info_incr_errors(!ModuleInfo)
        ;
            AnnotationIsMissing = no
        ),
        (
            TransformPrimitive = no
        ;
            TransformPrimitive = yes(Unitize),
            globals__lookup_bool_option(Globals, trace_table_io_only_retry,
                TraceTableIoOnlyRetry),
            (
                TraceTableIoOnlyRetry = no,
                Decl = table_io_decl
            ;
                TraceTableIoOnlyRetry = yes,
                Decl = table_io_proc
            ),
            TableIoMethod = eval_table_io(Decl, Unitize),
            proc_info_set_eval_method(TableIoMethod, ProcInfo0, ProcInfo1),
            table_gen__transform_proc_if_possible(TableIoMethod,
                PredId, ProcId, ProcInfo1, _, PredInfo0, _, !ModuleInfo,
                !GenMap, !IO)
        )
    ;
        true
    ).

%-----------------------------------------------------------------------------%

:- pred should_io_procedure_be_transformed(bool::in, bool::in, hlds_goal::in,
    sym_name::in, bool::out, maybe(table_io_is_unitize)::out) is det.

should_io_procedure_be_transformed(TransformAll, Require, BodyGoal,
        PredModuleName, AnnotationIsMissing, TransformInfo) :-
    tabled_for_io_attributes(BodyGoal, TabledForIoAttrs),
    (
        TabledForIoAttrs = [],
        AnnotationIsMissing = no,
        TransformInfo = no
    ;
        TabledForIoAttrs = [TabledForIoAttr],
        (
            TabledForIoAttr = not_tabled_for_io,
            (
                Require = yes,
                \+ any_mercury_builtin_module(PredModuleName)
            ->
                AnnotationIsMissing = yes,
                TransformInfo = no
            ;
                AnnotationIsMissing = no,
                (
                    TransformAll = no,
                    TransformInfo = no
                ;
                    TransformAll = yes,
                    may_call_mercury_attributes(BodyGoal, MayCallMercuryAttrs),
                    (
                        MayCallMercuryAttrs = [may_call_mercury]
                    ->
                        TransformInfo = no
                    ;
                        TransformInfo = yes(table_io_alone)
                    )
                )
            )
        ;
            TabledForIoAttr = tabled_for_descendant_io,
            AnnotationIsMissing = no,
            % The procedure itself doesn't do any I/O, so don't transform it.
            TransformInfo = no
        ;
            TabledForIoAttr = tabled_for_io,
            AnnotationIsMissing = no,
            TransformInfo = yes(table_io_alone)
        ;
            TabledForIoAttr = tabled_for_io_unitize,
            AnnotationIsMissing = no,
            TransformInfo = yes(table_io_unitize)
        )
    ;
        TabledForIoAttrs = [_, _ | _],
        % Since table_gen is run before inlining, each procedure
        % should contain at most one foreign_proc goal.
        unexpected(this_file, "should_io_procedure_be_transformed: " ++
            "different tabled_for_io attributes in one procedure")
    ).

:- pred may_call_mercury_attributes(hlds_goal::in, list(may_call_mercury)::out)
    is det.

may_call_mercury_attributes(Goal, MayCallMercuryAttrs) :-
    solutions(subgoal_may_call_mercury_attribute(Goal), MayCallMercuryAttrs).

:- pred subgoal_may_call_mercury_attribute(hlds_goal::in,
    may_call_mercury::out) is nondet.

subgoal_may_call_mercury_attribute(Goal, MayCallMercuryAttr) :-
    some [SubGoal, Attrs] (
        goal_contains_goal(Goal, SubGoal),
        SubGoal = foreign_proc(Attrs, _, _, _, _, _) - _,
        MayCallMercuryAttr = may_call_mercury(Attrs)
    ).

:- pred tabled_for_io_attributes(hlds_goal::in, list(tabled_for_io)::out)
    is det.

tabled_for_io_attributes(Goal, TabledForIoAttrs) :-
    solutions(subgoal_tabled_for_io_attribute(Goal), TabledForIoAttrs).

:- pred subgoal_tabled_for_io_attribute(hlds_goal::in, tabled_for_io::out)
    is nondet.

subgoal_tabled_for_io_attribute(Goal, TabledForIoAttr) :-
    some [SubGoal, Attrs] (
        goal_contains_goal(Goal, SubGoal),
        SubGoal = foreign_proc(Attrs, _, _, _, _, _) - _,
        TabledForIoAttr = tabled_for_io(Attrs),
        \+ TabledForIoAttr = not_tabled_for_io
    ).

:- pred report_missing_tabled_for_io(module_info::in, pred_info::in,
    pred_id::in, proc_id::in, io::di, io::uo) is det.

report_missing_tabled_for_io(ModuleInfo, PredInfo, PredId, ProcId, !IO) :-
    pred_info_context(PredInfo, Context),
    ProcPieces = describe_one_proc_name(ModuleInfo, should_module_qualify,
        proc(PredId, ProcId)),
    Msg = ProcPieces ++ [words("contains untabled I/O primitive.")],
    error_util__write_error_pieces(Context, 0, Msg, !IO).

:- pred report_bad_mode_for_tabling(module_info::in, pred_info::in,
    pred_id::in, proc_id::in, prog_varset::in, list(prog_var)::in,
    io::di, io::uo) is det.

report_bad_mode_for_tabling(ModuleInfo, PredInfo, PredId, ProcId, VarSet, Vars,
        !IO) :-
    pred_info_context(PredInfo, Context),
    ProcPieces = describe_one_proc_name(ModuleInfo, should_module_qualify,
        proc(PredId, ProcId)),
    lookup_var_names(VarSet, Vars, VarNames),
    Msg = ProcPieces ++ [words("contains arguments"),
        words("whose mode is incompatible with tabling;"), nl,
        words("these arguments are"), words(VarNames)],
    error_util__write_error_pieces(Context, 0, Msg, !IO).

:- pred lookup_var_names(prog_varset::in, list(prog_var)::in, string::out)
    is det.

lookup_var_names(_, [], "").
lookup_var_names(VarSet, [Var | Vars], Description) :-
    varset__lookup_name(VarSet, Var, Name),
    (
        Vars = [],
        Description = Name
    ;
        Vars = [_ | _],
        lookup_var_names(VarSet, Vars, Description0),
        Description = Name ++ ", " ++ Description0
    ).

%-----------------------------------------------------------------------------%

:- pred table_gen__transform_proc_if_possible(eval_method::in,
    pred_id::in, proc_id::in, proc_info::in, proc_info::out,
    pred_info::in, pred_info::out, module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__transform_proc_if_possible(EvalMethod, PredId, ProcId,
        !ProcInfo, !PredInfo, !ModuleInfo, !GenMap, !IO) :-
    globals__io_get_target(Target, !IO),
    globals__io_get_gc_method(GC_Method, !IO),
    ( Target = c, GC_Method \= accurate ->
        table_gen__transform_proc(EvalMethod, PredId, ProcId,
            !ProcInfo, !PredInfo, !ModuleInfo, !GenMap, !IO)
    ;
        % We don't want to increment the error count, since that
        % would combine with --halt-at-warn to prevent the clean
        % compilation of the library.

        pred_info_context(!.PredInfo, Context),
        ProcPieces = describe_one_proc_name(!.ModuleInfo,
            should_module_qualify, proc(PredId, ProcId)),
        EvalMethodStr = eval_method_to_one_string(EvalMethod),
        Msg = [words("Ignoring the pragma"), fixed(EvalMethodStr),
            words("for")] ++ ProcPieces ++
            [words("due to lack of support on this back end."), nl],
        error_util__write_error_pieces(Context, 0, Msg, !IO),
        %
        % XXX We set the evaluation method to eval_normal here to prevent
        % problems in the ml code generator if we are compiling in a grade
        % that does not support tabling. (See ml_gen_maybe_add_table_var/6
        % in ml_code_gen.m for further details.)
        %
        % We do this here rather than when processing the tabling pragmas
        % (in add_pragma.m) so that we can still generate error message
        % for misuses of the tabling pragmas.
        %
        proc_info_set_eval_method(eval_normal, !ProcInfo),
        module_info_set_pred_proc_info(PredId, ProcId, !.PredInfo,
            !.ProcInfo, !ModuleInfo)
    ).

:- pred table_gen__transform_proc(eval_method::in, pred_id::in, proc_id::in,
    proc_info::in, proc_info::out, pred_info::in, pred_info::out,
    module_info::in, module_info::out,
    generator_map::in, generator_map::out, io::di, io::uo) is det.

table_gen__transform_proc(EvalMethod, PredId, ProcId, !ProcInfo, !PredInfo,
        !ModuleInfo, !GenMap, !IO) :-
    table_info_init(!.ModuleInfo, !.PredInfo, !.ProcInfo, TableInfo0),

    % grab the appropriate fields from the pred_info and proc_info
    proc_info_interface_determinism(!.ProcInfo, Detism),
    determinism_to_code_model(Detism, CodeModel),
    proc_info_headvars(!.ProcInfo, HeadVars),
    proc_info_varset(!.ProcInfo, VarSet0),
    proc_info_vartypes(!.ProcInfo, VarTypes0),
    proc_info_goal(!.ProcInfo, OrigGoal),
    proc_info_argmodes(!.ProcInfo, ArgModes),

    (
        EvalMethod = eval_normal,
        % This should have been caught by our caller.
        unexpected(this_file, "table_gen__transform_proc: eval_normal")
    ;
        EvalMethod = eval_table_io(_, _),
        % Since we don't actually create a call table for I/O tabled
        % procedures, the value of MaybeSpecMethod doesn't really matter.
        MaybeSpecMethod = all_same(arg_value)
    ;
        EvalMethod = eval_loop_check,
        MaybeSpecMethod = all_same(arg_value)
    ;
        EvalMethod = eval_memo(CallStrictness),
        (
            CallStrictness = all_strict,
            MaybeSpecMethod = all_same(arg_value)
        ;
            CallStrictness = all_fast_loose,
            MaybeSpecMethod = all_same(arg_addr)
        ;
            CallStrictness = specified(ArgMethods),
            MaybeSpecMethod = specified(ArgMethods)
        )
    ;
        EvalMethod = eval_minimal(_),
        MaybeSpecMethod = all_same(arg_value)
    ),
    get_input_output_vars(HeadVars, ArgModes, !.ModuleInfo, MaybeSpecMethod, _,
        InputVarModeMethods, OutputVarModeMethods),
    allocate_slot_numbers(InputVarModeMethods, 0, NumberedInputVars),
    allocate_slot_numbers(OutputVarModeMethods, 0, NumberedOutputVars),
    tabling_via_extra_args(!.ModuleInfo, TablingViaExtraArgs),
    % The case EvalMethod = eval_normal was caught by the code above.
    (
        EvalMethod = eval_table_io(Decl, Unitize),
        module_info_get_globals(!.ModuleInfo, Globals),
        globals__lookup_bool_option(Globals, trace_table_io_states,
            TableIoStates),
        assoc_list__from_corresponding_lists(HeadVars, ArgModes, HeadVarModes),
        table_gen__create_new_io_goal(OrigGoal, Decl, Unitize,
            TableIoStates, PredId, ProcId, TablingViaExtraArgs,
            HeadVarModes, NumberedInputVars, NumberedOutputVars,
            VarTypes0, VarTypes, VarSet0, VarSet,
            TableInfo0, TableInfo, Goal, MaybeProcTableInfo),
        MaybeCallTableTip = no
    ;
        EvalMethod = eval_loop_check,
        table_gen__create_new_loop_goal(Detism, OrigGoal, PredId, ProcId,
            TablingViaExtraArgs, HeadVars,
            NumberedInputVars, NumberedOutputVars,
            VarTypes0, VarTypes, VarSet0, VarSet,
            TableInfo0, TableInfo, CallTableTip, Goal, Steps),
        generate_gen_proc_table_info(TableInfo, Steps,
            InputVarModeMethods, OutputVarModeMethods, ProcTableInfo),
        MaybeCallTableTip = yes(CallTableTip),
        MaybeProcTableInfo = yes(ProcTableInfo)
    ;
        EvalMethod = eval_memo(_CallStrictness),
        ( CodeModel = model_non ->
            table_gen__create_new_memo_non_goal(Detism,
                OrigGoal, PredId, ProcId, HeadVars,
                NumberedInputVars, NumberedOutputVars,
                VarTypes0, VarTypes, VarSet0, VarSet, TableInfo0, TableInfo,
                CallTableTip, Goal, Steps)
        ;
            table_gen__create_new_memo_goal(Detism,
                OrigGoal, PredId, ProcId, TablingViaExtraArgs,
                HeadVars, NumberedInputVars, NumberedOutputVars,
                VarTypes0, VarTypes, VarSet0, VarSet,
                TableInfo0, TableInfo, CallTableTip, Goal, Steps)
        ),
        generate_gen_proc_table_info(TableInfo, Steps,
            InputVarModeMethods, OutputVarModeMethods, ProcTableInfo),
        MaybeCallTableTip = yes(CallTableTip),
        MaybeProcTableInfo = yes(ProcTableInfo)
    ;
        EvalMethod = eval_minimal(MinimalMethod),
        (
            CodeModel = model_det,
            unexpected(this_file, "table_gen__transform_proc: minimal det")
        ;
            CodeModel = model_semi,
            unexpected(this_file, "table_gen__transform_proc: minimal semi")
        ;
            CodeModel = model_non,
            MinimalMethod = stack_copy,
            table_gen__create_new_mm_goal(Detism, OrigGoal,
                PredId, ProcId, TablingViaExtraArgs,
                HeadVars, NumberedInputVars, NumberedOutputVars,
                VarTypes0, VarTypes, VarSet0, VarSet,
                TableInfo0, TableInfo, CallTableTip, Goal, Steps),
            MaybeCallTableTip = yes(CallTableTip)
        ;
            CodeModel = model_non,
            MinimalMethod = own_stacks,
            table_gen__do_own_stack_transform(Detism, OrigGoal,
                PredId, ProcId, !.PredInfo, !.ProcInfo,
                HeadVars, NumberedInputVars, NumberedOutputVars,
                VarTypes0, VarTypes, VarSet0, VarSet,
                TableInfo0, TableInfo, !GenMap, Goal, Steps),
            MaybeCallTableTip = no
        ),
        generate_gen_proc_table_info(TableInfo, Steps,
            InputVarModeMethods, OutputVarModeMethods, ProcTableInfo),
        MaybeProcTableInfo = yes(ProcTableInfo)
    ),

    table_info_extract(TableInfo, !:ModuleInfo, !:PredInfo, !:ProcInfo),

    % set the new values of the fields in proc_info and pred_info
    % and save in the module info
    proc_info_set_goal(Goal, !ProcInfo),
    proc_info_set_varset(VarSet, !ProcInfo),
    proc_info_set_vartypes(VarTypes, !ProcInfo),
    proc_info_set_call_table_tip(MaybeCallTableTip, !ProcInfo),
    proc_info_set_maybe_proc_table_info(MaybeProcTableInfo, !ProcInfo),

    % Some of the instmap_deltas generated in this module
    % are pretty dodgy (especially those for if-then-elses), so
    % recompute them here.
    RecomputeAtomic = no,
    recompute_instmap_delta_proc(RecomputeAtomic, !ProcInfo, !ModuleInfo),

    pred_info_procedures(!.PredInfo, ProcTable1),
    map__det_update(ProcTable1, ProcId, !.ProcInfo, ProcTable),
    pred_info_set_procedures(ProcTable, !PredInfo),

    % The transformation doesn't pay attention to the purity
    % of compound goals, so recompute the purity here.
    repuritycheck_proc(!.ModuleInfo, proc(PredId, ProcId), !PredInfo),
    module_info_preds(!.ModuleInfo, PredTable1),
    map__det_update(PredTable1, PredId, !.PredInfo, PredTable),
    module_info_set_preds(PredTable, !ModuleInfo).

%-----------------------------------------------------------------------------%

% Example of transformation for model_det loopcheck:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   T0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(T0, A, T),
%   impure table_loop_setup(T, Status),
%   (
%       Status = loop_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = loop_inactive,
%       % status has been changed to active by the setup predicate
%       <original code>,
%       impure table_loop_mark_as_inactive(T)
%   ).
%
% Example of transformation for model_semi loopcheck:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   T0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(T0, A, T),
%   impure table_loop_setup(T, Status),
%   (
%       Status = loop_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = loop_inactive,
%       % status has been changed to active by the setup predicate
%       (if
%           <original code>, with B replaced by C
%       then
%           B = C,
%           impure table_loop_mark_as_inactive(T)
%       else
%           impure table_loop_mark_as_inactive_and_fail(T),
%       )
%   ).
%
% Example of transformation for model_non loopcheck:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   T0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(T0, A, T),
%   impure table_loop_setup(T, Status),
%   (
%       Status = loop_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = loop_inactive,
%       % status has been changed to active by the setup predicate
%       (
%           <original code>,
%           (
%               impure table_loop_mark_as_inactive(T)
%           ;
%               impure table_loop_mark_as_active_and_fail(T),
%               fail
%           )
%       ;
%           impure table_loop_mark_as_inactive_and_fail(T)
%       )
%   ).

:- pred create_new_loop_goal(determinism::in, hlds_goal::in,
    pred_id::in, proc_id::in, bool::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, hlds_goal::out,
    list(table_trie_step)::out) is det.

create_new_loop_goal(Detism, OrigGoal, PredId, ProcId, TablingViaExtraArgs,
        HeadVars, NumberedInputVars, NumberedOutputVars, !VarTypes, !VarSet,
        !TableInfo, TableTipVar, Goal, Steps) :-
    % Even if the original goal doesn't use all of the headvars,
    % the code generated by the tabling transformation does,
    % so we need to compute the nonlocals from the headvars rather
    % than getting it from the nonlocals field in the original goal.
    set__list_to_set(HeadVars, OrigNonLocals),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    goal_info_get_context(OrigGoalInfo, Context),

    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_simple_call_table_lookup_goal(loop_status_type,
        "table_loop_setup", NumberedInputVars, PredId, ProcId,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        TableTipVar, StatusVar, LookUpGoal, Steps),

    generate_error_goal(!.TableInfo, Context, infinite_recursion_msg,
        !VarTypes, !VarSet, ActiveGoal),

    MarkInactivePred = "table_loop_mark_as_inactive",
    MarkInactiveFailPred = "table_loop_mark_as_inactive_and_fail",
    MarkActiveFailPred = "table_loop_mark_as_active_and_fail",
    (
        TablingViaExtraArgs = no,
        generate_call(MarkInactivePred, det, [TableTipVar],
            impure_code, [], ModuleInfo, Context, MarkInactiveGoal),
        generate_call(MarkInactiveFailPred, failure, [TableTipVar],
            impure_code, [], ModuleInfo, Context, MarkInactiveFailGoal),
        generate_call(MarkActiveFailPred, failure, [TableTipVar],
            impure_code, [], ModuleInfo, Context, MarkActiveFailGoal)
    ;
        TablingViaExtraArgs = yes,
        TableTipArg = foreign_arg(TableTipVar,
            yes(cur_table_node_name - in_mode), trie_node_type),
        MarkInactiveCode = "\tMR_" ++ MarkInactivePred ++
            "(" ++ cur_table_node_name ++ ");\n",
        MarkInactiveFailCode = "\tMR_" ++ MarkInactiveFailPred ++
            "(" ++ cur_table_node_name ++ ");\n",
        MarkActiveFailCode = "\tMR_" ++ MarkActiveFailPred ++
            "(" ++ cur_table_node_name ++ ");\n",
        table_generate_foreign_proc(MarkInactivePred, det,
            tabling_c_attributes, [TableTipArg], [],
            "", MarkInactiveCode, "", impure_code, [],
            ModuleInfo, Context, MarkInactiveGoal),
        table_generate_foreign_proc(MarkInactiveFailPred, failure,
            tabling_c_attributes, [TableTipArg], [],
            "", MarkInactiveFailCode, "", impure_code, [],
            ModuleInfo, Context, MarkInactiveFailGoal),
        table_generate_foreign_proc(MarkActiveFailPred, failure,
            tabling_c_attributes, [TableTipArg], [],
            "", MarkActiveFailCode, "", impure_code, [],
            ModuleInfo, Context, MarkActiveFailGoal)
    ),

    determinism_to_code_model(Detism, CodeModel),
    set__list_to_set([TableTipVar | HeadVars], InactiveNonLocals),
    OutputVars = list__map(project_var, NumberedOutputVars),
    InactiveInstmapDelta = bind_vars(OutputVars),
    (
        CodeModel = model_det,
        InactiveGoalExpr = conj([OrigGoal, MarkInactiveGoal])
    ;
        CodeModel = model_semi,
        goal_info_get_instmap_delta(OrigGoalInfo, InstMapDelta),
        create_renaming(OutputVars, InstMapDelta, !VarTypes, !VarSet,
            Unifies, NewVars, Renaming),
        rename_vars_in_goal(Renaming, OrigGoal, RenamedOrigGoal),

        ThenGoalExpr = conj(list__append(Unifies, [MarkInactiveGoal])),
        list__append([TableTipVar | OutputVars], NewVars, ThenVars),
        set__list_to_set(ThenVars, ThenNonLocals),
        goal_info_init_hide(ThenNonLocals, InactiveInstmapDelta, Detism,
            purity_impure, Context, ThenGoalInfo),
        ThenGoal = ThenGoalExpr - ThenGoalInfo,

        InactiveGoalExpr = if_then_else([], RenamedOrigGoal,
            ThenGoal, MarkInactiveFailGoal)
    ;
        CodeModel = model_non,
        AfterGoalExpr = disj([MarkInactiveGoal, MarkActiveFailGoal]),
        instmap_delta_init_reachable(AfterInstMapDelta),
        goal_info_init_hide(set__make_singleton_set(TableTipVar),
            AfterInstMapDelta, multidet, purity_impure, Context,
            AfterGoalInfo),
        AfterGoal = AfterGoalExpr - AfterGoalInfo,
        FirstGoalExpr = conj([OrigGoal, AfterGoal]),
        goal_info_get_nonlocals(OrigGoalInfo, OrigGINonLocals),
        set__insert(OrigGINonLocals, TableTipVar, FirstNonlocals),
        goal_info_set_nonlocals(FirstNonlocals, OrigGoalInfo, FirstGoalInfo),
        FirstGoal = FirstGoalExpr - FirstGoalInfo,
        InactiveGoalExpr = disj([FirstGoal, MarkInactiveFailGoal])
    ),
    goal_info_init_hide(InactiveNonLocals, InactiveInstmapDelta, Detism,
        purity_impure, Context, InactiveGoalInfo),
    InactiveGoal = InactiveGoalExpr - InactiveGoalInfo,

    mercury_table_builtin_module(TB),
    SwitchArms = [
        case(cons(qualified(TB, "loop_active"), 0), ActiveGoal),
        case(cons(qualified(TB, "loop_inactive"), 0), InactiveGoal)
    ],
    SwitchExpr = switch(StatusVar, cannot_fail, SwitchArms),
    set__insert_list(InactiveNonLocals, [StatusVar, TableTipVar],
        SwitchNonLocals),
    goal_info_init_hide(SwitchNonLocals, InactiveInstmapDelta, Detism,
        purity_impure, Context, SwitchGoalInfo),
    SwitchGoal = SwitchExpr - SwitchGoalInfo,

    GoalExpr = conj([LookUpGoal, SwitchGoal]),
    goal_info_init_hide(OrigNonLocals, OrigInstMapDelta, Detism,
        purity_impure, Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

% Example of transformation for model_det memo:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   T0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(T0, A, T),
%   impure table_memo_setup(T, Status),
%   (
%       Status = memo_det_succeeded,
%       semipure table_memo_get_answer_block(T, Block),
%       semipure table_restore_int_answer(Block, 0, B)
%   ;
%       Status = memo_det_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = memo_det_inactive,
%       % status has been changed to active by the setup predicate
%       <original code>
%       impure table_memo_create_answer_block(T, 1, Block),
%       impure table_save_int_answer(Block, 0, B)
%   ).
%
% Example of transformation for model_semi memo:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   T0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(T0, A, T),
%   impure table_memo_setup(T, Status),
%   (
%       Status = memo_semi_failed,
%       fail
%   ;
%       Status = memo_semi_succeeded,
%       semipure table_memo_get_answer_block(T, Block),
%       semipure table_restore_int_answer(Block, 0, B)
%   ;
%       Status = memo_semi_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = memo_semi_inactive,
%       % status has been changed to active by the setup predicate
%       (if
%           <original code>, with B replaced by C
%       then
%           B = C,
%           impure table_memo_create_answer_block(T, 1, Block),
%           impure table_save_int_answer(Block, 0, B)
%       else
%           impure table_memo_mark_as_failed(T),
%           fail
%       )
%   ).
%
% Example of transformation for model_non memo:
%
% :- pred p(int::in, int::out) is semidet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%   CT0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(CT0, A, CT1),
%   impure table_memo_non_setup(CT1, Record, Status),
%   (
%       Status = memo_non_complete,
%       semipure table_memo_return_all_nondet(T, Block),
%       semipure table_restore_int_answer(Block, 0, B)
%   ;
%       Status = memo_non_incomplete,
%       error("detected need for minimal model tabling in ...")
%   ;
%       Status = memo_non_active,
%       error("detected infinite recursion in ...")
%   ;
%       Status = memo_non_inactive,
%       (
%           <original code>,
%
%               % Check for duplicate answers.
%           semipure table_memo_get_answer_table(Record, AT0),
%           impure table_lookup_insert_int(AT0, B, AT1),
%               % Fail if the answer is already in the table;
%               % otherwise, put it into the table.
%           impure table_mm_answer_is_not_duplicate(AT1),
%
%               % Save the new answer in the table.
%           impure table_memo_create_answer_block(Record, 1, Block),
%           impure table_save_int_answer(Block, 0, B),
%           (
%               impure table_memo_mark_as_incomplete(R)
%           ;
%               impure table_memo_mark_as_active_and_fail(R),
%               fail
%           )
%       ;
%           impure table_memo_mark_as_complete_and_fail(R)
%       )
%   ).
%
% If there are no output variables, then instead of creating an answer block
% and filling it in, we call table_memo_mark_as_succeeded.

:- pred create_new_memo_goal(determinism::in, hlds_goal::in,
    pred_id::in, proc_id::in, bool::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, hlds_goal::out,
    list(table_trie_step)::out) is det.

create_new_memo_goal(Detism, OrigGoal, PredId, ProcId,
        TablingViaExtraArgs, HeadVars, NumberedInputVars, NumberedOutputVars,
        !VarTypes, !VarSet, !TableInfo, TableTipVar, Goal, Steps) :-
    % Even if the original goal doesn't use all of the headvars,
    % the code generated by the tabling transformation does,
    % so we need to compute the nonlocals from the headvars rather
    % than getting it from the nonlocals field in the original goal.
    set__list_to_set(HeadVars, OrigNonLocals),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    goal_info_get_context(OrigGoalInfo, Context),

    ModuleInfo = !.TableInfo ^ table_module_info,
    determinism_to_code_model(Detism, CodeModel),
    (
        CodeModel = model_det,
        StatusType = memo_det_status_type,
        SetupPred = "table_memo_det_setup"
    ;
        CodeModel = model_semi,
        StatusType = memo_semi_status_type,
        SetupPred = "table_memo_semi_setup"
    ;
        CodeModel = model_non,
        unexpected(this_file, "create_new_memo_goal: model_non")
    ),
    generate_simple_call_table_lookup_goal(StatusType, SetupPred,
        NumberedInputVars, PredId, ProcId, TablingViaExtraArgs,
        Context, !VarTypes, !VarSet, !TableInfo, TableTipVar, StatusVar,
        LookUpGoal, Steps),

    generate_error_goal(!.TableInfo, Context, infinite_recursion_msg,
        !VarTypes, !VarSet, ActiveGoal),

    list__length(NumberedOutputVars, BlockSize),
    generate_memo_save_goals(NumberedOutputVars, TableTipVar, BlockSize,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        SaveAnswerGoals),
    generate_memo_restore_goal(NumberedOutputVars, OrigInstMapDelta,
        TableTipVar, ModuleInfo, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, RestoreAnswerGoal),
    SucceededGoal = RestoreAnswerGoal,

    set__list_to_set([TableTipVar | HeadVars], InactiveNonLocals),
    OutputVars = list__map(project_var, NumberedOutputVars),
    InactiveInstmapDelta = bind_vars(OutputVars),

    % The case CodeModel = model_non was caught by the code above.
    (
        CodeModel = model_det,
        InactiveGoalExpr = conj([OrigGoal | SaveAnswerGoals]),
        goal_info_init_hide(InactiveNonLocals, InactiveInstmapDelta,
            Detism, purity_impure, Context, InactiveGoalInfo),
        InactiveGoal = InactiveGoalExpr - InactiveGoalInfo,

        mercury_table_builtin_module(TB),
        SwitchArms = [
            case(cons(qualified(TB, "memo_det_active"), 0), ActiveGoal),
            case(cons(qualified(TB, "memo_det_inactive"), 0), InactiveGoal),
            case(cons(qualified(TB, "memo_det_succeeded"), 0), SucceededGoal)
        ]
    ;
        CodeModel = model_semi,
        create_renaming(OutputVars, OrigInstMapDelta, !VarTypes, !VarSet,
            Unifies, NewVars, Renaming),
        rename_vars_in_goal(Renaming, OrigGoal, RenamedOrigGoal),

        ThenGoalExpr = conj(list__append(Unifies, SaveAnswerGoals)),
        list__append([TableTipVar | OutputVars], NewVars, ThenVars),
        set__list_to_set(ThenVars, ThenNonLocals),
        goal_info_init_hide(ThenNonLocals, InactiveInstmapDelta,
            det, purity_impure, Context, ThenGoalInfo),
        ThenGoal = ThenGoalExpr - ThenGoalInfo,

        MarkAsFailedPred = "table_memo_mark_as_failed",
        (
            TablingViaExtraArgs = yes,
            TableTipArg = foreign_arg(TableTipVar,
                yes(cur_table_node_name - in_mode), trie_node_type),
            MarkAsFailedCode = "MR_" ++ MarkAsFailedPred ++
                "(" ++ cur_table_node_name ++ ");",
            table_generate_foreign_proc(MarkAsFailedPred, failure,
                tabling_c_attributes, [TableTipArg], [],
                "", MarkAsFailedCode, "", impure_code, [],
                ModuleInfo, Context, ElseGoal)
        ;
            TablingViaExtraArgs = no,
            generate_call("table_memo_mark_as_failed", failure, [TableTipVar],
                impure_code, [], ModuleInfo, Context, ElseGoal)
        ),
        InactiveGoalExpr = if_then_else([], RenamedOrigGoal,
            ThenGoal, ElseGoal),
        goal_info_init_hide(InactiveNonLocals, InactiveInstmapDelta, Detism,
            purity_impure, Context, InactiveGoalInfo),
        InactiveGoal = InactiveGoalExpr - InactiveGoalInfo,
        fail_goal(FailedGoal),

        mercury_table_builtin_module(TB),
        SwitchArms = [
            case(cons(qualified(TB, "memo_semi_active"), 0), ActiveGoal),
            case(cons(qualified(TB, "memo_semi_inactive"), 0), InactiveGoal),
            case(cons(qualified(TB, "memo_semi_succeeded"), 0), SucceededGoal),
            case(cons(qualified(TB, "memo_semi_failed"), 0), FailedGoal)
        ]
    ),

    SwitchExpr = switch(StatusVar, cannot_fail, SwitchArms),
    set__insert(InactiveNonLocals, StatusVar, SwitchNonLocals),
    goal_info_init_hide(SwitchNonLocals, InactiveInstmapDelta,
        Detism, purity_impure, Context, SwitchGoalInfo),
    SwitchGoal = SwitchExpr - SwitchGoalInfo,

    GoalExpr = conj([LookUpGoal, SwitchGoal]),
    goal_info_init_hide(OrigNonLocals, OrigInstMapDelta, Detism, purity_impure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

:- pred create_new_memo_non_goal(determinism::in, hlds_goal::in,
    pred_id::in, proc_id::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, hlds_goal::out,
    list(table_trie_step)::out) is det.

create_new_memo_non_goal(Detism, OrigGoal, PredId, ProcId,
        HeadVars, NumberedInputVars, NumberedOutputVars, !VarTypes, !VarSet,
        !TableInfo, RecordVar, Goal, Steps) :-
    % Even if the original goal doesn't use all of the headvars,
    % the code generated by the tabling transformation does,
    % so we need to compute the nonlocals from the headvars rather
    % than getting it from the nonlocals field in the original goal.
    set__list_to_set(HeadVars, OrigNonLocals),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    goal_info_get_context(OrigGoalInfo, Context),

    ModuleInfo = !.TableInfo ^ table_module_info,
    list__length(NumberedOutputVars, BlockSize),

    generate_error_goal(!.TableInfo, Context, infinite_recursion_msg,
        !VarTypes, !VarSet, InfiniteRecursionGoal),
    generate_error_goal(!.TableInfo, Context, need_minimal_model_msg,
        !VarTypes, !VarSet, NeedMinModelGoal),

    generate_memo_non_call_table_lookup_goal(NumberedInputVars,
        PredId, ProcId, Context, !VarTypes, !VarSet, !TableInfo,
        RecordVar, StatusVar, LookUpGoal, Steps),
    generate_memo_non_save_goals(NumberedOutputVars, RecordVar,
        BlockSize, Context, !VarTypes, !VarSet, !TableInfo, SaveAnswerGoals),

    generate_memo_non_restore_goal(Detism, NumberedOutputVars,
        OrigInstMapDelta, RecordVar, ModuleInfo, Context,
        !VarTypes, !VarSet, RestoreAllAnswerGoal),

    RecordVarName = memo_non_record_name,
    RecordArg = foreign_arg(RecordVar,
        yes(RecordVarName - in_mode), memo_non_record_type),
    MarkIncompletePred = "table_memo_mark_as_incomplete",
    MarkActivePred = "table_memo_mark_as_active_and_fail",
    MarkCompletePred = "table_memo_mark_as_complete_and_fail",
    MarkIncompleteCode = "MR_" ++ MarkIncompletePred ++ "(" ++
        RecordVarName ++ ");\n",
    MarkActiveCode = "MR_" ++ MarkActivePred ++ "(" ++
        RecordVarName ++ ");\n",
    MarkCompleteCode = "MR_" ++ MarkCompletePred ++ "(" ++
        RecordVarName ++ ");\n",
    table_generate_foreign_proc(MarkIncompletePred, det,
        tabling_c_attributes, [RecordArg], [],
        "", MarkIncompleteCode, "", impure_code, [],
        ModuleInfo, Context, MarkIncompleteGoal),
    table_generate_foreign_proc(MarkActivePred, failure,
        tabling_c_attributes, [RecordArg], [],
        "", MarkActiveCode, "", impure_code, [],
        ModuleInfo, Context, MarkActiveGoal),
    table_generate_foreign_proc(MarkCompletePred, failure,
        tabling_c_attributes, [RecordArg], [],
        "", MarkCompleteCode, "", impure_code, [],
        ModuleInfo, Context, MarkCompleteGoal),

    OrigSaveExpr = conj([OrigGoal | SaveAnswerGoals]),
    set__insert(OrigNonLocals, RecordVar, OrigSaveNonLocals),
    create_instmap_delta([OrigGoal | SaveAnswerGoals], OrigSaveIMD0),
    instmap_delta_restrict(OrigSaveNonLocals, OrigSaveIMD0, OrigSaveIMD),
    goal_info_init_hide(OrigSaveNonLocals, OrigSaveIMD, nondet, purity_impure,
        Context, OrigSaveGoalInfo),
    OrigSaveGoal = OrigSaveExpr - OrigSaveGoalInfo,

    AfterExpr = disj([MarkIncompleteGoal, MarkActiveGoal]),
    AfterNonLocals = set__make_singleton_set(RecordVar),
    create_instmap_delta([], AfterInstMapDelta),
    goal_info_init_hide(AfterNonLocals, AfterInstMapDelta, nondet,
        purity_impure, Context, AfterGoalInfo),
    AfterGoal = AfterExpr - AfterGoalInfo,

    OrigSaveAfterExpr = conj([OrigSaveGoal, AfterGoal]),
    OrigSaveAfterGoal = OrigSaveAfterExpr - OrigSaveGoalInfo,

    InactiveExpr = disj([OrigSaveAfterGoal, MarkCompleteGoal]),
    InactiveGoal = InactiveExpr - OrigSaveGoalInfo,

    set__list_to_set([RecordVar | HeadVars], InactiveNonLocals),
    OutputVars = list__map(project_var, NumberedOutputVars),
    InactiveInstmapDelta = bind_vars(OutputVars),

    mercury_table_builtin_module(TB),
    SwitchArms = [
        case(cons(qualified(TB, "memo_non_active"), 0), InfiniteRecursionGoal),
        case(cons(qualified(TB, "memo_non_inactive"), 0), InactiveGoal),
        case(cons(qualified(TB, "memo_non_incomplete"), 0), NeedMinModelGoal),
        case(cons(qualified(TB, "memo_non_complete"), 0), RestoreAllAnswerGoal)
    ],

    SwitchExpr = switch(StatusVar, cannot_fail, SwitchArms),
    set__insert(InactiveNonLocals, StatusVar, SwitchNonLocals),
    goal_info_init_hide(SwitchNonLocals, InactiveInstmapDelta, Detism,
        purity_impure, Context, SwitchGoalInfo),
    SwitchGoal = SwitchExpr - SwitchGoalInfo,

    GoalExpr = conj([LookUpGoal, SwitchGoal]),
    goal_info_init_hide(OrigNonLocals, OrigInstMapDelta, Detism, purity_impure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

% Example of transformation for tabling I/O, for I/O primitives (i.e.
% predicates defined by pragma c_code that take an input/output pair of
% io_state arguments) that have the tabled_for_io feature:
%
% :- pred p(int, string, io, io).
% :- mode p(in, out, di, uo) is det.
%
% p(A, B, S0, S) :-
%   <original code>
%
% The transformed code would be:
%
% p(A, B, S0, S) :-
%   (if
%           % Get the global I/O table, the global I/O
%           % counter, and the starting point for tabling
%           % I/O actions, if we are in the tabled range.
%       table_io_in_range(T0, Counter, Start)
%   then
%           % Look up the input arguments.
%       impure table_lookup_insert_start_int(T0, Counter,
%           Start, T),
%       (if
%           semipure table_io_has_occurred(T)
%       then
%           semipure table_memo_get_answer_block(T, Block),
%           impure table_restore_string_answer(Block, 0, B),
%           table_io_copy_io_state(S0, S)
%       else
%           <original code>
%               % Save the answers in the table.
%           impure table_io_create_answer_block(T, 1, Block),
%           impure table_save_string_answer(Block, 0, B)
%       )
%   else
%       <original code>
%   ).
%
% Note that copying the I/O state works only because variables of type
% io__state don't actually contain any information; the information is actually
% stored in global variables. However, if this ever changes, the transformation
% can be fixed simply by changing the value of --trace-table-io-states to yes,
% which will cause such values to be tabled along with the other output
% arguments.
%
% For I/O primitives that do not have tabled_for_io, we should require that
% they do not do any I/O in their own code, meaning that all their I/O is
% inside any Mercury code they call. We can then leave such primitives
% untransformed; the I/O primitives called from the inner Mercury engine
% will do the right thing. For now, this requirement is not enforced,
% which means that enabling I/O tabling (with --trace-table-io) does not
% guarantee that *all* I/O actions are tabled. This can cause inconsistent
% behavior after retry commands in mdb. This is the reason why retry across
% I/O is experimental for now.
%
% The reason why we require I/O primitives to be marked manually by a
% programmer with the tabled_for_io feature is to get the programmer to make
% sure that the primitive meets the requirement. Unfortunately, this cannot be
% automated, since automation would require analysis of arbitrary C code.
%
% The transformation for tabling I/O for declarative debugging is a variant
% of the usual transformation of I/O primitives. In this variant, the answer
% block contains not only the answers, but also a pointer to the primitive's
% proc layout structure and the values of the input aruments. The code we
% generate will fill in the slots containing this extra information before
% it executes the original goal.

:- pred table_gen__create_new_io_goal(hlds_goal::in, table_io_is_decl::in,
    table_io_is_unitize::in, bool::in, pred_id::in, proc_id::in, bool::in,
    assoc_list(prog_var, mer_mode)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out,
    hlds_goal::out, maybe(proc_table_info)::out) is det.

table_gen__create_new_io_goal(OrigGoal, TableDecl, Unitize, TableIoStates,
        PredId, ProcId, TablingViaExtraArgs, HeadVarModes,
        OrigInputVars, OrigOutputVars, !VarTypes, !VarSet,
        !TableInfo, Goal, MaybeProcTableInfo) :-
    OrigGoal = _ - OrigGoalInfo,
    ModuleInfo0 = !.TableInfo ^ table_module_info,
    module_info_pred_info(ModuleInfo0, PredId, PredInfo),
    pred_info_get_markers(PredInfo, Markers),
    ( check_marker(Markers, user_marked_no_inline) ->
        %
        % If the predicate should not be inlined, then we create a new
        % predicate with the same body as the original predicate, which is
        % called wherever the original goal would appear in the transformed
        % code.  This is necessary when the original goal is foreign C code
        % that uses labels.  The original goal would otherwise be duplicated
        % by the transformation, resulting in duplicate label errors from
        % the C compiler.
        % 
        clone_proc_and_create_call(PredInfo, ProcId, CallExpr, ModuleInfo0,
            ModuleInfo),
        NewGoal = CallExpr - OrigGoalInfo,
        !:TableInfo = !.TableInfo ^ table_module_info := ModuleInfo
    ;
        NewGoal = OrigGoal,
        ModuleInfo = ModuleInfo0
    ),
    goal_info_get_nonlocals(OrigGoalInfo, OrigNonLocals),
    goal_info_get_context(OrigGoalInfo, Context),

    (
        TableIoStates = yes,
        IoStateAssignToVars = [],
        IoStateAssignFromVars = [],
        SavedOutputVars = OrigOutputVars,
        SavedHeadVars = HeadVarModes
    ;
        TableIoStates = no,
        list__filter(table_gen__var_mode_pos_is_io_state(!.VarTypes),
            OrigOutputVars, IoStateAssignToVars, MisNumberedSavedOutputVars),
        reallocate_slot_numbers(MisNumberedSavedOutputVars, 0,
            SavedOutputVars),
        list__filter(table_gen__var_mode_pos_is_io_state(!.VarTypes),
            OrigInputVars, IoStateAssignFromVars, _MisNumberedSavedInputVars),
        list__filter(table_gen__var_mode_is_io_state(!.VarTypes),
            HeadVarModes, _, SavedHeadVars)
    ),
    generate_new_table_var("TableVar", trie_node_type, !VarTypes, !VarSet,
        TableVar),
    generate_new_table_var("CounterVar", int_type, !VarTypes, !VarSet,
        CounterVar),
    generate_new_table_var("StartVar", int_type, !VarTypes, !VarSet,
        StartVar),
    generate_call("table_io_in_range", semidet,
        [TableVar, CounterVar, StartVar], impure_code,
        ground_vars([TableVar, CounterVar, StartVar]),
        ModuleInfo, Context, InRangeGoal),
    generate_new_table_var("TipVar", trie_node_type, !VarTypes, !VarSet,
        TipVar),
    generate_call("table_lookup_insert_start_int", det,
        [TableVar, StartVar, CounterVar, TipVar], impure_code,
        ground_vars([TipVar]), ModuleInfo, Context, LookupGoal),
    generate_call("table_io_has_occurred", semidet, [TipVar],
        semipure_code, [], ModuleInfo, Context, OccurredGoal),
    (
        TableDecl = table_io_decl,
        ShroudedPredProcId = shroud_pred_proc_id(proc(PredId, ProcId)),
        TableIoDeclConsId = table_io_decl(ShroudedPredProcId),
        make_const_construction_alloc(TableIoDeclConsId, c_pointer_type,
            yes("TableIoDeclPtr"), TableIoDeclGoal, TableIoDeclPtrVar,
            !VarTypes, !VarSet),
        allocate_plain_slot_numbers(SavedHeadVars, 1, NumberedSavedHeadVars),
        NumberedSaveVars = [
            var_mode_pos_method(TableIoDeclPtrVar, in_mode, 0, unit)
            | NumberedSavedHeadVars],
        UnnumberedSavedOutputVars = list__map(project_var, SavedOutputVars),
        list__filter(var_belong_to_list(UnnumberedSavedOutputVars),
            NumberedSaveVars, NumberedSavedOutputVars),
        NumberedRestoreVars = NumberedSavedOutputVars,

        ProcInfo0 = !.TableInfo ^ table_cur_proc_info,
        continuation_info__generate_table_arg_type_info(ProcInfo0,
            list__map(project_var_pos, NumberedSavedHeadVars),
            TableArgTypeInfo),
        ProcTableInfo = table_io_decl_info(TableArgTypeInfo),
        MaybeProcTableInfo = yes(ProcTableInfo)
    ;
        TableDecl = table_io_proc,
        true_goal(TableIoDeclGoal),
        NumberedRestoreVars =
            list__map(project_out_arg_method, SavedOutputVars),
        NumberedSaveVars = list__map(project_out_arg_method, SavedOutputVars),
        MaybeProcTableInfo = no
    ),
    list__length(NumberedSaveVars, BlockSize),
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    generate_memo_restore_goal(NumberedRestoreVars, OrigInstMapDelta, TipVar,
        ModuleInfo, TablingViaExtraArgs, Context, !VarTypes, !VarSet,
        RestoreAnswerGoal0),
    (
        TableIoStates = yes,
        RestoreAnswerGoal = RestoreAnswerGoal0
    ;
        TableIoStates = no,
        (
            IoStateAssignFromVars = [IoStateAssignFromVarPrime],
            IoStateAssignToVars = [IoStateAssignToVarPrime]
        ->
            IoStateAssignFromVar = project_var(IoStateAssignFromVarPrime),
            IoStateAssignToVar = project_var(IoStateAssignToVarPrime)
        ;
            % The call to proc_info_has_io_state_pair in
            % table_gen__process_procs should ensure that we
            % never get here.
            error("create_new_io_goal: one in / one out violation")
        ),
        generate_call("table_io_copy_io_state", det,
            [IoStateAssignFromVar, IoStateAssignToVar], pure_code,
            [IoStateAssignFromVar - ground(clobbered, none),
            IoStateAssignToVar - ground(unique, none)],
            ModuleInfo, Context, IoStateAssignGoal),
        RestoreAnswerGoalExpr = conj([RestoreAnswerGoal0, IoStateAssignGoal]),
        create_instmap_delta([RestoreAnswerGoal0, IoStateAssignGoal],
            RestoreAnswerInstMapDelta0),
        RestoreAnswerGoal0 = _ - RestoreAnswerGoal0Info,
        goal_info_get_nonlocals(RestoreAnswerGoal0Info,
            RestoreAnswer0NonLocals),
        set__insert_list(RestoreAnswer0NonLocals,
            [IoStateAssignFromVar, IoStateAssignToVar],
            RestoreAnswerNonLocals),
        instmap_delta_restrict(RestoreAnswerNonLocals,
            RestoreAnswerInstMapDelta0, RestoreAnswerInstMapDelta),
        goal_info_init_hide(RestoreAnswerNonLocals,
            RestoreAnswerInstMapDelta, det, purity_semipure, Context,
            RestoreAnswerGoalInfo),
        RestoreAnswerGoal = RestoreAnswerGoalExpr - RestoreAnswerGoalInfo
    ),
    generate_memo_save_goals(NumberedSaveVars, TipVar, BlockSize,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        SaveAnswerGoals),
    (
        Unitize = table_io_alone,
        CallSaveAnswerGoalList = [NewGoal, TableIoDeclGoal | SaveAnswerGoals]
    ;
        Unitize = table_io_unitize,
        generate_new_table_var("SavedTraceEnabled", int_type,
            !VarTypes, !VarSet, SavedTraceEnabledVar),
        generate_call("table_io_left_bracket_unitized_goal", det,
            [SavedTraceEnabledVar], impure_code,
            ground_vars([SavedTraceEnabledVar]),
            ModuleInfo, Context, LeftBracketGoal),
        generate_call("table_io_right_bracket_unitized_goal", det,
            [SavedTraceEnabledVar], impure_code, [],
            ModuleInfo, Context, RightBracketGoal),
        CallSaveAnswerGoalList = [LeftBracketGoal, NewGoal,
            RightBracketGoal, TableIoDeclGoal | SaveAnswerGoals]
    ),
    CallSaveAnswerGoalExpr = conj(CallSaveAnswerGoalList),
    create_instmap_delta(CallSaveAnswerGoalList, CallSaveAnswerInstMapDelta0),
    set__insert(OrigNonLocals, TipVar, CallSaveAnswerNonLocals),
    instmap_delta_restrict(CallSaveAnswerNonLocals,
        CallSaveAnswerInstMapDelta0, CallSaveAnswerInstMapDelta),
    goal_info_init_hide(CallSaveAnswerNonLocals, CallSaveAnswerInstMapDelta,
        det, purity_impure, Context, CallSaveAnswerGoalInfo0),
    goal_info_add_feature(hide_debug_event,
        CallSaveAnswerGoalInfo0, CallSaveAnswerGoalInfo),
    CallSaveAnswerGoal = CallSaveAnswerGoalExpr - CallSaveAnswerGoalInfo,

    GenIfNecGoalExpr = if_then_else([], OccurredGoal,
        RestoreAnswerGoal, CallSaveAnswerGoal),
    create_instmap_delta([OccurredGoal, RestoreAnswerGoal,
        CallSaveAnswerGoal], GenIfNecInstMapDelta0),
    set__insert(OrigNonLocals, TipVar, GenIfNecNonLocals),
    instmap_delta_restrict(GenIfNecNonLocals,
        GenIfNecInstMapDelta0, GenIfNecInstMapDelta),
    goal_info_init_hide(GenIfNecNonLocals, GenIfNecInstMapDelta, det,
        purity_impure, Context, GenIfNecGoalInfo),
    GenIfNecGoal = GenIfNecGoalExpr - GenIfNecGoalInfo,

    CheckAndGenAnswerGoalExpr = conj([LookupGoal, GenIfNecGoal]),
    create_instmap_delta([LookupGoal, GenIfNecGoal],
        CheckAndGenAnswerInstMapDelta0),
    set__insert_list(OrigNonLocals, [TableVar, CounterVar, StartVar],
        CheckAndGenAnswerNonLocals),
    instmap_delta_restrict(CheckAndGenAnswerNonLocals,
        CheckAndGenAnswerInstMapDelta0, CheckAndGenAnswerInstMapDelta),
    goal_info_init_hide(CheckAndGenAnswerNonLocals,
        CheckAndGenAnswerInstMapDelta, det, purity_impure, Context,
        CheckAndGenAnswerGoalInfo),
    CheckAndGenAnswerGoal = CheckAndGenAnswerGoalExpr
        - CheckAndGenAnswerGoalInfo,

    BodyGoalExpr = if_then_else([], InRangeGoal, CheckAndGenAnswerGoal,
        NewGoal),
    create_instmap_delta([InRangeGoal, CheckAndGenAnswerGoal, NewGoal],
        BodyInstMapDelta0),
    instmap_delta_restrict(OrigNonLocals, BodyInstMapDelta0, BodyInstMapDelta),
    goal_info_init_hide(OrigNonLocals, BodyInstMapDelta, det, purity_impure,
        Context, BodyGoalInfo),
    Goal = BodyGoalExpr - BodyGoalInfo.

%-----------------------------------------------------------------------------%

% Example of transformation for nondet minimal_model:
%
% :- pred p(int, int).
% :- mode p(in, out) is nondet.
%
% p(A, B) :-
%   <original code>.
%
% The transformed code would be:
%
% p(A, B) :-
%       % Get a handle on the table.
%   CT0 = <table pointer for p/2>,
%
%       % Look up the input arguments, and set up the table.
%   impure table_lookup_insert_int(CT0, A, CT1),
%   impure table_mm_setup(CT1, Subgoal, Status),
%   (
%       Status = complete,
%           % Return all the answers from the complete table.
%       semipure table_mm_return_all_nondet(Subgoal, Block),
%       semipure table_restore_int_answer(Block, 0, B)
%   ;
%       Status = active,
%           % Suspend the current computational branch.
%           % Resume when the generator has computed some answers.
%       impure table_mm_suspend_consumer(Subgoal, Block),
%       semipure table_restore_int_answer(Block, 0, B)
%   ;
%       Status = inactive,
%       (
%           <original code>,
%
%               % Check for duplicate answers.
%           semipure table_mm_get_answer_table(Subgoal, AT0),
%           impure table_lookup_insert_int(AT0, B, AT1),
%               % Fail if the answer is already in the table;
%               % otherwise, put it into the table.
%           impure table_mm_answer_is_not_duplicate(AT1),
%
%               % Save the new answer in the table.
%           impure table_mm_create_answer_block(Subgoal, 1, Block),
%           impure table_save_int_answer(Block, 0, B)
%       ;
%               % Mark this subgoal as completely evaluated,
%               % modulo any dependencies on other subgoals.
%           impure table_mm_completion(Subgoal),
%           fail
%       )
%   ).

:- pred table_gen__create_new_mm_goal(determinism::in,
    hlds_goal::in, pred_id::in, proc_id::in, bool::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, hlds_goal::out,
    list(table_trie_step)::out) is det.

table_gen__create_new_mm_goal(Detism, OrigGoal, PredId, ProcId,
        TablingViaExtraArgs, HeadVars, NumberedInputVars, NumberedOutputVars,
        !VarTypes, !VarSet, !TableInfo, SubgoalVar, Goal, Steps) :-
    % Even if the original goal doesn't use all of the headvars,
    % the code generated by the tabling transformation does,
    % so we need to compute the nonlocals from the headvars rather
    % than getting it from the nonlocals field in the original goal.
    set__list_to_set(HeadVars, OrigNonLocals),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    goal_info_get_context(OrigGoalInfo, Context),

    ModuleInfo = !.TableInfo ^ table_module_info,
    list__length(NumberedOutputVars, BlockSize),
    generate_mm_call_table_lookup_goal(NumberedInputVars, PredId, ProcId,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        SubgoalVar, StatusVar, LookUpGoal, Steps),
    generate_mm_save_goals(NumberedOutputVars, SubgoalVar, BlockSize,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        SaveAnswerGoals),
    generate_mm_restore_goal(Detism, NumberedOutputVars, OrigInstMapDelta,
        SubgoalVar, ModuleInfo, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, RestoreAllAnswerGoal),
    generate_mm_suspend_goal(NumberedOutputVars, OrigInstMapDelta,
        SubgoalVar, ModuleInfo, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, SuspendGoal),

    MainExpr = conj([OrigGoal | SaveAnswerGoals]),
    set__insert_list(OrigNonLocals, [SubgoalVar, StatusVar], MainNonLocals),
    create_instmap_delta([OrigGoal | SaveAnswerGoals], MainIMD0),
    instmap_delta_restrict(MainNonLocals, MainIMD0, MainIMD),
    goal_info_init_hide(MainNonLocals, MainIMD, nondet, purity_impure, Context,
        MainGoalInfo),
    MainGoal = MainExpr - MainGoalInfo,

    generate_call("table_mm_completion", det, [SubgoalVar], impure_code,
        [], ModuleInfo, Context, ResumeGoal0),
    append_fail(ResumeGoal0, ResumeGoal),
    InactiveExpr = disj([MainGoal, ResumeGoal]),
    InactiveGoal = InactiveExpr - MainGoalInfo,

    mercury_table_builtin_module(TB),
    SwitchArms = [
        case(cons(qualified(TB, "mm_inactive"), 0), InactiveGoal),
        case(cons(qualified(TB, "mm_complete"), 0), RestoreAllAnswerGoal),
        case(cons(qualified(TB, "mm_active"), 0), SuspendGoal)
    ],
    SwitchExpr = switch(StatusVar, cannot_fail, SwitchArms),
    goal_info_add_feature(hide_debug_event, MainGoalInfo, SwitchGoalInfo),
    SwitchGoal = SwitchExpr - SwitchGoalInfo,

    GoalExpr = conj([LookUpGoal, SwitchGoal]),
    goal_info_init_hide(OrigNonLocals, OrigInstMapDelta, nondet, purity_impure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

% Example of transformation for nondet minimal_model_own_stack:
%
% :- pred p(int, int).
% :- mode p(in, out) is nondet
%
% p(A, B) :- e(A, B).
% p(A, B) :- p(A, C), e(C, B).
%
% The transformed code would be something like this; see also forest.ps
% in the tabling directory in the papers CVS module.
%
% p2_gen(A, B) :-
%   impure table_mmos_pickup_generator(Generator),
%   (
%       (
%           %
%           % Original goals
%           %
%       ),
%
%           % Check for duplicate answers.
%       semipure table_mmos_get_answer_table(Generator, AT0),
%       impure table_lookup_insert_int(AT0, B, AT1),
%           Fail if the answer is already in the table;
%           otherwise, put it into the table.
%       impure table_mmos_answer_is_not_duplicate(AT1),
%
%           % Save the new answer in the table.
%       impure table_mmos_create_answer_block(Generator, 1,
%           AnswerBlock),
%       impure table_save_int_ans(AnswerBlock, 0, B),
%       impure table_mmos_return_answer(Generator, AnswerBlock)
%   ;
%       impure table_mmos_completion(Generator)
%   ).
%
% p(A, B) :-
%   table_mmos_save_inputs(1, A),       % into global variable
%   CT0 = <table pointer for p/2>,
%   impure table_lookup_insert_int(CT0, A, CT1),
%   impure table_mmos_setup_consumer(CT1, 1, p2_gen, "p/2", Consumer),
%   impure table_mmos_consume_next_answer_nondet(Consumer, AnswerBlock),
%   impure table_restore_int_ans(AnswerBlock, 0, B).

:- pred table_gen__do_own_stack_transform(determinism::in, hlds_goal::in,
    pred_id::in, proc_id::in, pred_info::in, proc_info::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, generator_map::in, generator_map::out,
    hlds_goal::out, list(table_trie_step)::out) is det.

table_gen__do_own_stack_transform(Detism, OrigGoal, PredId, ProcId,
        PredInfo0, ProcInfo0, HeadVars, NumberedInputVars, NumberedOutputVars,
        !VarTypes, !VarSet, !TableInfo, !GenMap, Goal, Steps) :-
    PredName = pred_info_name(PredInfo0),
    ( map__search(!.GenMap, PredId, GeneratorPredIdPrime) ->
        GeneratorPredId = GeneratorPredIdPrime
    ;
        clone_pred_info(PredId, PredInfo0, HeadVars, NumberedOutputVars,
            GeneratorPredId, !TableInfo),
        map__det_insert(!.GenMap, PredId, GeneratorPredId, !:GenMap)
    ),

    % Even if the original goal doesn't use all of the headvars,
    % the code generated by the tabling transformation does,
    % so we need to compute the nonlocals from the headvars rather
    % than getting it from the nonlocals field in the original goal.
    set__list_to_set(HeadVars, OrigNonLocals),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_instmap_delta(OrigGoalInfo, OrigInstMapDelta),
    goal_info_get_context(OrigGoalInfo, Context),

    list__length(NumberedInputVars, NumInputVars),
    ModuleInfo = !.TableInfo ^ table_module_info,

    % The type is a lie, but a safe one: the variable we create
    % is handled only by C code. The reason why we lie is that
    % creating the right type would be quite complicated.
    GeneratorPredType = c_pointer_type,

    generate_new_table_var("GeneratorPredVar", GeneratorPredType,
        !VarTypes, !VarSet, GeneratorPredVar),
    generate_new_table_var("Consumer", consumer_type, !VarTypes, !VarSet,
        ConsumerVar),

    ShroudedPredProcId = shroud_pred_proc_id(proc(GeneratorPredId, ProcId)),
    GeneratorConsId = pred_const(ShroudedPredProcId, lambda_normal),
    make_const_construction(GeneratorPredVar, GeneratorConsId,
        MakeGeneratorVarGoal),

    generate_call_table_lookup_goals(NumberedInputVars,
        PredId, ProcId, Context, !VarTypes, !VarSet, !TableInfo, _TableTipVar,
        _LookupGoals, Steps, PredTableVar, LookupForeignArgs,
        LookupPrefixGoals, LookupCodeStr),

    InputVarModes = list__map(project_mode, NumberedInputVars),
    assoc_list__from_corresponding_lists(LookupForeignArgs, InputVarModes,
        LookupForeignArgModes),
    generate_save_input_vars_code(LookupForeignArgModes, ModuleInfo, 0,
        PickupForeignArgs, SaveInputVarCode, PickupInputVarCode),

    GeneratorPredVarName = generator_pred_name,
    ConsumerVarName = consumer_name,
    PredTableVarName = pred_table_name,

    PredTableArg = foreign_arg(PredTableVar,
        yes(PredTableVarName - in_mode), trie_node_type),
    GeneratorPredArg = foreign_arg(GeneratorPredVar,
        yes(generator_pred_name - in_mode), GeneratorPredType),
    ConsumerArg = foreign_arg(ConsumerVar,
        yes(ConsumerVarName - out_mode), consumer_type),

    LookupDeclCodeStr =
        "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
        "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
        "\tMR_GeneratorPtr " ++ generator_name ++ ";\n\n" ++
        "\t" ++ cur_table_node_name ++ " = " ++ PredTableVarName ++ ";\n" ++
        LookupCodeStr,

    SetupPred = "table_mmos_setup_consumer",
    SetupCode = "\t" ++ generator_name ++ " = " ++
        cur_table_node_name ++ "->MR_generator;\n" ++
        "\tif (" ++ generator_name ++ " == NULL) {\n" ++
            SaveInputVarCode ++
            "\t\t" ++ generator_name ++ " = MR_table_mmos_setup_generator(" ++
                cur_table_node_name ++ ",\n\t\t\t"
                ++ int_to_string(NumInputVars) ++ ", "
                ++ GeneratorPredVarName ++ ", " ++
                """" ++ PredName ++ """);\n" ++
            "\t\tMR_mmos_new_generator = " ++ generator_name ++ ";\n" ++
        "\t}\n" ++
        "\t" ++ consumer_name ++ " = " ++
            "MR_table_mmos_setup_consumer(" ++ generator_name ++
            ", """ ++ PredName ++ """);\n",
    table_generate_foreign_proc(SetupPred, det, make_generator_c_attributes,
        [PredTableArg, GeneratorPredArg, ConsumerArg], LookupForeignArgs,
        LookupDeclCodeStr, SetupCode, "", impure_code,
        ground_vars([ConsumerVar]), ModuleInfo, Context, SetupGoal),
    % We don't attach the call_table_tip attribute to the setup goal, since
    % retrying across the creation of the generator should not require undoing
    % the creation of the generator. Of course, for this to work *properly*,
    % the runtime system and the debugger will need to cooperate to effectively
    % present to the user a distinct sequence of trace events for each context.
    % In any case,
    % attach_call_table_tip(SetupGoal0, SetupGoal),
    LookupSetupGoals = [MakeGeneratorVarGoal | LookupPrefixGoals]
        ++ [SetupGoal],

    generate_new_table_var("AnswerBlock", answer_block_type,
        !VarTypes, !VarSet, AnswerBlockVar),
    ( Detism = multidet ->
        ConsumePredName = "table_mmos_consume_next_answer_multi"
    ; Detism = nondet ->
        ConsumePredName = "table_mmos_consume_next_answer_nondet"
    ;
        unexpected(this_file, "do_own_stack_transform: invalid determinism")
    ),
    % XXX consider inlining the predicate being called
    generate_call(ConsumePredName, Detism, [ConsumerVar, AnswerBlockVar],
        impure_code, ground_vars([AnswerBlockVar]), ModuleInfo, Context,
        GetNextAnswerGoal),
    generate_restore_goals(NumberedOutputVars, OrigInstMapDelta,
        AnswerBlockVar, ModuleInfo, Context, !VarTypes, !VarSet, _RestoreGoals,
        RestoreInstMapDeltaSrc, RestoreArgs, RestoreCodeStr),
    AnswerBlockArg = foreign_arg(AnswerBlockVar,
        yes(answer_block_name - in_mode), answer_block_type),
    RestoreAllPredName = "table_mmos_restore_answers",
    table_generate_foreign_proc(RestoreAllPredName, det, tabling_c_attributes,
        [AnswerBlockArg], RestoreArgs, "", "", RestoreCodeStr,
        impure_code, RestoreInstMapDeltaSrc, ModuleInfo, Context, RestoreGoal),

    GoalExpr = conj(LookupSetupGoals ++ [GetNextAnswerGoal, RestoreGoal]),
    goal_info_init(OrigNonLocals, OrigInstMapDelta, Detism, purity_impure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo,

    module_info_pred_info(ModuleInfo, GeneratorPredId, GeneratorPredInfo),
    table_info_init(ModuleInfo, GeneratorPredInfo, ProcInfo0,
        GeneratorTableInfo0),
    do_own_stack_create_generator(GeneratorPredId, ProcId, GeneratorPredInfo,
        ProcInfo0, Context, GeneratorPredVar,
        PickupInputVarCode, PickupForeignArgs,
        NumberedInputVars, NumberedOutputVars,
        OrigNonLocals, OrigInstMapDelta, !.VarTypes, !.VarSet,
        GeneratorTableInfo0, GeneratorTableInfo),
    !:TableInfo = !.TableInfo ^ table_module_info :=
        GeneratorTableInfo ^ table_module_info.

:- pred generate_save_input_vars_code(assoc_list(foreign_arg, mer_mode)::in,
    module_info::in, int::in, list(foreign_arg)::out, string::out, string::out)
    is det.

generate_save_input_vars_code([], _, _, [], "", "").
generate_save_input_vars_code([InputArg - Mode | InputArgModes], ModuleInfo,
        Pos, [PickupArg | PickupArgs], SaveVarCode ++ SaveVarCodes,
        PickupVarCode ++ PickupVarCodes) :-
    InputArg = foreign_arg(InputVar, MaybeArgNameMode, Type),
    (
        MaybeArgNameMode = yes(InputVarName - _InMode)
    ;
        MaybeArgNameMode = no,
        unexpected(this_file, "generate_save_input_vars_code: no InputVarName")
    ),
    mode_get_insts(ModuleInfo, Mode, InitInst, _FinalInst),
    PickupMode = (free -> InitInst),
    PickupArg = foreign_arg(InputVar, yes(InputVarName - PickupMode), Type),
    SaveVarCode = "\t\tMR_mmos_save_input_arg(" ++
        int_to_string(Pos) ++ ", " ++ InputVarName ++ ");\n",
    PickupVarCode = "\t\tMR_mmos_pickup_input_arg(" ++
        int_to_string(Pos) ++ ", " ++ InputVarName ++ ");\n",
    generate_save_input_vars_code(InputArgModes, ModuleInfo, Pos + 1,
        PickupArgs, SaveVarCodes, PickupVarCodes).

:- pred do_own_stack_create_generator(pred_id::in, proc_id::in,
    pred_info::in, proc_info::in, term__context::in, prog_var::in, string::in,
    list(foreign_arg)::in,
    list(var_mode_pos_method)::in, list(var_mode_pos_method)::in,
    set(prog_var)::in, instmap_delta::in,
    vartypes::in, prog_varset::in, table_info::in, table_info::out) is det.

do_own_stack_create_generator(PredId, ProcId, !.PredInfo, !.ProcInfo, Context,
        GeneratorVar, PickupVarCode, PickupForeignArgs,
        NumberedInputVars, NumberedOutputVars,
        OrigNonLocals, OrigInstMapDelta, !.VarTypes, !.VarSet, !TableInfo) :-
    ModuleInfo0 = !.TableInfo ^ table_module_info,

    proc_info_set_headvars(list__map(project_var, NumberedOutputVars),
        !ProcInfo),
    proc_info_set_argmodes(list__map(project_mode, NumberedOutputVars),
        !ProcInfo),
    PickupInstMapDeltaSrc0 = list__map(project_var_init_inst(ModuleInfo0),
        NumberedInputVars),
    PickupInstMapDeltaSrc = [pair_with_ground(GeneratorVar)
        | PickupInstMapDeltaSrc0],
    PickupGeneratorCode = "\t\t" ++ generator_name ++
        " = MR_mmos_new_generator;\n",
    PickupGeneratorArg = foreign_arg(GeneratorVar,
        yes(generator_name - out_mode), generator_type),
    table_generate_foreign_proc("table_mmos_pickup_inputs", det,
        tabling_c_attributes, [PickupGeneratorArg], PickupForeignArgs,
        "", PickupGeneratorCode, PickupVarCode, semipure_code,
        PickupInstMapDeltaSrc, ModuleInfo0, Context, PickupGoal),

    list__length(NumberedOutputVars, BlockSize),
    generate_own_stack_save_goal(NumberedOutputVars, GeneratorVar, BlockSize,
        Context, !VarTypes, !VarSet, !TableInfo, SaveAnswerGoals),

    proc_info_goal(!.ProcInfo, OrigGoal),
    GoalExpr = conj([PickupGoal, OrigGoal | SaveAnswerGoals]),
    OrigGoal = _ - OrigGoalInfo,
    goal_info_get_determinism(OrigGoalInfo, Detism),
    set__insert(OrigNonLocals, GeneratorVar, NonLocals),
    goal_info_init(NonLocals, OrigInstMapDelta, Detism, purity_impure, Context,
        GoalInfo0),
    goal_info_add_feature(hide_debug_event, GoalInfo0, GoalInfo),
    Goal = GoalExpr - GoalInfo,
    proc_info_set_goal(Goal, !ProcInfo),

    proc_info_set_vartypes(!.VarTypes, !ProcInfo),
    proc_info_set_varset(!.VarSet, !ProcInfo),
    pred_info_procedures(!.PredInfo, ProcTable0),
    map__det_insert(ProcTable0, ProcId, !.ProcInfo, ProcTable),
    pred_info_set_procedures(ProcTable, !PredInfo),

    module_info_preds(ModuleInfo0, PredTable0),
    map__det_update(PredTable0, PredId, !.PredInfo, PredTable),
    module_info_set_preds(PredTable, ModuleInfo0, ModuleInfo),
    !:TableInfo = !.TableInfo ^ table_module_info := ModuleInfo.

:- pred clone_pred_info(pred_id::in, pred_info::in, list(prog_var)::in,
    list(var_mode_pos_method)::in, pred_id::out,
    table_info::in, table_info::out) is det.

clone_pred_info(OrigPredId, PredInfo0, HeadVars, NumberedOutputVars,
        GeneratorPredId, !TableInfo) :-
    % We don't have any procedures for the generator yet. We will copy
    % the consumers' procedures later, one by one, as they are transformed.

    ModuleName = pred_info_module(PredInfo0),
    PredName0 = pred_info_name(PredInfo0),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo0),
    pred_info_context(PredInfo0, Context),
    % The generator is local even if the original predicate is exported.
    Status = local,
    pred_info_get_goal_type(PredInfo0, GoalType),
    pred_info_get_markers(PredInfo0, Markers0),
    pred_info_arg_types(PredInfo0, ArgTypes0),
    pred_info_typevarset(PredInfo0, TypeVarSet),
    pred_info_get_exist_quant_tvars(PredInfo0, ExistQVars),
    pred_info_get_class_context(PredInfo0, ClassContext),
    pred_info_get_constraint_proofs(PredInfo0, ClassProofs),
    pred_info_get_constraint_map(PredInfo0, ClassConstraintMap),
    pred_info_get_aditi_owner(PredInfo0, Owner),
    pred_info_get_origin(PredInfo0, OrigOrigin),
    pred_info_clauses_info(PredInfo0, ClausesInfo),

    PredName = qualified(ModuleName, "GeneratorFor_" ++ PredName0),
    assoc_list__from_corresponding_lists(HeadVars, ArgTypes0, HeadVarTypes),
    keep_only_output_arg_types(HeadVarTypes, NumberedOutputVars, ArgTypes),
    Arity = list__length(ArgTypes),

    markers_to_marker_list(Markers0, MarkerList0),
    list__filter(filter_marker, MarkerList0, MarkerList),
    marker_list_to_markers(MarkerList, Markers),

    Origin = transformed(table_generator, OrigOrigin, OrigPredId),
    pred_info_init(ModuleName, PredName, Arity, PredOrFunc, Context,
        Origin, Status, GoalType, Markers, ArgTypes, TypeVarSet,
        ExistQVars, ClassContext, ClassProofs, ClassConstraintMap,
        Owner, ClausesInfo, PredInfo),

    ModuleInfo0 = !.TableInfo ^ table_module_info,
    module_info_get_predicate_table(ModuleInfo0, PredTable0),
    predicate_table_insert(PredInfo, GeneratorPredId, PredTable0, PredTable),
    module_info_set_predicate_table(PredTable, ModuleInfo0, ModuleInfo),
    !:TableInfo = !.TableInfo ^ table_module_info := ModuleInfo.

    % clone_proc_and_create_call(PredInfo, ProcId, CallExpr, !ModuleInfo).
    % This predicate creates a new procedure with the same body as the
    % procedure with ProcId in PredInfo.  It then creates a call goal
    % expression which calls the new procedure with its formal arguments as the
    % actual arguments.
    %
:- pred clone_proc_and_create_call(pred_info::in, proc_id::in, 
    hlds_goal_expr::out, module_info::in, module_info::out) is det.

clone_proc_and_create_call(PredInfo, ProcId, CallExpr, !ModuleInfo) :-
        pred_info_proc_info(PredInfo, ProcId, ProcInfo),
        proc_info_context(ProcInfo, ProcContext),
        proc_info_varset(ProcInfo, ProcVarSet),
        proc_info_vartypes(ProcInfo, ProcVarTypes),
        proc_info_headvars(ProcInfo, ProcHeadVars),
        proc_info_inst_varset(ProcInfo, ProcInstVarSet),
        proc_info_argmodes(ProcInfo, ProcHeadModes),
        proc_info_inferred_determinism(ProcInfo, ProcDetism),
        proc_info_goal(ProcInfo, ProcGoal),
        proc_info_rtti_varmaps(ProcInfo, ProcRttiVarMaps),
        proc_info_create(ProcContext, ProcVarSet, ProcVarTypes, 
                ProcHeadVars, ProcInstVarSet, ProcHeadModes,
                ProcDetism, ProcGoal, ProcRttiVarMaps, address_is_not_taken,
                NewProcInfo),
        ModuleName = pred_info_module(PredInfo),
        OrigPredName = pred_info_name(PredInfo),
        PredOrFunc = pred_info_is_pred_or_func(PredInfo),
        pred_info_context(PredInfo, PredContext),
        NewPredName = qualified(ModuleName, "OutlinedForIOTablingFrom_" ++ 
            OrigPredName),
        pred_info_arg_types(PredInfo, PredArgTypes),
        pred_info_typevarset(PredInfo, PredTypeVarSet),
        pred_info_get_exist_quant_tvars(PredInfo, PredExistQVars),
        pred_info_get_class_context(PredInfo, PredClassContext),
        pred_info_get_assertions(PredInfo, PredAssertions),
        pred_info_get_aditi_owner(PredInfo, AditiOwner),
        pred_info_get_markers(PredInfo, Markers),
        pred_info_create(ModuleName, NewPredName, PredOrFunc, PredContext, 
                created(io_tabling), local, Markers, PredArgTypes, 
                PredTypeVarSet, PredExistQVars, PredClassContext,
                PredAssertions, AditiOwner, NewProcInfo, NewProcId, 
                NewPredInfo),
        module_info_get_predicate_table(!.ModuleInfo, PredicateTable0),
		predicate_table_insert(NewPredInfo, NewPredId,
			PredicateTable0, PredicateTable),
		module_info_set_predicate_table(PredicateTable, !ModuleInfo),
        CallExpr = call(NewPredId, NewProcId, ProcHeadVars, not_builtin, no,
            NewPredName).

:- pred keep_only_output_arg_types(assoc_list(prog_var, mer_type)::in,
    list(var_mode_pos_method)::in, list(mer_type)::out) is det.

keep_only_output_arg_types([], _, []).
keep_only_output_arg_types([_ | _], [], []).
keep_only_output_arg_types([Var - Type | VarTypes], [Out | Outs], OutTypes) :-
    Out = var_mode_pos_method(OutVar, _, _, _),
    ( Var = OutVar ->
        keep_only_output_arg_types(VarTypes, Outs, OutTypesTail),
        OutTypes = [Type | OutTypesTail]
    ;
        keep_only_output_arg_types(VarTypes, [Out | Outs], OutTypes)
    ).

:- pred filter_marker(marker::in) is semidet.

filter_marker(Marker) :-
    keep_marker(Marker) = yes.

:- func keep_marker(marker) = bool.

keep_marker(stub) = no.
keep_marker(infer_type) = no.
keep_marker(infer_modes) = no.
keep_marker(obsolete) = no.
keep_marker(user_marked_inline) = no.
keep_marker(user_marked_no_inline) = no.
keep_marker(heuristic_inline) = no.
keep_marker(dnf) = no.
keep_marker(aditi) = no.                % consider calling error
keep_marker(base_relation) = no.        % consider calling error
keep_marker(naive) = no.                % consider calling error
keep_marker(psn) = no.                  % consider calling error
keep_marker(aditi_memo) = no.           % consider calling error
keep_marker(aditi_no_memo) = no.        % consider calling error
keep_marker(supp_magic) = no.           % consider calling error
keep_marker(context) = no.              % consider calling error
keep_marker(generate_inline) = no.      % consider calling error
keep_marker(class_method) = no.
keep_marker(class_instance_method) = no.
keep_marker(named_class_instance_method) = no.
keep_marker(is_impure) = yes.
keep_marker(is_semipure) = yes.
keep_marker(promised_pure) = yes.
keep_marker(promised_semipure) = yes.
keep_marker(terminates) = yes.
keep_marker(does_not_terminate) = yes.
keep_marker(check_termination) = no.
keep_marker(calls_are_fully_qualified) = yes.
keep_marker(mode_check_clauses) = yes.

%-----------------------------------------------------------------------------%

:- pred generate_gen_proc_table_info(table_info::in, list(table_trie_step)::in,
    list(var_mode_method)::in, list(var_mode_method)::in,
    proc_table_info::out) is det.

generate_gen_proc_table_info(TableInfo, Steps, InputVars, OutputVars,
        ProcTableInfo) :-
    ProcInfo = TableInfo ^ table_cur_proc_info,
    list__append(InputVars, OutputVars, InOutHeadVars),
    allocate_slot_numbers(InOutHeadVars, 1, NumberedInOutHeadVars),
    ArgInfos = list__map(project_var_pos, NumberedInOutHeadVars),
    continuation_info__generate_table_arg_type_info(ProcInfo, ArgInfos,
        TableArgTypeInfo),
    NumInputs = list__length(InputVars),
    NumOutputs = list__length(OutputVars),
    ProcTableInfo = table_gen_info(NumInputs, NumOutputs, Steps,
        TableArgTypeInfo).

%-----------------------------------------------------------------------------%

    % Generate a goal for doing lookups in call tables for
    % loopcheck and memo predicates.
    %
:- pred generate_simple_call_table_lookup_goal(mer_type::in, string::in,
    list(var_mode_pos_method)::in, pred_id::in, proc_id::in, bool::in,
    term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, prog_var::out,
    hlds_goal::out, list(table_trie_step)::out) is det.

generate_simple_call_table_lookup_goal(StatusType, SetupPred,
        NumberedVars, PredId, ProcId, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, !TableInfo, TableTipVar, StatusVar, Goal, Steps) :-
    generate_call_table_lookup_goals(NumberedVars, PredId, ProcId, Context,
        !VarTypes, !VarSet, !TableInfo, TableTipVar, LookupGoals, Steps,
        PredTableVar, LookupForeignArgs, LookupPrefixGoals, LookupCodeStr),
    generate_new_table_var("Status", StatusType, !VarTypes, !VarSet,
        StatusVar),
    ModuleInfo = !.TableInfo ^ table_module_info,
    (
        TablingViaExtraArgs = yes,
        PredTableVarName = pred_table_name,
        TableTipVarName = table_tip_node_name,
        StatusVarName = status_name,
        PredTableArg = foreign_arg(PredTableVar,
            yes(PredTableVarName - in_mode), trie_node_type),
        TableTipArg = foreign_arg(TableTipVar,
            yes(TableTipVarName - out_mode), trie_node_type),
        StatusArg = foreign_arg(StatusVar,
            yes(StatusVarName - out_mode), StatusType),
        MainPredCodeStr = "\tMR_" ++ SetupPred ++ "(" ++
            cur_table_node_name ++ ", " ++ StatusVarName ++ ");\n",
        (
            NumberedVars = [_ | _],
            Args = [PredTableArg, TableTipArg, StatusArg],
            BoundVars = [TableTipVar, StatusVar],
            CalledPred = SetupPred ++ "_shortcut",
            TableTipAssignStr = MainPredCodeStr ++ "\t" ++ TableTipVarName ++
                " = " ++ cur_table_node_name ++ ";\n",
            PredCodeStr = "\tMR_" ++ CalledPred ++ "(" ++
                cur_table_node_name ++ ", " ++ TableTipVarName ++ ", " ++
                StatusVarName ++ ");\n"
        ;
            NumberedVars = [],
            Args = [PredTableArg, StatusArg],
            BoundVars = [StatusVar],
            CalledPred = SetupPred,
            TableTipAssignStr = "",
            PredCodeStr = MainPredCodeStr
        ),
        LookupDeclCodeStr =
            "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
            "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
            "\t" ++ cur_table_node_name ++ " = " ++
                PredTableVarName ++ ";\n" ++
            LookupCodeStr ++
            TableTipAssignStr,
        table_generate_foreign_proc(CalledPred, det, tabling_c_attributes,
            Args, LookupForeignArgs, LookupDeclCodeStr,
            PredCodeStr, "", impure_code, ground_vars(BoundVars),
            ModuleInfo, Context, SetupGoal0),
        attach_call_table_tip(SetupGoal0, SetupGoal),
        list__append(LookupPrefixGoals, [SetupGoal], LookupSetupGoals)
    ;
        TablingViaExtraArgs = no,
        generate_call(SetupPred, det, [TableTipVar, StatusVar],
            impure_code, ground_vars([StatusVar]),
            ModuleInfo, Context, SetupGoal0),
        attach_call_table_tip(SetupGoal0, SetupGoal),
        list__append(LookupGoals, [SetupGoal], LookupSetupGoals)
    ),
    GoalExpr = conj(LookupSetupGoals),
    Vars = list__map(project_var, NumberedVars),
    set__list_to_set([StatusVar, TableTipVar | Vars], NonLocals),
    goal_info_init_hide(NonLocals, bind_vars([TableTipVar, StatusVar]),
        det, purity_impure, Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

    % Generate a goal for doing lookups in call tables for
    % model_non memo predicates.
    %
:- pred generate_memo_non_call_table_lookup_goal(list(var_mode_pos_method)::in,
    pred_id::in, proc_id::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, prog_var::out,
    hlds_goal::out, list(table_trie_step)::out) is det.

generate_memo_non_call_table_lookup_goal(NumberedVars,
        PredId, ProcId, Context, !VarTypes, !VarSet, !TableInfo,
        RecordVar, StatusVar, Goal, Steps) :-
    generate_call_table_lookup_goals(NumberedVars,
        PredId, ProcId, Context, !VarTypes, !VarSet, !TableInfo,
        _TableTipVar, _LookupGoals, Steps, PredTableVar,
        LookupForeignArgs, LookupPrefixGoals, LookupCodeStr),
    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_new_table_var("Record", memo_non_record_type, !VarTypes, !VarSet,
        RecordVar),
    generate_new_table_var("Status", memo_non_status_type, !VarTypes, !VarSet,
        StatusVar),
    SetupPred = "table_memo_non_setup",
    BoundVars = [RecordVar, StatusVar],
    PredTableVarName = pred_table_name,
    RecordVarName = memo_non_record_name,
    StatusVarName = status_name,
    PredTableArg = foreign_arg(PredTableVar,
        yes(PredTableVarName - in_mode), trie_node_type),
    RecordArg = foreign_arg(RecordVar,
        yes(RecordVarName - out_mode), memo_non_record_type),
    StatusArg = foreign_arg(StatusVar,
        yes(StatusVarName - out_mode), memo_non_status_type),
    Args = [PredTableArg, RecordArg, StatusArg],
    LookupDeclCodeStr =
        "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
        "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
        "\t" ++ cur_table_node_name ++ " = " ++ PredTableVarName ++ ";\n" ++
        LookupCodeStr,
    PredCodeStr = "\tMR_" ++ SetupPred ++ "(" ++ cur_table_node_name ++ ", " ++
        RecordVarName ++ ", " ++ StatusVarName ++ ");\n",
    table_generate_foreign_proc(SetupPred, det, tabling_c_attributes, Args,
        LookupForeignArgs, LookupDeclCodeStr, PredCodeStr, "", impure_code,
        ground_vars(BoundVars), ModuleInfo, Context, SetupGoal0),
    attach_call_table_tip(SetupGoal0, SetupGoal),
    list__append(LookupPrefixGoals, [SetupGoal], LookupSetupGoals),

    GoalExpr = conj(LookupSetupGoals),
    Vars = list__map(project_var, NumberedVars),
    set__list_to_set([StatusVar, RecordVar | Vars], NonLocals),
    goal_info_init_hide(NonLocals, bind_vars([RecordVar, StatusVar]),
        det, purity_impure, Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

    % Generate a goal for doing lookups in call tables for
    % minimal model predicates.
    %
:- pred generate_mm_call_table_lookup_goal(list(var_mode_pos_method)::in,
    pred_id::in, proc_id::in, bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out, prog_var::out,
    hlds_goal::out, list(table_trie_step)::out) is det.

generate_mm_call_table_lookup_goal(NumberedVars, PredId, ProcId,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        SubgoalVar, StatusVar, Goal, Steps) :-
    generate_call_table_lookup_goals(NumberedVars, PredId, ProcId,
        Context, !VarTypes, !VarSet, !TableInfo, TableTipVar, LookupGoals,
        Steps, PredTableVar, LookupForeignArgs, LookupPrefixGoals,
        LookupCodeStr),
    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_new_table_var("Subgoal", subgoal_type, !VarTypes, !VarSet,
        SubgoalVar),
    generate_new_table_var("Status", mm_status_type, !VarTypes, !VarSet,
        StatusVar),
    SetupPred = "table_mm_setup",
    BoundVars = [SubgoalVar, StatusVar],
    (
        TablingViaExtraArgs = yes,
        PredTableVarName = pred_table_name,
        SubgoalVarName = subgoal_name,
        StatusVarName = status_name,
        PredTableArg = foreign_arg(PredTableVar,
            yes(PredTableVarName - in_mode), trie_node_type),
        SubgoalArg = foreign_arg(SubgoalVar,
            yes(SubgoalVarName - out_mode), subgoal_type),
        StatusArg = foreign_arg(StatusVar,
            yes(StatusVarName - out_mode), mm_status_type),
        Args = [PredTableArg, SubgoalArg, StatusArg],
        LookupDeclCodeStr =
            "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
            "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
            "\t" ++ cur_table_node_name ++ " = " ++
                PredTableVarName ++ ";\n" ++
            LookupCodeStr,
        PredCodeStr = "\tMR_" ++ SetupPred ++ "(" ++
            cur_table_node_name ++ ", " ++ SubgoalVarName ++ ", " ++
            StatusVarName ++ ");\n",
        table_generate_foreign_proc(SetupPred, det, tabling_c_attributes,
            Args, LookupForeignArgs, LookupDeclCodeStr,
            PredCodeStr, "", impure_code, ground_vars(BoundVars),
            ModuleInfo, Context, SetupGoal0),
        attach_call_table_tip(SetupGoal0, SetupGoal),
        list__append(LookupPrefixGoals, [SetupGoal], LookupSetupGoals)
    ;
        TablingViaExtraArgs = no,
        generate_call(SetupPred, det,
            [TableTipVar, SubgoalVar, StatusVar], impure_code,
            ground_vars(BoundVars), ModuleInfo, Context, SetupGoal0),
            attach_call_table_tip(SetupGoal0, SetupGoal),
        list__append(LookupGoals, [SetupGoal], LookupSetupGoals)
    ),
    GoalExpr = conj(LookupSetupGoals),
    Vars = list__map(project_var, NumberedVars),
    set__list_to_set([StatusVar, SubgoalVar | Vars], NonLocals),
    goal_info_init_hide(NonLocals, bind_vars([SubgoalVar, StatusVar]),
        det, purity_impure, Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

% Utility predicates used when creating call table lookup goals.

:- pred generate_call_table_lookup_goals(list(var_mode_pos_method)::in,
    pred_id::in, proc_id::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out,
    list(hlds_goal)::out, list(table_trie_step)::out, prog_var::out,
    list(foreign_arg)::out, list(hlds_goal)::out, string::out) is det.

generate_call_table_lookup_goals(NumberedVars, PredId, ProcId,
        Context, !VarTypes, !VarSet, !TableInfo, TableTipVar, Goals, Steps,
        PredTableVar, ForeignArgs, PrefixGoals, CodeStr) :-
    generate_get_table_goal(PredId, ProcId, !VarTypes, !VarSet,
        PredTableVar, GetTableGoal),
    generate_table_lookup_goals(NumberedVars, "CallTableNode",
        Context, PredTableVar, TableTipVar, !VarTypes, !VarSet, !TableInfo,
        LookupGoals, Steps, ForeignArgs, LookupPrefixGoals, CodeStr),
    Goals = [GetTableGoal | LookupGoals],
    PrefixGoals = [GetTableGoal | LookupPrefixGoals].

:- pred generate_get_table_goal(pred_id::in, proc_id::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    prog_var::out, hlds_goal::out) is det.

generate_get_table_goal(PredId, ProcId, !VarTypes, !VarSet, PredTableVar,
        Goal) :-
    generate_new_table_var("PredTable", trie_node_type, !VarTypes, !VarSet,
        PredTableVar),
    ShroudedPredProcId = shroud_pred_proc_id(proc(PredId, ProcId)),
    ConsId = tabling_pointer_const(ShroudedPredProcId),
    make_const_construction(PredTableVar, ConsId, GoalExpr - GoalInfo0),
    goal_info_add_feature(impure_goal, GoalInfo0, GoalInfo),
    Goal = GoalExpr - GoalInfo.

:- pred attach_call_table_tip(hlds_goal::in, hlds_goal::out) is det.

attach_call_table_tip(GoalExpr - GoalInfo0, GoalExpr - GoalInfo) :-
    goal_info_get_features(GoalInfo0, Features0),
    set__insert(Features0, call_table_gen, Features),
    goal_info_set_features(Features, GoalInfo0, GoalInfo).

%-----------------------------------------------------------------------------%

    % Generate a sequence of lookup goals for the given variables.
    % The generated code is used for lookups in both call tables
    % and answer tables.
    %
:- pred generate_table_lookup_goals(list(var_mode_pos_method)::in, string::in,
    term__context::in, prog_var::in, prog_var::out,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out,
    list(table_trie_step)::out, list(foreign_arg)::out,
    list(hlds_goal)::out, string::out) is det.

generate_table_lookup_goals([], _, _, !TableVar, !VarTypes, !VarSet,
        !TableInfo, [], [], [], [], "").
generate_table_lookup_goals([VarModePos | NumberedVars],
        Prefix, Context, !TableVar, !VarTypes, !VarSet, !TableInfo,
        Goals ++ RestGoals, [Step | Steps], ForeignArgs ++ RestForeignArgs,
        PrefixGoals ++ RestPrefixGoals, CodeStr ++ RestCodeStr) :-
    VarModePos = var_mode_pos_method(Var, _, VarSeqNum, ArgMethod),
    ModuleInfo = !.TableInfo ^ table_module_info,
    map__lookup(!.VarTypes, Var, VarType),
    classify_type(ModuleInfo, VarType) = TypeCat,
    (
        ArgMethod = arg_promise_implied,
        Goals = [],
        Step = table_trie_step_promise_implied,
        ForeignArgs = [],
        PrefixGoals = [],
        CodeStr = "\t/* promise_implied for " ++ arg_name(VarSeqNum) ++ " */\n"
    ;
        ArgMethod = arg_value,
        gen_lookup_call_for_type(ArgMethod, TypeCat, VarType, Var,
            Prefix, VarSeqNum, Context, !VarTypes, !VarSet, !TableInfo,
            !TableVar, Goals, Step, ForeignArgs, PrefixGoals, CodeStr)
    ;
        ArgMethod = arg_addr,
        gen_lookup_call_for_type(ArgMethod, TypeCat, VarType, Var,
            Prefix, VarSeqNum, Context, !VarTypes, !VarSet, !TableInfo,
            !TableVar, Goals, Step, ForeignArgs, PrefixGoals, CodeStr)
    ),
    generate_table_lookup_goals(NumberedVars, Prefix, Context,
        !TableVar, !VarTypes, !VarSet, !TableInfo, RestGoals, Steps,
        RestForeignArgs, RestPrefixGoals, RestCodeStr).

:- pred gen_lookup_call_for_type(arg_tabling_method::in, type_category::in,
    mer_type::in, prog_var::in, string::in, int::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::in, prog_var::out,
    list(hlds_goal)::out, table_trie_step::out,
    list(foreign_arg)::out, list(hlds_goal)::out, string::out) is det.

gen_lookup_call_for_type(ArgTablingMethod, TypeCat, Type, ArgVar, Prefix,
        VarSeqNum, Context, !VarTypes, !VarSet, !TableInfo, TableVar,
        NextTableVar, Goals, Step, ExtraArgs, PrefixGoals, CodeStr) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    VarName = Prefix ++ int_to_string(VarSeqNum),
    generate_new_table_var(VarName, trie_node_type, !VarTypes, !VarSet,
        NextTableVar),
    BindNextTableVar = ground_vars([NextTableVar]),
    ArgName = arg_name(VarSeqNum),
    ForeignArg = foreign_arg(ArgVar, yes(ArgName - in_mode), Type),
    ( TypeCat = enum_type ->
        ( type_to_ctor_and_args(Type, TypeCtor, _) ->
            module_info_get_type_table(ModuleInfo, TypeDefnTable),
            map__lookup(TypeDefnTable, TypeCtor, TypeDefn),
            hlds_data__get_type_defn_body(TypeDefn, TypeBody),
            (
                Ctors = TypeBody ^ du_type_ctors,
                TypeBody ^ du_type_is_enum = is_enum,
                TypeBody ^ du_type_usereq  = no
            ->
                list__length(Ctors, EnumRange)
            ;
                unexpected(this_file,
                    "gen_lookup_call_for_type: enum type is not du_type?")
            ),
            gen_int_construction("RangeVar", EnumRange, !VarTypes,
                !VarSet, RangeVar, RangeUnifyGoal),
            LookupPredName = "table_lookup_insert_enum",
            generate_call(LookupPredName, det,
                [TableVar, RangeVar, ArgVar, NextTableVar],
                impure_code, BindNextTableVar,
                ModuleInfo, Context, LookupGoal),
            Goals = [RangeUnifyGoal, LookupGoal],
            Step = table_trie_step_enum(EnumRange),
            PrefixGoals = [],
            ExtraArgs = [ForeignArg],
            CodeStr0 = "\tMR_" ++ LookupPredName ++ "(" ++
                cur_table_node_name ++ ", " ++ int_to_string(EnumRange) ++
                ", " ++ ArgName ++ ", " ++ next_table_node_name ++ ");\n"
        ;
            unexpected(this_file,
                "gen_lookup_call_for_type: unexpected enum type")
        )
    ; TypeCat = dummy_type ->
        generate_call("unify", det, [TableVar, NextTableVar],
            impure_code, BindNextTableVar, ModuleInfo, Context, SetEqualGoal),
        Goals = [SetEqualGoal],
        Step = table_trie_step_dummy,
        PrefixGoals = [],
        ExtraArgs = [],
        CodeStr0 = next_table_node_name ++ " = "
            ++ cur_table_node_name ++ ";\n "
    ;
        lookup_tabling_category(TypeCat, MaybeCatStringStep),
        (
            MaybeCatStringStep = no,
            prog_type__vars(Type, TypeVars),
            (
                ArgTablingMethod = arg_value,
                ( 
                    TypeVars = [],
                    LookupPredName = "table_lookup_insert_user",
                    Step = table_trie_step_user(Type)
                ;
                    TypeVars = [_ | _],
                    LookupPredName = "table_lookup_insert_poly",
                    Step = table_trie_step_poly
                )
            ;
                ArgTablingMethod = arg_addr,
                ( 
                    TypeVars = [],
                    LookupPredName = "table_lookup_insert_user_fast_loose",
                    Step = table_trie_step_user_fast_loose(Type)
                ;
                    TypeVars = [_ | _],
                    LookupPredName = "table_lookup_insert_poly_fast_loose",
                    Step = table_trie_step_poly_fast_loose
                )
            ;
                ArgTablingMethod = arg_promise_implied,
                unexpected(this_file,
                    "gen_lookup_call_for_type: arg_promise_implied")
            ),
            make_type_info_var(Type, Context, !VarTypes, !VarSet,
                !TableInfo, TypeInfoVar, ExtraGoals),
            generate_call(LookupPredName, det,
                [TypeInfoVar, TableVar, ArgVar, NextTableVar],
                impure_code, BindNextTableVar, ModuleInfo, Context, CallGoal),
            Goals = ExtraGoals ++ [CallGoal],
            PrefixGoals = ExtraGoals,
            TypeInfoArgName = "input_typeinfo" ++ int_to_string(VarSeqNum),
            map__lookup(!.VarTypes, TypeInfoVar, TypeInfoType),
            ForeignTypeInfoArg = foreign_arg(TypeInfoVar,
                yes(TypeInfoArgName - in_mode), TypeInfoType),
            ExtraArgs = [ForeignTypeInfoArg, ForeignArg],
            CodeStr0 = "\tMR_" ++ LookupPredName ++ "(" ++
                cur_table_node_name ++ ", " ++ TypeInfoArgName ++ ", " ++
                ArgName ++ ", " ++ next_table_node_name ++ ");\n"
        ;
            MaybeCatStringStep = yes(CatString - Step),
            LookupPredName = "table_lookup_insert_" ++ CatString,
            generate_call(LookupPredName, det,
                [TableVar, ArgVar, NextTableVar],
                impure_code, BindNextTableVar, ModuleInfo, Context, Goal),
            Goals = [Goal],
            PrefixGoals = [],
            ExtraArgs = [ForeignArg],
            CodeStr0 = "\tMR_" ++ LookupPredName ++ "(" ++
                cur_table_node_name ++ ", " ++ ArgName ++ ", " ++
                next_table_node_name ++ ");\n"
        )
    ),
    CodeStr = CodeStr0 ++ "\t" ++ cur_table_node_name ++ " = " ++
        next_table_node_name ++ ";\n".

%-----------------------------------------------------------------------------%

    % Generate a goal for saving the output arguments in an answer block
    % in memo predicates.
    %
:- pred generate_memo_save_goals(list(var_mode_pos_method(T))::in,
    prog_var::in, int::in, bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out) is det.

generate_memo_save_goals(NumberedSaveVars, TableTipVar, BlockSize,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo, Goals) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    ( BlockSize > 0 ->
        CreatePredName = "table_memo_create_answer_block",
        ShortcutPredName = "table_memo_fill_answer_block_shortcut",
        generate_all_save_goals(NumberedSaveVars, TableTipVar, trie_node_type,
            base_name, BlockSize, CreatePredName, ShortcutPredName,
            TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
            Goals, _, _)
    ;
        MarkAsSucceededPred = "table_memo_mark_as_succeeded",
        (
            TablingViaExtraArgs = yes,
            TableArg = foreign_arg(TableTipVar,
                yes(cur_table_node_name - in_mode), trie_node_type),
            MarkAsSucceededCode = "MR_" ++ MarkAsSucceededPred ++
                "(" ++ cur_table_node_name ++ ");",
            table_generate_foreign_proc(MarkAsSucceededPred, det,
                tabling_c_attributes, [TableArg], [],
                "", MarkAsSucceededCode, "", impure_code, [],
                ModuleInfo, Context, Goal)
        ;
            TablingViaExtraArgs = no,
            generate_call(MarkAsSucceededPred, det, [TableTipVar],
                impure_code, [], ModuleInfo, Context, Goal)
        ),
        Goals = [Goal]
    ).

    % Generate a goal for saving the output arguments in an answer block
    % in model_non memo predicates.
    %
:- pred generate_memo_non_save_goals(list(var_mode_pos_method)::in,
    prog_var::in, int::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out) is det.

generate_memo_non_save_goals(NumberedSaveVars, RecordVar,
        BlockSize, Context, !VarTypes, !VarSet, !TableInfo, Goals) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_new_table_var("AnswerTableVar", trie_node_type,
        !VarTypes, !VarSet, AnswerTableVar),
    RecordName = memo_non_record_name,
    AnswerTableName = "AnswerTableVar",
    RecordArg = foreign_arg(RecordVar,
        yes(RecordName - in_mode), memo_non_record_type),
    AnswerTableArg = foreign_arg(AnswerTableVar,
        yes(AnswerTableName - in_mode), trie_node_type),
    GetPredName = "table_memo_non_get_answer_table",
    GetPredCode = "\tMR_" ++ GetPredName ++ "(" ++
        RecordName ++ ", " ++ AnswerTableName ++ ");\n",
    table_generate_foreign_proc(GetPredName, det, tabling_c_attributes,
        [RecordArg, AnswerTableArg], [], "", GetPredCode, "",
        semipure_code, ground_vars([AnswerTableVar]),
        ModuleInfo, Context, GetAnswerTableGoal),
    generate_table_lookup_goals(NumberedSaveVars,
        "AnswerTableNode", Context, AnswerTableVar, _AnswerTableTipVar,
        !VarTypes, !VarSet, !TableInfo, _LookupAnswerGoals, _,
        LookupForeignArgs, LookupPrefixGoals, LookupCodeStr),

    CreateAnswerBlockPred = "table_memo_non_create_answer_block",
    CreateAnswerBlockPredShortcut = CreateAnswerBlockPred ++ "_shortcut",
    generate_all_save_goals(NumberedSaveVars, RecordVar,
        memo_non_record_type, memo_non_record_name, BlockSize,
        CreateAnswerBlockPred, CreateAnswerBlockPredShortcut, yes,
        Context, !VarTypes, !VarSet, !TableInfo, _SaveGoals,
        SaveDeclCode, CreateSaveCode),

    GetPredName = "table_memo_non_get_answer_table",
    DuplCheckPredName = "table_memo_non_answer_is_not_duplicate",
    DuplCheckPredNameShortcut = DuplCheckPredName ++ "_shortcut",

    SuccName = "succeeded",
    LookupDeclCodeStr =
        "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
        "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
        "\tMR_bool " ++ SuccName ++ ";\n",
    GetLookupCodeStr =
        "\tMR_" ++ GetPredName ++ "(" ++ RecordName ++ ", " ++
            cur_table_node_name ++ ");\n" ++
        LookupCodeStr,
    DuplCheckCodeStr =
        "\tMR_" ++ DuplCheckPredName ++ "(" ++
            cur_table_node_name ++ ", " ++ SuccName ++ ");\n",
    AssignSuccessCodeStr =
        "\t" ++ success_indicator_name ++ " = " ++ SuccName ++ ";\n",
    PreStr = LookupDeclCodeStr ++ SaveDeclCode ++ GetLookupCodeStr,
    PostStr = "\tif (" ++ SuccName ++ ") {\n" ++ CreateSaveCode ++ "\t}\n" ++
        AssignSuccessCodeStr,
    table_generate_foreign_proc(DuplCheckPredNameShortcut, semidet,
        tabling_c_attributes, [RecordArg], LookupForeignArgs,
        PreStr, DuplCheckCodeStr, PostStr, impure_code, [],
        ModuleInfo, Context, DuplicateCheckSaveGoal),
    Goals = [GetAnswerTableGoal | LookupPrefixGoals] ++
        [DuplicateCheckSaveGoal].

    % Generate a goal for saving the output arguments in an answer block
    % in minimal model predicates.
    %
:- pred generate_mm_save_goals(list(var_mode_pos_method)::in,
    prog_var::in, int::in, bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out) is det.

generate_mm_save_goals(NumberedSaveVars, SubgoalVar, BlockSize,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo, Goals) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_new_table_var("AnswerTableVar", trie_node_type,
        !VarTypes, !VarSet, AnswerTableVar),
    GetPredName = "table_mm_get_answer_table",
    generate_call(GetPredName, det, [SubgoalVar, AnswerTableVar],
        semipure_code, ground_vars([AnswerTableVar]),
        ModuleInfo, Context, GetAnswerTableGoal),
    generate_table_lookup_goals(NumberedSaveVars,
        "AnswerTableNode", Context, AnswerTableVar, AnswerTableTipVar,
        !VarTypes, !VarSet, !TableInfo, LookupAnswerGoals, _,
        LookupForeignArgs, LookupPrefixGoals, LookupCodeStr),

    CreatePredName = "table_mm_create_answer_block",
    ShortcutCreatePredName = "table_mm_fill_answer_block_shortcut",
    generate_all_save_goals(NumberedSaveVars,
        SubgoalVar, subgoal_type, subgoal_name, BlockSize,
        CreatePredName, ShortcutCreatePredName, TablingViaExtraArgs,
        Context, !VarTypes, !VarSet, !TableInfo, SaveGoals,
        SaveDeclCode, CreateSaveCode),

    DuplCheckPredName = "table_mm_answer_is_not_duplicate",
    DuplCheckPredNameShortCut = DuplCheckPredName ++ "_shortcut",
    (
        TablingViaExtraArgs = yes,
        SubgoalName = subgoal_name,
        Args = [foreign_arg(SubgoalVar, yes(SubgoalName - in_mode),
            subgoal_type)],
        SuccName = "succeeded",
        LookupDeclCodeStr =
            "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
            "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
            "\tMR_bool " ++ SuccName ++ ";\n",
        GetLookupCodeStr =
            "\tMR_" ++ GetPredName ++ "(" ++ SubgoalName ++ ", " ++
                cur_table_node_name ++ ");\n" ++
            LookupCodeStr,
        DuplCheckCodeStr =
            "\tMR_" ++ DuplCheckPredName ++ "(" ++
                cur_table_node_name ++ ", " ++ SuccName ++ ");\n",
        AssignSuccessCodeStr =
            "\t" ++ success_indicator_name ++ " = " ++ SuccName ++ ";\n",
        PreStr = LookupDeclCodeStr ++ SaveDeclCode ++ GetLookupCodeStr,
        PostStr = "\tif (" ++ SuccName ++ ") {\n" ++
            CreateSaveCode ++ "\t}\n" ++
            AssignSuccessCodeStr,
        table_generate_foreign_proc(DuplCheckPredNameShortCut, semidet,
            tabling_c_attributes, Args, LookupForeignArgs,
            PreStr, DuplCheckCodeStr, PostStr, impure_code, [],
            ModuleInfo, Context, DuplicateCheckSaveGoal),
        list__append(LookupPrefixGoals, [DuplicateCheckSaveGoal], Goals)
    ;
        TablingViaExtraArgs = no,
        generate_call(DuplCheckPredName, semidet, [AnswerTableTipVar],
            impure_code, [], ModuleInfo, Context, DuplicateCheckGoal),
        list__append([GetAnswerTableGoal | LookupAnswerGoals],
            [DuplicateCheckGoal], LookupCheckGoals),
        list__append(LookupCheckGoals, SaveGoals, Goals)
    ).

    % Generate a save goal for the given variables.
    %
:- pred generate_all_save_goals(list(var_mode_pos_method(T))::in,
    prog_var::in, mer_type::in, string::in, int::in, string::in, string::in,
    bool::in, term__context::in, vartypes::in, vartypes::out,
    prog_varset::in, prog_varset::out, table_info::in, table_info::out,
    list(hlds_goal)::out, string::out, string::out) is det.

generate_all_save_goals(NumberedSaveVars, BaseVar, BaseVarType, BaseVarName,
        BlockSize, CreatePredName, ShortcutPredName,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, !TableInfo,
        Goals, SaveDeclCodeStr, CreateSaveCodeStr) :-
    generate_new_table_var("AnswerBlock", answer_block_type,
        !VarTypes, !VarSet, AnswerBlockVar),
    generate_save_goals(NumberedSaveVars, AnswerBlockVar, Context,
        !VarTypes, !VarSet, !TableInfo, SaveGoals,
        SaveArgs, SavePrefixGoals, SaveCodeStr),
    ModuleInfo = !.TableInfo ^ table_module_info,
    (
        TablingViaExtraArgs = yes,
        TableArg = foreign_arg(BaseVar, yes(BaseVarName - in_mode),
            BaseVarType),
        Args = [TableArg],
        SaveDeclCodeStr = "\tMR_AnswerBlock " ++ answer_block_name ++ ";\n",
        CreateCodeStr = "\tMR_" ++ CreatePredName ++ "(" ++
            BaseVarName ++ ", " ++ int_to_string(BlockSize) ++ ", " ++
            answer_block_name ++ ");\n",
        CreateSaveCodeStr = CreateCodeStr ++ SaveCodeStr,
        ShortcutStr = "\tMR_" ++ ShortcutPredName ++ "(" ++
            BaseVarName ++ ");\n",
        table_generate_foreign_proc(ShortcutPredName, det,
            tabling_c_attributes, Args, SaveArgs,
            SaveDeclCodeStr ++ CreateSaveCodeStr, ShortcutStr, "",
            impure_code, [], ModuleInfo, Context, ShortcutGoal),
        list__append(SavePrefixGoals, [ShortcutGoal], Goals)
    ;
        TablingViaExtraArgs = no,
        gen_int_construction("BlockSize", BlockSize, !VarTypes,
            !VarSet, BlockSizeVar, BlockSizeVarUnifyGoal),
        generate_call(CreatePredName, det,
            [BaseVar, BlockSizeVar, AnswerBlockVar],
            impure_code, ground_vars([AnswerBlockVar]),
            ModuleInfo, Context, CreateAnswerBlockGoal),
        Goals = [BlockSizeVarUnifyGoal, CreateAnswerBlockGoal | SaveGoals],
        SaveDeclCodeStr = "",
        CreateSaveCodeStr = ""
    ).

%-----------------------------------------------------------------------------%

    % Generate a sequence of save goals for the given variables.
    %
:- pred generate_own_stack_save_goal(list(var_mode_pos_method)::in,
    prog_var::in, int::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out) is det.

generate_own_stack_save_goal(NumberedOutputVars, GeneratorVar, BlockSize,
        Context, !VarTypes, !VarSet, !TableInfo, Goals) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    generate_new_table_var("AnswerTableVar", trie_node_type,
        !VarTypes, !VarSet, AnswerTableVar),
    GeneratorName = generator_name,
    GeneratorArg = foreign_arg(GeneratorVar, yes(GeneratorName - in_mode),
        generator_type),
    generate_table_lookup_goals(NumberedOutputVars,
        "AnswerTableNode", Context, AnswerTableVar, _AnswerTableTipVar,
        !VarTypes, !VarSet, !TableInfo, _LookupAnswerGoals, _Steps,
        LookupForeignArgs, LookupPrefixGoals, LookupCodeStr),

    CreatePredName = "table_mm_create_answer_block",
    generate_new_table_var("AnswerBlock", answer_block_type,
        !VarTypes, !VarSet, AnswerBlockVar),
    generate_save_goals(NumberedOutputVars, AnswerBlockVar, Context,
        !VarTypes, !VarSet, !TableInfo, _SaveGoals,
        _SaveArgs, SavePrefixGoals, SaveCodeStr),

    DuplCheckPredName = "table_mmos_answer_is_not_duplicate",
    DuplCheckPredNameShortCut = DuplCheckPredName ++ "_shortcut",
    Args = [GeneratorArg],
    SuccName = "succeeded",
    LookupSaveDeclCodeStr =
        "\tMR_TrieNode " ++ cur_table_node_name ++ ";\n" ++
        "\tMR_TrieNode " ++ next_table_node_name ++ ";\n" ++
        "\tMR_AnswerBlock " ++ answer_block_name ++ ";\n" ++
        "\tMR_bool " ++ SuccName ++ ";\n",
    GetPredName = "table_mmos_get_answer_table",
    GetLookupCodeStr = "\t" ++ cur_table_node_name ++ " = " ++
        "MR_" ++ GetPredName ++ "(" ++ GeneratorName ++ ");\n" ++
        LookupCodeStr,
    DuplCheckCodeStr =
        "\tMR_" ++ DuplCheckPredName ++ "(" ++
            cur_table_node_name ++ ", " ++ SuccName ++ ");\n",
    AssignSuccessCodeStr =
        "\t" ++ success_indicator_name ++ " = " ++ SuccName ++ ";\n",
    CreateCodeStr = "\tMR_" ++ CreatePredName ++ "(" ++
        GeneratorName ++ ", " ++ int_to_string(BlockSize) ++ ", " ++
        answer_block_name ++ ");\n",
    CreateSaveCodeStr = CreateCodeStr ++ SaveCodeStr,
    PreStr = LookupSaveDeclCodeStr ++ GetLookupCodeStr,
    PostStr = "\tif (" ++ SuccName ++ ") {\n" ++
        CreateSaveCodeStr ++ "\t}\n" ++
        AssignSuccessCodeStr,
    table_generate_foreign_proc(DuplCheckPredNameShortCut, semidet,
        tabling_c_attributes, Args, LookupForeignArgs,
        PreStr, DuplCheckCodeStr, PostStr, impure_code, [],
        ModuleInfo, Context, DuplicateCheckSaveGoal),
    Goals = LookupPrefixGoals ++ SavePrefixGoals ++ [DuplicateCheckSaveGoal].

:- pred generate_save_goals(list(var_mode_pos_method(T))::in, prog_var::in,
    term__context::in, vartypes::in, vartypes::out,
    prog_varset::in, prog_varset::out, table_info::in, table_info::out,
    list(hlds_goal)::out, list(foreign_arg)::out, list(hlds_goal)::out,
    string::out) is det.

generate_save_goals([], _, _, !VarTypes, !VarSet, !TableInfo, [],
        [], [], "").
generate_save_goals([NumberedVar | NumberedRest], TableVar, Context,
        !VarTypes, !VarSet, !TableInfo, Goals, Args ++ RestArgs,
        PrefixGoals ++ RestPrefixGoals, CodeStr ++ RestCodeStr) :-
    NumberedVar = var_mode_pos_method(Var, _Mode, Offset, _),
    gen_int_construction("OffsetVar", Offset, !VarTypes, !VarSet,
        OffsetVar, OffsetUnifyGoal),
    ModuleInfo = !.TableInfo ^ table_module_info,
    map__lookup(!.VarTypes, Var, VarType),
    classify_type(ModuleInfo, VarType) = TypeCat,
    gen_save_call_for_type(TypeCat, VarType, TableVar, Var,
        Offset, OffsetVar, Context, !VarTypes, !VarSet, !TableInfo,
        SaveGoals, Args, PrefixGoals, CodeStr),
    generate_save_goals(NumberedRest, TableVar, Context,
        !VarTypes, !VarSet, !TableInfo, RestGoals,
        RestArgs, RestPrefixGoals, RestCodeStr),
    Goals = [OffsetUnifyGoal | SaveGoals ++ RestGoals].

:- pred gen_save_call_for_type(type_category::in, mer_type::in,
    prog_var::in, prog_var::in, int::in, prog_var::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(hlds_goal)::out,
    list(foreign_arg)::out, list(hlds_goal)::out, string::out) is det.

gen_save_call_for_type(TypeCat, Type, TableVar, Var, Offset, OffsetVar,
        Context, !VarTypes, !VarSet, !TableInfo, Goals,
        Args, PrefixGoals, CodeStr) :-
    ModuleInfo = !.TableInfo ^ table_module_info,
    Name = arg_name(Offset),
    ForeignArg = foreign_arg(Var, yes(Name - in_mode), Type),
    ( type_util__type_is_io_state(Type) ->
        SavePredName = "table_save_io_state_answer",
        generate_call(SavePredName, det, [TableVar, OffsetVar, Var],
            impure_code, [], ModuleInfo, Context, Goal),
        Goals = [Goal],
        Args = [ForeignArg],
        PrefixGoals = [],
        CodeStr = "\tMR_" ++ SavePredName ++ "(" ++
            answer_block_name ++ ", " ++ int_to_string(Offset) ++ ", " ++
            Name ++ ");\n"
    ; builtin_type(TypeCat) = no ->
        % If we used ForeignArg instead of GenericForeignArg, then
        % Var would be unboxed when assigned to Name, which we don't want.
        GenericForeignArg = foreign_arg(Var, yes(Name - in_mode),
            dummy_type_var),
        make_type_info_var(Type, Context, !VarTypes, !VarSet,
            !TableInfo, TypeInfoVar, ExtraGoals),
        TypeInfoName = "save_arg_typeinfo" ++ int_to_string(Offset),
        map__lookup(!.VarTypes, TypeInfoVar, TypeInfoType),
        TypeInfoForeignArg = foreign_arg(TypeInfoVar,
            yes(TypeInfoName - in_mode), TypeInfoType),
        SavePredName = "table_save_any_answer",
        generate_call(SavePredName, det,
            [TypeInfoVar, TableVar, OffsetVar, Var],
            impure_code, [], ModuleInfo, Context, CallGoal),
        Goals = ExtraGoals ++ [CallGoal],
        Args = [GenericForeignArg, TypeInfoForeignArg],
        PrefixGoals = ExtraGoals,
        CodeStr = "\tMR_" ++ SavePredName ++ "(" ++
            answer_block_name ++ ", " ++ int_to_string(Offset) ++ ", " ++
            TypeInfoName ++ ", " ++ Name ++ ");\n"
    ;
        type_save_category(TypeCat, CatString),
        SavePredName = "table_save_" ++ CatString ++ "_answer",
        generate_call(SavePredName, det, [TableVar, OffsetVar, Var],
            impure_code, [], ModuleInfo, Context, Goal),
        Goals = [Goal],
        Args = [ForeignArg],
        PrefixGoals = [],
        CodeStr = "\tMR_" ++ SavePredName ++ "(" ++
            answer_block_name ++ ", " ++ int_to_string(Offset) ++ ", " ++
            Name ++ ");\n"
    ).

%-----------------------------------------------------------------------------%

    % Generate a goal for restoring the output arguments from
    % an answer block in memo predicates.
    %
:- pred generate_memo_restore_goal(list(var_mode_pos_method(T))::in,
    instmap_delta::in, prog_var::in, module_info::in, bool::in,
    term__context::in, vartypes::in, vartypes::out,
    prog_varset::in, prog_varset::out, hlds_goal::out) is det.

generate_memo_restore_goal(NumberedOutputVars, OrigInstMapDelta, TipVar,
        ModuleInfo, TablingViaExtraArgs, Context, !VarTypes, !VarSet, Goal) :-
    (
        NumberedOutputVars = [_ | _],
        OutputVars = list__map(project_var, NumberedOutputVars),
        GetPredName = "table_memo_get_answer_block",
        generate_new_table_var("RestoreBlockVar", answer_block_type,
            !VarTypes, !VarSet, RestoreBlockVar),
        generate_restore_goals(NumberedOutputVars, OrigInstMapDelta,
            RestoreBlockVar, ModuleInfo, Context, !VarTypes, !VarSet,
            RestoreGoals, RestoreInstMapDeltaSrc, RestoreArgs, RestoreCodeStr),
        (
            TablingViaExtraArgs = yes,
            BaseVarName = base_name,
            Arg = foreign_arg(TipVar, yes(BaseVarName - in_mode),
                trie_node_type),
            Args = [Arg],
            DeclCodeStr = "\tMR_AnswerBlock " ++ answer_block_name ++ ";\n",
            ShortcutPredName = GetPredName ++ "_shortcut",
            ShortcutStr = "\tMR_" ++ ShortcutPredName ++ "(" ++
                BaseVarName ++ ");\n",
            GetRestoreCodeStr = "\tMR_" ++ GetPredName ++ "(" ++
                BaseVarName ++ ", " ++ answer_block_name ++ ");\n" ++
                RestoreCodeStr,
            table_generate_foreign_proc(ShortcutPredName, det,
                tabling_c_attributes, Args, RestoreArgs, DeclCodeStr,
                ShortcutStr, GetRestoreCodeStr, impure_code,
                RestoreInstMapDeltaSrc, ModuleInfo, Context, ShortcutGoal),
            Goal = ShortcutGoal
        ;
            TablingViaExtraArgs = no,
            generate_call(GetPredName, det, [TipVar, RestoreBlockVar],
                semipure_code, ground_vars([RestoreBlockVar]),
                ModuleInfo, Context, GetBlockGoal),
            GoalExpr = conj([GetBlockGoal | RestoreGoals]),
            set__list_to_set([TipVar | OutputVars], NonLocals),
            goal_info_init_hide(NonLocals, OrigInstMapDelta,
                det, purity_semipure, Context, GoalInfo),
            Goal = GoalExpr - GoalInfo
        )
    ;
        NumberedOutputVars = [],
        true_goal(Goal)
    ).

    % Generate a goal for restoring the output arguments from
    % an answer block in model_non memo predicates.
    %
:- pred generate_memo_non_restore_goal(determinism::in,
    list(var_mode_pos_method)::in, instmap_delta::in, prog_var::in,
    module_info::in, term__context::in, vartypes::in, vartypes::out,
    prog_varset::in, prog_varset::out, hlds_goal::out) is det.

generate_memo_non_restore_goal(Detism, NumberedOutputVars, OrigInstMapDelta,
        RecordVar, ModuleInfo, Context, !VarTypes, !VarSet, Goal) :-
    ( Detism = multidet ->
        ReturnAllAns = "table_memo_return_all_answers_multi"
    ; Detism = nondet ->
        ReturnAllAns = "table_memo_return_all_answers_nondet"
    ;
        unexpected(this_file, "generate_mm_restore_goal: invalid determinism")
    ),
    generate_new_table_var("AnswerBlock", answer_block_type,
        !VarTypes, !VarSet, AnswerBlockVar),
    generate_call(ReturnAllAns, Detism, [RecordVar, AnswerBlockVar],
        semipure_code, ground_vars([AnswerBlockVar]), ModuleInfo,
        Context, ReturnAnswerBlocksGoal),
    generate_restore_goals(NumberedOutputVars, OrigInstMapDelta,
        AnswerBlockVar, ModuleInfo, Context, !VarTypes, !VarSet,
        _RestoreGoals, RestoreInstMapDeltaSrc, RestoreArgs, RestoreCodeStr),
    OutputVars = list__map(project_var, NumberedOutputVars),
    Arg = foreign_arg(AnswerBlockVar, yes(answer_block_name - in_mode),
        answer_block_type),
    Args = [Arg],
    ShortcutPredName = "table_memo_non_return_all_shortcut",
    ShortcutStr = "\tMR_" ++ ShortcutPredName ++ "(" ++
        answer_block_name ++ ");\n",
    table_generate_foreign_proc(ShortcutPredName, det, tabling_c_attributes,
        Args, RestoreArgs, "", ShortcutStr, RestoreCodeStr, impure_code,
        RestoreInstMapDeltaSrc, ModuleInfo, Context, ShortcutGoal),

    GoalExpr = conj([ReturnAnswerBlocksGoal, ShortcutGoal]),
    set__list_to_set([RecordVar | OutputVars], NonLocals),
    goal_info_init_hide(NonLocals, OrigInstMapDelta, Detism, purity_semipure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

    % Generate a goal for restoring the output arguments from
    % an answer block in minimal model predicates without a suspension.
    %
:- pred generate_mm_restore_goal(determinism::in,
    list(var_mode_pos_method)::in, instmap_delta::in, prog_var::in,
    module_info::in, bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    hlds_goal::out) is det.

generate_mm_restore_goal(Detism, NumberedOutputVars, OrigInstMapDelta,
        SubgoalVar, ModuleInfo, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, Goal) :-
    ( Detism = multidet ->
        ReturnAllAns = "table_mm_return_all_multi"
    ; Detism = nondet ->
        ReturnAllAns = "table_mm_return_all_nondet"
    ;
        unexpected(this_file, "generate_mm_restore_goal: invalid determinism")
    ),
    generate_mm_restore_or_suspend_goal(ReturnAllAns, Detism, purity_semipure,
        NumberedOutputVars, OrigInstMapDelta, SubgoalVar, ModuleInfo,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, Goal).

    % Generate a goal for restoring the output arguments from
    % an answer block in minimal model predicates after a suspension.
    %
:- pred generate_mm_suspend_goal(list(var_mode_pos_method)::in,
    instmap_delta::in, prog_var::in, module_info::in,
    bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    hlds_goal::out) is det.

generate_mm_suspend_goal(NumberedOutputVars, OrigInstMapDelta, SubgoalVar,
        ModuleInfo, TablingViaExtraArgs, Context, !VarTypes, !VarSet, Goal) :-
    generate_mm_restore_or_suspend_goal("table_mm_suspend_consumer",
        nondet, purity_impure, NumberedOutputVars, OrigInstMapDelta,
        SubgoalVar, ModuleInfo, TablingViaExtraArgs, Context,
        !VarTypes, !VarSet, Goal).

    % Generate a goal for restoring the output arguments from
    % an answer block in minimal model predicates. Whether the restore
    % is after a suspension depends on the arguments.
    %
:- pred generate_mm_restore_or_suspend_goal(string::in, determinism::in,
    purity::in, list(var_mode_pos_method)::in, instmap_delta::in,
    prog_var::in, module_info::in, bool::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    hlds_goal::out) is det.

generate_mm_restore_or_suspend_goal(PredName, Detism, Purity,
        NumberedOutputVars, OrigInstMapDelta, SubgoalVar, ModuleInfo,
        TablingViaExtraArgs, Context, !VarTypes, !VarSet, Goal) :-
    generate_new_table_var("AnswerBlock", answer_block_type,
        !VarTypes, !VarSet, AnswerBlockVar),
    generate_call(PredName, Detism, [SubgoalVar, AnswerBlockVar],
        semipure_code, ground_vars([AnswerBlockVar]), ModuleInfo,
        Context, ReturnAnswerBlocksGoal),
    generate_restore_goals(NumberedOutputVars, OrigInstMapDelta,
        AnswerBlockVar, ModuleInfo, Context, !VarTypes, !VarSet,
        RestoreGoals, RestoreInstMapDeltaSrc, RestoreArgs, RestoreCodeStr),
    OutputVars = list__map(project_var, NumberedOutputVars),
    (
        TablingViaExtraArgs = yes,
        Arg = foreign_arg(AnswerBlockVar,
            yes(answer_block_name - in_mode), answer_block_type),
        Args = [Arg],
        ShortcutPredName = "table_mm_return_all_shortcut",
        ShortcutStr = "\tMR_" ++ ShortcutPredName ++ "(" ++
            answer_block_name ++ ");\n",
        table_generate_foreign_proc(ShortcutPredName, det,
            tabling_c_attributes, Args, RestoreArgs, "", ShortcutStr,
            RestoreCodeStr, impure_code, RestoreInstMapDeltaSrc, ModuleInfo,
            Context, ShortcutGoal),
        GoalExpr = conj([ReturnAnswerBlocksGoal, ShortcutGoal])
    ;
        TablingViaExtraArgs = no,
        GoalExpr = conj([ReturnAnswerBlocksGoal | RestoreGoals])
    ),
    set__list_to_set([SubgoalVar | OutputVars], NonLocals),
    goal_info_init_hide(NonLocals, OrigInstMapDelta, Detism, Purity,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

    % Generate a sequence of restore goals for the given variables.
    %
:- pred generate_restore_goals(list(var_mode_pos_method(T))::in,
    instmap_delta::in, prog_var::in, module_info::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    list(hlds_goal)::out, assoc_list(prog_var, mer_inst)::out,
    list(foreign_arg)::out, string::out) is det.

generate_restore_goals([], _, _, _, _, !VarTypes, !VarSet, [], [], [], "").
generate_restore_goals([NumberedVar | NumberedRest], OrigInstmapDelta,
        AnswerBlockVar, ModuleInfo, Context, !VarTypes, !VarSet,
        [OffsetUnifyGoal, CallGoal | RestGoals], [VarInst | VarInsts],
        [Arg | Args], CodeStr ++ RestCodeStr) :-
    NumberedVar = var_mode_pos_method(Var, _Mode, Offset, _),
    gen_int_construction("OffsetVar", Offset, !VarTypes, !VarSet,
        OffsetVar, OffsetUnifyGoal),
    map__lookup(!.VarTypes, Var, VarType),
    classify_type(ModuleInfo, VarType) = TypeCat,
    gen_restore_call_for_type(TypeCat, VarType, OrigInstmapDelta,
        AnswerBlockVar, Var, Offset, OffsetVar, ModuleInfo, Context,
        CallGoal, VarInst, Arg, CodeStr),
    generate_restore_goals(NumberedRest, OrigInstmapDelta, AnswerBlockVar,
        ModuleInfo, Context, !VarTypes, !VarSet, RestGoals, VarInsts,
        Args, RestCodeStr).

:- pred gen_restore_call_for_type(type_category::in, mer_type::in,
    instmap_delta::in, prog_var::in, prog_var::in, int::in, prog_var::in,
    module_info::in, term__context::in, hlds_goal::out,
    pair(prog_var, mer_inst)::out, foreign_arg::out, string::out) is det.

gen_restore_call_for_type(TypeCat, Type, OrigInstmapDelta, TableVar, Var,
        Offset, OffsetVar, ModuleInfo, Context, Goal, Var - Inst, Arg,
        CodeStr) :-
    Name = "restore_arg" ++ int_to_string(Offset),
    ( type_util__type_is_io_state(Type) ->
        RestorePredName = "table_restore_io_state_answer",
        ArgType = Type
    ; builtin_type(TypeCat) = no ->
        RestorePredName = "table_restore_any_answer",
        ArgType = dummy_type_var
    ;
        type_save_category(TypeCat, CatString),
        RestorePredName = "table_restore_" ++ CatString ++ "_answer",
        ArgType = Type
    ),
    ( instmap_delta_search_var(OrigInstmapDelta, Var, InstPrime) ->
        Inst = InstPrime
    ;
        unexpected(this_file, "gen_restore_call_for_type: no inst")
    ),
    Arg = foreign_arg(Var, yes(Name - (free -> Inst)), ArgType),
    CodeStr = "\tMR_" ++ RestorePredName ++ "(" ++ answer_block_name ++ ", "
        ++ int_to_string(Offset) ++ ", " ++ Name ++ ");\n",
    generate_call(RestorePredName, det, [TableVar, OffsetVar, Var],
        semipure_code, [Var - Inst], ModuleInfo, Context, Goal).

%-----------------------------------------------------------------------------%

:- func infinite_recursion_msg = string.

infinite_recursion_msg = "detected infinite recursion".

:- func need_minimal_model_msg = string.

need_minimal_model_msg = "detected need for minimal model".

:- pred generate_error_goal(table_info::in, term__context::in,
    string::in, vartypes::in, vartypes::out,
    prog_varset::in, prog_varset::out, hlds_goal::out) is det.

generate_error_goal(TableInfo, Context, Msg, !VarTypes, !VarSet, Goal) :-
    ModuleInfo = TableInfo ^ table_module_info,
    PredInfo = TableInfo ^ table_cur_pred_info,

    Module = pred_info_module(PredInfo),
    Name = pred_info_name(PredInfo),
    Arity = pred_info_orig_arity(PredInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    PredOrFuncStr = pred_or_func_to_str(PredOrFunc),
    sym_name_to_string(qualified(Module, Name), NameStr),
    string__int_to_string(Arity, ArityStr),
    Message = Msg ++ " in " ++ PredOrFuncStr ++ " " ++ NameStr
        ++ "/" ++ ArityStr,

    gen_string_construction("Message", Message, !VarTypes, !VarSet,
        MessageVar, MessageStrGoal),
    generate_call("table_error", erroneous, [MessageVar], pure_code, [],
        ModuleInfo, Context, CallGoal),

    GoalExpr = conj([MessageStrGoal, CallGoal]),
    goal_info_init_hide(set__init, bind_vars([]), erroneous, purity_impure,
        Context, GoalInfo),
    Goal = GoalExpr - GoalInfo.

%-----------------------------------------------------------------------------%

:- pred generate_new_table_var(string::in, mer_type::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    prog_var::out) is det.

generate_new_table_var(Name, Type, !VarTypes, !VarSet, Var) :-
    varset__new_named_var(!.VarSet, Name, Var, !:VarSet),
    map__set(!.VarTypes, Var, Type, !:VarTypes).

:- type impure_or_semipure
    --->    impure_code
    ;       semipure_code
    ;       pure_code.

:- func impure_or_semipure_to_features(impure_or_semipure)
    = list(goal_feature).

impure_or_semipure_to_features(impure_code) =
    [impure_goal, not_impure_for_determinism].
impure_or_semipure_to_features(semipure_code) =
    [semipure_goal, not_impure_for_determinism].
impure_or_semipure_to_features(pure_code) = [].

:- pred generate_call(string::in, determinism::in, list(prog_var)::in,
    impure_or_semipure::in, assoc_list(prog_var, mer_inst)::in,
    module_info::in, term__context::in, hlds_goal::out) is det.

generate_call(PredName, Detism, Args, Purity, InstMapSrc,
        ModuleInfo, Context, Goal) :-
    mercury_table_builtin_module(BuiltinModule),
    Features0 = impure_or_semipure_to_features(Purity),
    ( Detism = failure ->
        Features = [preserve_backtrack_into | Features0]
    ;
        Features = Features0
    ),
    goal_util__generate_simple_call(BuiltinModule, PredName, predicate,
        only_mode, Detism, Args, Features, InstMapSrc, ModuleInfo,
        Context, Goal).

:- pred table_generate_foreign_proc(string::in, determinism::in,
    pragma_foreign_proc_attributes::in,
    list(foreign_arg)::in, list(foreign_arg)::in, string::in, string::in,
    string::in, impure_or_semipure::in, assoc_list(prog_var, mer_inst)::in,
    module_info::in, term__context::in, hlds_goal::out) is det.

table_generate_foreign_proc(PredName, Detism, Attributes, Args, ExtraArgs,
        PrefixCode, Code, SuffixCode, Purity, InstMapSrc,
        ModuleInfo, Context, Goal) :-
    mercury_table_builtin_module(BuiltinModule),
    Features0 = impure_or_semipure_to_features(Purity),
    ( Detism = failure ->
        Features = [preserve_backtrack_into | Features0]
    ;
        Features = Features0
    ),
    goal_util__generate_foreign_proc(BuiltinModule, PredName, predicate,
        only_mode, Detism, Attributes, Args, ExtraArgs,
        PrefixCode, Code, SuffixCode, Features, InstMapSrc,
        ModuleInfo, Context, Goal).

:- pred append_fail(hlds_goal::in, hlds_goal::out) is det.

append_fail(Goal, GoalAndThenFail) :-
    Goal = _ - GoalInfo,
    goal_info_get_nonlocals(GoalInfo, NonLocals),
    goal_info_get_context(GoalInfo, Context),
    instmap_delta_init_unreachable(UnreachInstMapDelta),
    goal_info_init_hide(NonLocals, UnreachInstMapDelta, failure, purity_impure,
        Context, ConjGoalInfo),
    fail_goal(FailGoal),
    GoalAndThenFail = conj([Goal, FailGoal]) - ConjGoalInfo.

:- pred gen_int_construction(string::in, int::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    prog_var::out, hlds_goal::out) is det.

gen_int_construction(VarName, VarValue, !VarTypes, !VarSet, Var, Goal) :-
    make_int_const_construction_alloc(VarValue, yes(VarName), Goal, Var,
        !VarTypes, !VarSet).

:- pred gen_string_construction(string::in, string::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    prog_var::out, hlds_goal::out) is det.

gen_string_construction(VarName, VarValue, !VarTypes, !VarSet, Var, Goal) :-
    make_string_const_construction_alloc(VarValue, yes(VarName), Goal, Var,
        !VarTypes, !VarSet).

:- func trie_node_type = mer_type.
:- func memo_non_record_type = mer_type.
:- func subgoal_type = mer_type.
:- func answer_block_type = mer_type.
:- func loop_status_type = mer_type.
:- func memo_det_status_type = mer_type.
:- func memo_semi_status_type = mer_type.
:- func memo_non_status_type = mer_type.
:- func mm_status_type = mer_type.

trie_node_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "ml_trie_node") - 0, [], Type).

memo_non_record_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "memo_non_record") - 0, [], Type).

subgoal_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "ml_subgoal") - 0, [], Type).

answer_block_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "ml_answer_block") - 0, [], Type).

loop_status_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "loop_status") - 0, [], Type).

memo_det_status_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "memo_det_status") - 0, [], Type).

memo_semi_status_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "memo_semi_status") - 0, [], Type).

memo_non_status_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "memo_non_status") - 0, [], Type).

mm_status_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "mm_status") - 0, [], Type).

%-----------------------------------------------------------------------------%

:- func consumer_type = mer_type.

consumer_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "ml_consumer") - 0, [], Type).

:- func generator_type = mer_type.

generator_type = Type :-
    mercury_table_builtin_module(TB),
    construct_type(qualified(TB, "ml_generator") - 0, [], Type).

:- type maybe_specified_method
    --->    all_same(arg_tabling_method)
    ;       specified(list(maybe(arg_tabling_method))).

:- pred get_input_output_vars(list(prog_var)::in, list(mer_mode)::in,
    module_info::in, maybe_specified_method::in, maybe_specified_method::out,
    list(var_mode_method)::out, list(var_mode_method)::out) is det.

get_input_output_vars([], [], _, !MaybeSpecMethod, [], []).
get_input_output_vars([_ | _], [], _, !MaybeSpecMethod, _, _) :-
    unexpected(this_file, "get_input_output_vars: lists not same length").
get_input_output_vars([], [_ | _], _, !MaybeSpecMethod, _, _) :-
    unexpected(this_file, "get_input_output_vars: lists not same length").
get_input_output_vars([Var | Vars], [Mode | Modes], ModuleInfo,
        !MaybeSpecMethod, InVarModes, OutVarModes) :-
    ( mode_is_fully_input(ModuleInfo, Mode) ->
        get_input_output_vars(Vars, Modes, ModuleInfo, !MaybeSpecMethod,
            InVarModes0, OutVarModes),
        (
            !.MaybeSpecMethod = all_same(ArgMethod)
        ;
            !.MaybeSpecMethod = specified(MaybeArgMethods0),
            (
                list__split_last(MaybeArgMethods0, MaybeArgMethods,
                    LastMaybeArgMethod)
            ->
                (
                    LastMaybeArgMethod = yes(ArgMethod)
                ;
                    LastMaybeArgMethod = no,
                    error("get_input_output_vars: bad method for input var")
                ),
                !:MaybeSpecMethod = specified(MaybeArgMethods)
            ;
                % We have run out of specified arg_methods, which means the
                % variable we are looking at right now is one that was added
                % by the polymorphism transformation.
                ArgMethod = arg_value,
                !:MaybeSpecMethod = all_same(arg_value)
            )
        ),
        InVarModes = [var_mode_method(Var, Mode, ArgMethod) | InVarModes0]
    ; mode_is_fully_output(ModuleInfo, Mode) ->
        get_input_output_vars(Vars, Modes, ModuleInfo, !MaybeSpecMethod,
            InVarModes, OutVarModes0),
        (
            !.MaybeSpecMethod = all_same(_ArgMethod)
            % The tabling methods that use answer tables always use arg_value
            % to look up computed output arguments in them. The argument of
            % all_same refers only to the treatment of input arguments.
        ;
            !.MaybeSpecMethod = specified(MaybeArgMethods0),
            (
                list__split_last(MaybeArgMethods0, MaybeArgMethods,
                    LastMaybeArgMethod)
            ->
                require(unify(LastMaybeArgMethod, no),
                    "get_input_output_vars: bad method for output var"),
                !:MaybeSpecMethod = specified(MaybeArgMethods)
            ;
                % We have run out of specified arg_methods, which means the
                % variable we are looking at right now is one that was added
                % by the polymorphism transformation.
                !:MaybeSpecMethod = all_same(arg_value)
            )
        ),
        OutVarModes = [var_mode_method(Var, Mode, arg_value) | OutVarModes0]
    ;
        % We should have caught this when we added the tabling pragma
        % to the proc_info.
        unexpected(this_file, "get_input_output_vars: bad var")
    ).

%-----------------------------------------------------------------------------%

:- pred create_instmap_delta(hlds_goals::in, instmap_delta::out) is det.

create_instmap_delta([], IMD) :-
    instmap_delta_from_assoc_list([], IMD).
create_instmap_delta([Goal | Rest], IMD) :-
    Goal = _ - GoalInfo,
    goal_info_get_instmap_delta(GoalInfo, IMD0),
    create_instmap_delta(Rest, IMD1),
    instmap_delta_apply_instmap_delta(IMD0, IMD1, test_size, IMD).

%-----------------------------------------------------------------------------%

:- type var_mode_method
    --->    var_mode_method(
                prog_var,   % The head variable.
                mer_mode,   % The mode of the head variable.
                arg_tabling_method
                            % For input arguments, this is the arg method to
                            % use in looking up the argument in the call table.
                            % For output arguments, this is the arg method to
                            % use in looking up the argument in the answer
                            % table (if any).
            ).

:- type var_mode_pos_method == var_mode_pos_method(arg_tabling_method).

:- type var_mode_pos_method(T)
    --->    var_mode_pos_method(
                prog_var,   % The head variable.
                mer_mode,   % The mode of the head variable.
                int,        % The position of the head variable in the list of
                            % inputs or outputs; first element is in the
                            % position numbered 0.
                T
                            % For input arguments, this is the arg method to
                            % use in looking up the argument in the call table.
                            % For output arguments, this is the arg method to
                            % use in looking up the argument in the answer
                            % table (if any), which for now is always
                            % arg_value.
                            %
                            % When T is unit, there is no info about how to
                            % look up the variable in a call or return table.
                            % This is useful for recording the structure of
                            % answer blocks and sequences of arguments
                            % for I/O tabling.
            ).

:- func project_var(var_mode_pos_method(T)) = prog_var.

project_var(var_mode_pos_method(Var, _, _, _)) = Var.

:- func project_var_pos(var_mode_pos_method(T)) = pair(prog_var, int).

project_var_pos(var_mode_pos_method(Var, _, Pos, _)) = Var - Pos.

:- func project_var_init_inst(module_info, var_mode_pos_method(T)) =
    pair(prog_var, mer_inst).

project_var_init_inst(ModuleInfo, var_mode_pos_method(Var, Mode, _, _))
        = Var - Inst :-
    mode_get_insts(ModuleInfo, Mode, Inst, _).

:- func project_mode(var_mode_pos_method(T)) = mer_mode.

project_mode(var_mode_pos_method(_, Mode, _, _)) = Mode.

:- func project_out_arg_method(var_mode_pos_method) =
    var_mode_pos_method(unit).

project_out_arg_method(var_mode_pos_method(Var, Mode, Pos, _)) =
    var_mode_pos_method(Var, Mode, Pos, unit).

:- pred allocate_slot_numbers(list(var_mode_method)::in,
    int::in, list(var_mode_pos_method)::out) is det.

allocate_slot_numbers([], _, []).
allocate_slot_numbers([var_mode_method(Var, Mode, ArgMethod) | VarModes],
        Offset0, [VarModePos | VarModePoss]) :-
    VarModePos = var_mode_pos_method(Var, Mode, Offset0, ArgMethod),
    allocate_slot_numbers(VarModes, Offset0 + 1, VarModePoss).

:- pred allocate_plain_slot_numbers(assoc_list(prog_var, mer_mode)::in,
    int::in, list(var_mode_pos_method(unit))::out) is det.

allocate_plain_slot_numbers([], _, []).
allocate_plain_slot_numbers([Var - Mode | VarModes],
        Offset0, [VarModePos | VarModePoss]) :-
    VarModePos = var_mode_pos_method(Var, Mode, Offset0, unit),
    allocate_plain_slot_numbers(VarModes, Offset0 + 1, VarModePoss).

:- pred reallocate_slot_numbers(list(var_mode_pos_method(T))::in, int::in,
    list(var_mode_pos_method(T))::out) is det.

reallocate_slot_numbers([], _, []).
reallocate_slot_numbers([VarModePos0 | VarModes], Offset0,
        [VarModePos | VarModePoss]) :-
    VarModePos0 = var_mode_pos_method(Var, Mode, _, ArgMethod),
    VarModePos = var_mode_pos_method(Var, Mode, Offset0, ArgMethod),
    reallocate_slot_numbers(VarModes, Offset0 + 1, VarModePoss).

:- pred var_belong_to_list(list(prog_var)::in, var_mode_pos_method(T)::in)
    is semidet.

var_belong_to_list(List, var_mode_pos_method(Var, _, _, _)) :-
    list__member(Var, List).

:- func bind_vars(list(prog_var)) = instmap_delta.

bind_vars(Vars) = InstMapDelta :-
    VarsAndGround = ground_vars(Vars),
    instmap_delta_from_assoc_list(VarsAndGround, InstMapDelta).

:- func ground_vars(list(prog_var)) = assoc_list(prog_var, mer_inst).

ground_vars(Vars) = VarsAndGround :-
    VarsAndGround = list__map(pair_with_ground, Vars).

:- func pair_with_ground(prog_var) = pair(prog_var, mer_inst).

pair_with_ground(Var) = Var - ground(shared, none).

:- pred goal_info_init_hide(set(prog_var)::in, instmap_delta::in,
    determinism::in, purity::in, prog_context::in, hlds_goal_info::out)
    is det.

goal_info_init_hide(NonLocals, InstmapDelta, Detism, Purity, Context,
        GoalInfo) :-
    goal_info_init(NonLocals, InstmapDelta, Detism, Purity, Context,
        GoalInfo0),
    goal_info_add_feature(hide_debug_event, GoalInfo0, GoalInfo).

%-----------------------------------------------------------------------------%

% For backward compatibility, we treat type_info_type as user_type. This
% used to make the tabling of type_infos more expensive than necessary, since
% we essentially tabled the information in the type_info twice, once by tabling
% the type represented by the type_info (since this was the value of the type
% argument of the type constructor private_builtin.type_info/1), and then
% tabling the type_info itself. However, since we made type_info have arity
% zero, this overhead should be gone.

:- func builtin_type(type_category) = bool.

builtin_type(int_type) = yes.
builtin_type(char_type) = yes.
builtin_type(str_type) = yes.
builtin_type(float_type) = yes.
builtin_type(void_type) = yes.
builtin_type(type_info_type) = no.
builtin_type(type_ctor_info_type) = yes.
builtin_type(typeclass_info_type) = yes.
builtin_type(base_typeclass_info_type) = yes.
builtin_type(higher_order_type) = no.
builtin_type(enum_type) = no.
builtin_type(dummy_type) = no.
builtin_type(variable_type) = no.
builtin_type(tuple_type) = no.
builtin_type(user_ctor_type) = no.

% Figure out what kind of data structure implements the lookup table for values
% of a given builtin type.

:- pred lookup_tabling_category(type_category::in,
    maybe(pair(string, table_trie_step))::out) is det.

lookup_tabling_category(int_type,   yes("int" -    table_trie_step_int)).
lookup_tabling_category(char_type,  yes("char" -   table_trie_step_char)).
lookup_tabling_category(str_type,   yes("string" - table_trie_step_string)).
lookup_tabling_category(float_type, yes("float" -  table_trie_step_float)).
lookup_tabling_category(void_type, _) :-
    unexpected(this_file, "lookup_tabling_category: void").
lookup_tabling_category(dummy_type, _) :-
    unexpected(this_file, "lookup_tabling_category: dummy_type").
lookup_tabling_category(type_info_type,
        yes("typeinfo" - table_trie_step_typeinfo)).
lookup_tabling_category(type_ctor_info_type,
        yes("typeinfo" - table_trie_step_typeinfo)).
lookup_tabling_category(typeclass_info_type, _) :-
    unexpected(this_file, "lookup_tabling_category: typeclass_info_type").
lookup_tabling_category(base_typeclass_info_type, _) :-
    unexpected(this_file, "lookup_tabling_category: base_typeclass_info_type").
lookup_tabling_category(enum_type, no).
lookup_tabling_category(higher_order_type, no).
lookup_tabling_category(tuple_type, no).
lookup_tabling_category(variable_type, no).
lookup_tabling_category(user_ctor_type, no).

% Figure out which save and restore predicates in library/table_builtin.m
% we need to use for values of types belonging the type category given by
% the first argument. The returned value replaces CAT in table_save_CAT_answer
% and table_restore_CAT_answer.

:- pred type_save_category(type_category::in, string::out) is det.

type_save_category(enum_type,       "enum").
type_save_category(int_type,        "int").
type_save_category(char_type,       "char").
type_save_category(str_type,        "string").
type_save_category(float_type,      "float").
type_save_category(higher_order_type,   "pred").
type_save_category(tuple_type,      "any").
type_save_category(user_ctor_type,  "any").     % could do better
type_save_category(variable_type,   "any").     % could do better
type_save_category(dummy_type, _) :-
    unexpected(this_file, "type_save_category: dummy").
type_save_category(void_type, _) :-
    unexpected(this_file, "type_save_category: void").
type_save_category(type_info_type, "any").      % could do better
type_save_category(type_ctor_info_type, _) :-
    unexpected(this_file, "type_save_category: type_ctor_info").
type_save_category(typeclass_info_type, _) :-
    unexpected(this_file, "type_save_category: typeclass_info").
type_save_category(base_typeclass_info_type, _) :-
    unexpected(this_file, "type_save_category: base_typeclass_info").

%-----------------------------------------------------------------------------%

:- pred table_gen__make_type_info_var(mer_type::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, prog_var::out,
    list(hlds_goal)::out) is det.

table_gen__make_type_info_var(Type, Context, !VarTypes, !VarSet, !TableInfo,
        TypeInfoVar, TypeInfoGoals) :-
    table_gen__make_type_info_vars([Type], Context, !VarTypes, !VarSet,
        !TableInfo, TypeInfoVars, TypeInfoGoals),
    ( TypeInfoVars = [TypeInfoVar0] ->
        TypeInfoVar = TypeInfoVar0
    ;
        unexpected(this_file,
            "table_gen__make_type_info_var: list length != 1")
    ).

:- pred table_gen__make_type_info_vars(list(mer_type)::in, term__context::in,
    vartypes::in, vartypes::out, prog_varset::in, prog_varset::out,
    table_info::in, table_info::out, list(prog_var)::out,
    list(hlds_goal)::out) is det.

table_gen__make_type_info_vars(Types, Context, !VarTypes, !VarSet, !TableInfo,
        TypeInfoVars, TypeInfoGoals) :-
    %
    % Extract the information from table_info
    %
    table_info_extract(!.TableInfo, ModuleInfo0, PredInfo0, ProcInfo0),

    %
    % Put the varset and vartypes from the simplify_info
    % back in the proc_info
    %
    proc_info_set_vartypes(!.VarTypes, ProcInfo0, ProcInfo1),
    proc_info_set_varset(!.VarSet, ProcInfo1, ProcInfo2),

    %
    % Call polymorphism.m to create the type_infos
    %
    create_poly_info(ModuleInfo0, PredInfo0, ProcInfo2, PolyInfo0),
    polymorphism__make_type_info_vars(Types, Context,
        TypeInfoVars, TypeInfoGoals, PolyInfo0, PolyInfo),
    poly_info_extract(PolyInfo, PredInfo0, PredInfo,
        ProcInfo0, ProcInfo, ModuleInfo),

    %
    % Get the new varset and vartypes from the proc_info
    %
    proc_info_vartypes(ProcInfo, !:VarTypes),
    proc_info_varset(ProcInfo, !:VarSet),

    %
    % Put the new module_info, pred_info, and proc_info back in the
    % table_info.
    %
    table_info_init(ModuleInfo, PredInfo, ProcInfo, !:TableInfo).

%-----------------------------------------------------------------------------%

:- pred table_gen__var_mode_pos_is_io_state(vartypes::in,
    var_mode_pos_method::in) is semidet.

table_gen__var_mode_pos_is_io_state(VarTypes, VarModePosMethod) :-
    table_gen__var_is_io_state(VarTypes, project_var(VarModePosMethod)).

:- pred table_gen__var_mode_is_io_state(vartypes::in,
    pair(prog_var, mer_mode)::in) is semidet.

table_gen__var_mode_is_io_state(VarTypes, Var - _) :-
    table_gen__var_is_io_state(VarTypes, Var).

:- pred table_gen__var_is_io_state(vartypes::in, prog_var::in) is semidet.

table_gen__var_is_io_state(VarTypes, Var) :-
    map__lookup(VarTypes, Var, VarType),
    type_util__type_is_io_state(VarType).

%-----------------------------------------------------------------------------%

:- pred tabling_via_extra_args(module_info::in, bool::out) is det.

tabling_via_extra_args(ModuleInfo, TablingViaExtraArgs) :-
    module_info_get_globals(ModuleInfo, Globals),
    globals__lookup_bool_option(Globals, tabling_via_extra_args,
        TablingViaExtraArgs).

:- func tabling_c_attributes = pragma_foreign_proc_attributes.

tabling_c_attributes = Attrs :-
    Attrs0 = default_attributes(c),
    set_may_call_mercury(will_not_call_mercury, Attrs0, Attrs).

:- func make_generator_c_attributes = pragma_foreign_proc_attributes.

make_generator_c_attributes = Attrs :-
    Attrs0 = default_attributes(c),
    set_may_call_mercury(may_call_mercury, Attrs0, Attrs).

:- func dummy_type_var = mer_type.

dummy_type_var = Type :-
    varset__init(DummyTVarSet0),
    varset__new_var(DummyTVarSet0, DummyTVar, _),
    Type = variable(DummyTVar, star).

%-----------------------------------------------------------------------------%

:- func pred_table_name = string.
:- func cur_table_node_name = string.
:- func next_table_node_name = string.
:- func table_tip_node_name = string.
:- func base_name = string.
:- func memo_non_record_name = string.
:- func subgoal_name = string.
:- func status_name = string.
:- func answer_block_name = string.
:- func success_indicator_name = string.
:- func arg_name(int) = string.
:- func num_input_args_name = string.
:- func pred_name_var_name = string.
:- func answer_table_name = string.
:- func consumer_name = string.
:- func generator_name = string.
:- func generator_pred_name = string.

pred_table_name = "pred_table".
cur_table_node_name = "cur_node".
next_table_node_name = "next_node".
table_tip_node_name = "table_tip".
base_name = "base".
memo_non_record_name = "record".
subgoal_name = "subgoal".
status_name = "status".
answer_block_name = "answerblock".
success_indicator_name = "SUCCESS_INDICATOR".
arg_name(VarSeqNum) = "arg" ++ int_to_string(VarSeqNum).
num_input_args_name = "num_input_args".
pred_name_var_name = "pred_name".
answer_table_name = "answer_table".
consumer_name = "consumer".
generator_name = "generator".
generator_pred_name = "generator_pred".

%-----------------------------------------------------------------------------%

:- type table_info
    ---> table_info(
            table_module_info   :: module_info,
            table_cur_pred_info :: pred_info,
            table_cur_proc_info :: proc_info
        ).

:- pred table_info_init(module_info::in,
    pred_info::in, proc_info::in, table_info::out) is det.

:- pred table_info_extract(table_info::in, module_info::out,
    pred_info::out, proc_info::out) is det.

table_info_init(ModuleInfo, PredInfo, ProcInfo, TableInfo) :-
    TableInfo = table_info(ModuleInfo, PredInfo, ProcInfo).

table_info_extract(TableInfo, ModuleInfo, PredInfo, ProcInfo) :-
    TableInfo = table_info(ModuleInfo, PredInfo, ProcInfo).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "table.m".

%-----------------------------------------------------------------------------%
