%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: introduce_parallelism.m.
% Main author: pbone.
%
% This module uses deep profiling feedback information generated by
% mdprof_create_feedback to introduce parallel conjunctions where it could be
% worthwhile (implicit parallelism). It deals with both independent and
% dependent parallelism.
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.implicit_parallelism.introduce_parallelism.
:- interface.

:- import_module hlds.hlds_module.

:- import_module io.

%-----------------------------------------------------------------------------%

    % apply_implicit_parallelism_transformation(!ModuleInfo, !IO)
    %
    % Apply the implicit parallelism transformation using the specified
    % feedback file.
    %
:- pred apply_implicit_parallelism_transformation(
    module_info::in, module_info::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds.goal_util.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_pred.
:- import_module hlds.instmap.
:- import_module hlds.pred_table.
:- import_module libs.globals.
:- import_module ll_backend.
:- import_module ll_backend.prog_rep.
:- import_module ll_backend.stack_layout.
:- import_module mdbcomp.feedback.
:- import_module mdbcomp.feedback.automatic_parallelism.
:- import_module mdbcomp.goal_path.
:- import_module mdbcomp.prim_data.
:- import_module mdbcomp.sym_name.
:- import_module mdbcomp.program_representation.
:- import_module parse_tree.error_util.
:- import_module parse_tree.prog_data.
:- import_module transform_hlds.implicit_parallelism.push_goals_together.

:- import_module assoc_list.
:- import_module bool.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module string.
:- import_module term.

%-----------------------------------------------------------------------------%

apply_implicit_parallelism_transformation(!ModuleInfo, !IO) :-
    module_info_get_globals(!.ModuleInfo, Globals),
    io_get_maybe_source_file_map(MaybeSourceFileMap, !IO),
    (
        MaybeSourceFileMap = yes(SourceFileMap)
    ;
        MaybeSourceFileMap = no,
        unexpected($module, $pred,
            "could not retrieve the source file map")
    ),
    do_apply_implicit_parallelism_transformation(SourceFileMap, Specs,
        !ModuleInfo),
    write_error_specs(Specs, Globals, 0, _, 0, NumErrors, !IO),
    module_info_incr_num_errors(NumErrors, !ModuleInfo).

%-----------------------------------------------------------------------------%

    % This type is used to track whether parallelism has been introduced by a
    % predicate.
    %
:- type introduced_parallelism
    --->    have_not_introduced_parallelism
    ;       introduced_parallelism.

:- pred do_apply_implicit_parallelism_transformation(source_file_map::in,
    list(error_spec)::out, module_info::in, module_info::out) is det.

do_apply_implicit_parallelism_transformation(SourceFileMap, Specs,
        !ModuleInfo) :-
    module_info_get_globals(!.ModuleInfo, Globals0),
    globals.get_maybe_feedback_info(Globals0, MaybeFeedbackInfo),
    module_info_get_name(!.ModuleInfo, ModuleName),
    (
        yes(FeedbackInfo) = MaybeFeedbackInfo,
        get_implicit_parallelism_feedback(ModuleName, FeedbackInfo,
            ParallelismInfo)
    ->
        % Retrieve and process predicates.
        module_info_get_valid_predids(PredIds, !ModuleInfo),
        module_info_get_predicate_table(!.ModuleInfo, PredTable0),
        predicate_table_get_preds(PredTable0, PredMap0),
        list.foldl4(maybe_parallelise_pred(ParallelismInfo),
            PredIds, PredMap0, PredMap,
            have_not_introduced_parallelism, AnyPredIntroducedParallelism,
            !ModuleInfo, [], Specs),
        (
            AnyPredIntroducedParallelism = have_not_introduced_parallelism
        ;
            AnyPredIntroducedParallelism = introduced_parallelism,
            predicate_table_set_preds(PredMap, PredTable0, PredTable),
            module_info_set_predicate_table(PredTable, !ModuleInfo),
            module_info_set_has_parallel_conj(!ModuleInfo)
        )
    ;
        map.lookup(SourceFileMap, ModuleName, ModuleFilename),
        Context = context(ModuleFilename, 1),
        Pieces = [words("Implicit parallelism was requested but the"),
            words("feedback file does not the candidate parallel"),
            words("conjunctions feedback information.")],
        Specs = [error_spec(severity_error, phase_auto_parallelism,
            [simple_msg(Context, [always(Pieces)])])]
    ).

    % Information retrieved from the feedback system to be used for
    % parallelising this module.
    %
:- type parallelism_info
    --->    parallelism_info(
                pi_parameters           :: candidate_par_conjunctions_params,

                % A map of candidate parallel conjunctions in this module
                % indexed by their procedure.
                pi_cpc_map              :: module_candidate_par_conjs_map
            ).

:- type intra_module_proc_label
    --->    intra_module_proc_label(
                im_pred_name            :: string,
                im_arity                :: int,
                im_pred_or_func         :: pred_or_func,
                im_mode                 :: int
            ).

:- type candidate_par_conjunction == candidate_par_conjunction(pard_goal).

:- type seq_conj == seq_conj(pard_goal).

    % A map of the candidate parallel conjunctions indexed by the procedure
    % label for a given module.
    %
:- type module_candidate_par_conjs_map
    == map(intra_module_proc_label, candidate_par_conjunctions_proc).

:- pred get_implicit_parallelism_feedback(module_name::in, feedback_info::in,
    parallelism_info::out) is semidet.

get_implicit_parallelism_feedback(ModuleName, FeedbackInfo, ParallelismInfo) :-
    MaybeCandidates =
        get_feedback_candidate_parallel_conjunctions(FeedbackInfo),
    MaybeCandidates = yes(Candidates),
    Candidates =
        feedback_info_candidate_parallel_conjunctions(Parameters, ProcsConjs),
    make_module_candidate_par_conjs_map(ModuleName, ProcsConjs,
        CandidateParConjsMap),
    ParallelismInfo = parallelism_info(Parameters, CandidateParConjsMap).

:- pred make_module_candidate_par_conjs_map(module_name::in,
    assoc_list(string_proc_label, candidate_par_conjunctions_proc)::in,
    module_candidate_par_conjs_map::out) is det.

make_module_candidate_par_conjs_map(ModuleName,
        CandidateParConjsAssocList0, CandidateParConjsMap) :-
    ModuleNameStr = sym_name_to_string(ModuleName),
    list.filter_map(cpc_proc_is_in_module(ModuleNameStr),
        CandidateParConjsAssocList0, CandidateParConjsAssocList),
    CandidateParConjsMap = map.from_assoc_list(CandidateParConjsAssocList).

:- pred cpc_proc_is_in_module(string::in,
    pair(string_proc_label, candidate_par_conjunctions_proc)::in,
    pair(intra_module_proc_label, candidate_par_conjunctions_proc)::out)
    is semidet.

cpc_proc_is_in_module(ModuleName, ProcLabel - CPC, IMProcLabel - CPC) :-
    (
        ProcLabel = str_ordinary_proc_label(PredOrFunc, _, DefModule, Name,
            Arity, Mode)
    ;
        ProcLabel = str_special_proc_label(_, _, DefModule, Name, Arity, Mode),
        PredOrFunc = pf_predicate
    ),
    ModuleName = DefModule,
    IMProcLabel = intra_module_proc_label(Name, Arity, PredOrFunc, Mode).

%-----------------------------------------------------------------------------%

:- pred maybe_parallelise_pred(parallelism_info::in,
    pred_id::in, pred_table::in, pred_table::out,
    introduced_parallelism::in, introduced_parallelism::out,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

maybe_parallelise_pred(ParallelismInfo, PredId, !PredTable,
        !AnyPredIntroducedParallelism, !ModuleInfo, !Specs) :-
    map.lookup(!.PredTable, PredId, PredInfo0),
    ProcIds = pred_info_non_imported_procids(PredInfo0),
    pred_info_get_procedures(PredInfo0, ProcTable0),
    list.foldl4(maybe_parallelise_proc(ParallelismInfo, PredInfo0, PredId),
        ProcIds, ProcTable0, ProcTable,
        have_not_introduced_parallelism, AnyProcIntroducedParallelism,
        !ModuleInfo, !Specs),
    (
        AnyProcIntroducedParallelism = have_not_introduced_parallelism
    ;
        AnyProcIntroducedParallelism = introduced_parallelism,
        !:AnyPredIntroducedParallelism = introduced_parallelism,
        pred_info_set_procedures(ProcTable, PredInfo0, PredInfo),
        map.det_update(PredId, PredInfo, !PredTable)
    ).

:- pred maybe_parallelise_proc(parallelism_info::in,
    pred_info::in, pred_id::in, proc_id::in, proc_table::in, proc_table::out,
    introduced_parallelism::in, introduced_parallelism::out,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

maybe_parallelise_proc(ParallelismInfo, PredInfo, _PredId, ProcId,
        !ProcTable, !AnyProcIntroducedParallelism, !ModuleInfo, !Specs) :-
    map.lookup(!.ProcTable, ProcId, ProcInfo0),

    % Lookup the Candidate Parallel Conjunction (CPC) Map for this procedure.
    Name = pred_info_name(PredInfo),
    Arity = pred_info_orig_arity(PredInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    Mode = proc_id_to_int(ProcId),
    IMProcLabel = intra_module_proc_label(Name, Arity, PredOrFunc, Mode),
    CPCMap = ParallelismInfo ^ pi_cpc_map,
    ( map.search(CPCMap, IMProcLabel, CPCProc) ->
        proc_info_get_has_parallel_conj(ProcInfo0, HasParallelConj),
        (
            HasParallelConj = has_parallel_conj,
            Spec = report_already_parallelised(PredInfo),
            !:Specs = [Spec | !.Specs]
        ;
            HasParallelConj = has_no_parallel_conj,
            parallelise_proc(CPCProc, PredInfo, ProcInfo0, ProcInfo,
                ProcIntroducedParallelism, !ModuleInfo, !Specs),
            (
                ProcIntroducedParallelism = have_not_introduced_parallelism
            ;
                ProcIntroducedParallelism = introduced_parallelism,
                !:AnyProcIntroducedParallelism = introduced_parallelism,
                map.det_update(ProcId, ProcInfo, !ProcTable)
            )
        )
    ;
        true
    ).

:- pred parallelise_proc(candidate_par_conjunctions_proc::in,
    pred_info::in, proc_info::in, proc_info::out,
    introduced_parallelism::out,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

parallelise_proc(CPCProc, PredInfo, !ProcInfo,
        IntroducedParallelism, !ModuleInfo, !Specs) :-
    CPCProc = candidate_par_conjunctions_proc(VarNameTable, PushGoals,
        CPCs0),
    (
        PushGoals = []
    ;
        PushGoals = [_ | _],
        push_goals_in_proc(PushGoals, _Result, !ProcInfo, !ModuleInfo)
    ),

    proc_info_get_goal(!.ProcInfo, Goal0),
    Context = goal_info_get_context(Goal0 ^ hlds_goal_info),
    term.context_file(Context, FileName),
    proc_info_get_vartypes(!.ProcInfo, VarTypes),
    % VarNumRep is not used by goal_to_goal_rep, var_num_1_byte
    % is an arbitrary value. XXX zs: I don't think this is true.
    VarNumRep = var_num_1_byte,
    proc_info_get_headvars(!.ProcInfo, HeadVars),
    proc_info_get_varset(!.ProcInfo, VarSet),
    compute_var_number_map(HeadVars, VarSet, [], Goal0, VarNumMap),
    ProgRepInfo = prog_rep_info(FileName, VarTypes, VarNumMap,
        VarNumRep, !.ModuleInfo, flatten_par_conjs),
    proc_info_get_initial_instmap(!.ProcInfo, !.ModuleInfo, Instmap),

    % Sort the candidate parallelisations so that we introduce
    % parallelisations in an order that allows us to continue to insert
    % parallelisations even as the goal tree changes. In particular,
    % insert deeper parallelisations before shallower ones, and later
    % ones before earlier ones.
    list.sort_and_remove_dups(compare_candidate_par_conjunctions, CPCs0, CPCs),
    list.foldl3(
        maybe_parallelise_goal(PredInfo, ProgRepInfo, VarNameTable, Instmap),
        CPCs, Goal0, Goal,
        have_not_introduced_parallelism, IntroducedParallelism, !Specs),
    (
        IntroducedParallelism = introduced_parallelism,
        % In the future we'll specialise the procedure for parallelism,
        % We don't do that now so simply replace the procedure's body.
        proc_info_set_goal(Goal, !ProcInfo),
        proc_info_set_has_parallel_conj(has_parallel_conj, !ProcInfo)
    ;
        IntroducedParallelism = have_not_introduced_parallelism
    ).

%-----------------------------------------------------------------------------%

    % maybe_parallelise_goal(ProgRepInfo, VarNameTable, CPC, !Goal,
    %   !IntroducedParallelism).
    %
    % Attempt to parallelise some part of !.Goal returning !:Goal.
    % If !.IntroducedParallelism = have_not_introduced_parallelism then !Goal
    % will be unmodified.
    %
:- pred maybe_parallelise_goal(pred_info::in, prog_rep_info::in,
    var_name_table::in, instmap::in, candidate_par_conjunction::in,
    hlds_goal::in, hlds_goal::out,
    introduced_parallelism::in, introduced_parallelism::out,
    list(error_spec)::in, list(error_spec)::out) is det.

maybe_parallelise_goal(PredInfo, ProgRepInfo, VarNameTable, Instmap0, CPC,
        Goal0, Goal, !IntroducedParallelism, !Specs) :-
    TargetGoalPathString = CPC ^ cpc_goal_path,
    ( goal_path_from_string(TargetGoalPathString, TargetGoalPathPrime) ->
        TargetGoalPath = TargetGoalPathPrime
    ;
        unexpected($module, $pred,
            "Invalid goal path in CPC Feedback Information")
    ),
    maybe_transform_goal_at_goal_path_with_instmap(
        maybe_parallelise_conj(ProgRepInfo, VarNameTable, CPC),
        TargetGoalPath, Instmap0, Goal0, MaybeGoal),
    (
        MaybeGoal = ok(Goal),
        !:IntroducedParallelism = introduced_parallelism
    ;
        (
            MaybeGoal = error(Error)
        ;
            MaybeGoal = goal_not_found,
            Error = "Could not find goal in procedure; "
                ++ "perhaps the program has changed"
        ),
        Goal = Goal0,
        Spec = report_failed_parallelisation(PredInfo, TargetGoalPathString,
            Error),
        !:Specs = [Spec | !.Specs]
    ).

%-----------------------------------------------------------------------------%

:- pred maybe_parallelise_conj(prog_rep_info::in, var_name_table::in,
    candidate_par_conjunction::in, instmap::in, hlds_goal::in,
    maybe_error(hlds_goal)::out) is det.

maybe_parallelise_conj(ProgRepInfo, VarNameTable, CPC, Instmap0,
        Goal0, MaybeGoal) :-
    Goal0 = hlds_goal(GoalExpr0, _GoalInfo0),
    % We have reached the point indicated by the goal path.
    % Find the conjuncts that we wish to parallelise.
    cpc_get_first_goal(CPC, FirstGoalRep),
    (
        GoalExpr0 = conj(plain_conj, Conjs0),
        flatten_conj(Conjs0, Conjs1),
        find_first_goal(FirstGoalRep, Conjs1, ProgRepInfo, VarNameTable,
            Instmap0, found_first_goal(GoalsBefore, FirstGoal, OtherGoals))
    ->
        GoalsBeforeInstDeltas = list.map(
            (func(G) = goal_info_get_instmap_delta(G ^ hlds_goal_info)),
            GoalsBefore),
        list.foldl(apply_instmap_delta_sv, GoalsBeforeInstDeltas,
            Instmap0, Instmap),
        build_par_conjunction(ProgRepInfo, VarNameTable, Instmap,
            [FirstGoal | OtherGoals], CPC, MaybeParConjunction),
        (
            MaybeParConjunction = ok(
                par_conjunction_and_remaining_goals(ParConjunction,
                RemainingGoals)),
            Conjs = GoalsBefore ++ ParConjunction ++ RemainingGoals,
            GoalExpr = conj(plain_conj, Conjs),
            MaybeGoal = ok(hlds_goal(GoalExpr, Goal0 ^ hlds_goal_info))
        ;
            MaybeParConjunction = error(Error),
            MaybeGoal = error(Error)
        )
    ;
        MaybeGoal = error("Could not find partition within conjunction: "
            ++ "perhaps the program has changed")
    ).

:- pred cpc_get_first_goal(candidate_par_conjunction::in, pard_goal::out)
    is det.

cpc_get_first_goal(CPC, FirstGoal) :-
    GoalsBefore = CPC ^ cpc_goals_before,
    (
        GoalsBefore = [FirstGoal | _]
    ;
        GoalsBefore = [],
        ParConj = CPC ^ cpc_conjs,
        (
            ParConj = [FirstParConj | _],
            FirstParConj = seq_conj([FirstGoalPrime | _])
        ->
            FirstGoal = FirstGoalPrime
        ;
            unexpected($module, $pred,
                "candidate parallel conjunction is empty")
        )
    ).

:- type find_first_goal_result
    --->    did_not_find_first_goal
    ;       found_first_goal(
                ffg_goals_before        :: hlds_goals,
                ffg_goal                :: hlds_goal,
                ffg_goals_after         :: hlds_goals
            ).

:- pred find_first_goal(pard_goal::in, list(hlds_goal)::in,
    prog_rep_info::in, var_name_table::in, instmap::in,
    find_first_goal_result::out) is det.

find_first_goal(_, [], _, _, _, did_not_find_first_goal).
find_first_goal(GoalRep, [Goal | Goals], ProcRepInfo, VarNameTable, !.Instmap,
        Result) :-
    (
        pard_goal_match_hlds_goal(ProcRepInfo, VarNameTable, !.Instmap,
            GoalRep, Goal)
    ->
        Result = found_first_goal([], Goal, Goals)
    ;
        InstmapDelta = goal_info_get_instmap_delta(Goal ^ hlds_goal_info),
        apply_instmap_delta_sv(InstmapDelta, !Instmap),
        find_first_goal(GoalRep, Goals, ProcRepInfo, VarNameTable, !.Instmap,
            Result0),
        (
            Result0 = did_not_find_first_goal,
            Result = did_not_find_first_goal
        ;
            Result0 = found_first_goal(GoalsBefore0, _, _),
            Result = Result0 ^ ffg_goals_before := [Goal | GoalsBefore0]
        )
    ).

%-----------------------------------------------------------------------------%

:- type par_conjunction_and_remaining_goals
    --->    par_conjunction_and_remaining_goals(
                pcrg_par_conjunction            :: hlds_goals,
                pcrg_remaining_goals            :: hlds_goals
            ).

:- pred build_par_conjunction(prog_rep_info::in, var_name_table::in,
    instmap::in, hlds_goals::in, candidate_par_conjunction::in,
    maybe_error(par_conjunction_and_remaining_goals)::out) is det.

build_par_conjunction(ProcRepInfo, VarNameTable, Instmap0, !.Goals, CPC,
        MaybeParConjunction) :-
    GoalRepsBefore = CPC ^ cpc_goals_before,
    GoalRepsAfter = CPC ^ cpc_goals_after,
    ParConjReps = CPC ^ cpc_conjs,
    some [!Instmap] (
        !:Instmap = Instmap0,
        build_seq_conjuncts(ProcRepInfo, VarNameTable, GoalRepsBefore,
            MaybeGoalsBefore, !Goals, !Instmap),
        build_par_conjuncts(ProcRepInfo, VarNameTable, ParConjReps,
            MaybeParConjuncts, !Goals, !Instmap),
        build_seq_conjuncts(ProcRepInfo, VarNameTable, GoalRepsAfter,
            MaybeGoalsAfter, !Goals, !Instmap),
        _ = !.Instmap
    ),
    (
        MaybeGoalsBefore = yes(GoalsBefore),
        (
            MaybeParConjuncts = yes(ParConjuncts),
            (
                MaybeGoalsAfter = yes(GoalsAfter),
                create_conj_from_list(ParConjuncts, parallel_conj,
                    ParConjunction0),
                ParConjunction = GoalsBefore ++ [ParConjunction0 | GoalsAfter],
                MaybeParConjunction = ok(
                    par_conjunction_and_remaining_goals(ParConjunction,
                    !.Goals))
            ;
                MaybeGoalsAfter = no,
                MaybeParConjunction = error("The goals after the parallel "
                    ++ "conjunction do not match those in the feedback file")
            )
        ;
            MaybeParConjuncts = no,
            MaybeParConjunction = error("The goals within the parallel "
                ++ "conjunction do not match those in the feedback file")
        )
    ;
        MaybeGoalsBefore = no,
        MaybeParConjunction = error("The goals before the parallel "
            ++ "conjunction do not match those in the feedback file")
    ).

:- pred build_par_conjuncts(prog_rep_info::in, var_name_table::in,
    list(seq_conj)::in, maybe(hlds_goals)::out,
    hlds_goals::in, hlds_goals::out, instmap::in, instmap::out) is det.

build_par_conjuncts(_, _, [], yes([]), !Goals, !Instmap).
build_par_conjuncts(ProcRepInfo, VarNameTable, [GoalRep | GoalReps],
        MaybeConjs, !Goals, !Instmap) :-
    GoalRep = seq_conj(SeqConjs),
    build_seq_conjuncts(ProcRepInfo, VarNameTable, SeqConjs, MaybeConj,
        !Goals, !Instmap),
    (
        MaybeConj = yes(Conj0),
        create_conj_from_list(Conj0, plain_conj, Conj),
        build_par_conjuncts(ProcRepInfo, VarNameTable, GoalReps,
            MaybeConjs0, !Goals, !Instmap),
        (
            MaybeConjs0 = yes(Conjs0),
            MaybeConjs = yes([Conj | Conjs0])
        ;
            MaybeConjs0 = no,
            MaybeConjs = no
        )
    ;
        MaybeConj = no,
        MaybeConjs = no
    ).

:- pred build_seq_conjuncts(prog_rep_info::in, var_name_table::in,
    list(pard_goal)::in, maybe(hlds_goals)::out,
    hlds_goals::in, hlds_goals::out, instmap::in, instmap::out) is det.

build_seq_conjuncts(_, _, [], yes([]), !Goals, !Instmap).
build_seq_conjuncts(ProcRepInfo, VarNameTable, [GoalRep | GoalReps],
        MaybeConjs, !Goals, !Instmap) :-
    (
        !.Goals = [Goal | !:Goals],
        (
            pard_goal_match_hlds_goal(ProcRepInfo, VarNameTable, !.Instmap,
                GoalRep, Goal)
        ->
            InstmapDelta = goal_info_get_instmap_delta(Goal ^ hlds_goal_info),
            apply_instmap_delta_sv(InstmapDelta, !Instmap),
            build_seq_conjuncts(ProcRepInfo, VarNameTable, GoalReps,
                MaybeConjs0, !Goals, !Instmap),
            (
                MaybeConjs0 = yes(Conjs0),
                MaybeConjs = yes([Goal | Conjs0])
            ;
                MaybeConjs0 = no,
                MaybeConjs = no
            )
        ;
            MaybeConjs = no
        )
    ;
        !.Goals = [],
        MaybeConjs = no
    ).

%-----------------------------------------------------------------------------%

:- func report_failed_parallelisation(pred_info, string, string) =
    error_spec.

report_failed_parallelisation(PredInfo, GoalPath, Error) = Spec :-
    % Should the severity be informational?
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    ModuleName = pred_info_module(PredInfo),
    PredName = pred_info_name(PredInfo),
    Arity = pred_info_orig_arity(PredInfo),
    Pieces = [words("In"), p_or_f(PredOrFunc),
        sym_name_and_arity(qualified(ModuleName, PredName) / Arity),
        suffix(":"), nl,
        words("Warning: could not auto-parallelise"), quote(GoalPath),
        suffix(":"), words(Error)],
    pred_info_get_context(PredInfo, Context),
    % XXX Make this a warning or error if the user wants compilation to
    % abort.
    Spec = error_spec(severity_informational, phase_auto_parallelism,
        [simple_msg(Context, [always(Pieces)])]).

:- func report_already_parallelised(pred_info) = error_spec.

report_already_parallelised(PredInfo) = Spec :-
    % Should the severity be informational?
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    ModuleName = pred_info_module(PredInfo),
    PredName = pred_info_name(PredInfo),
    Arity = pred_info_orig_arity(PredInfo),
    Pieces = [words("In"), p_or_f(PredOrFunc),
        sym_name_and_arity(qualified(ModuleName, PredName) / Arity),
        suffix(":"), nl,
        words("Warning: this procedure contains explicit parallel"),
        words("conjunctions, it will not be automatically parallelised.")],
    pred_info_get_context(PredInfo, Context),
    Spec = error_spec(severity_warning, phase_auto_parallelism,
        [simple_msg(Context, [always(Pieces)])]).

%-----------------------------------------------------------------------------%

:- pred compare_candidate_par_conjunctions(candidate_par_conjunction::in,
    candidate_par_conjunction::in, comparison_result::out) is det.

compare_candidate_par_conjunctions(CPCA, CPCB, Result) :-
    goal_path_from_string_det(CPCA ^ cpc_goal_path, PathA),
    goal_path_from_string_det(CPCB ^ cpc_goal_path, PathB),
    compare_goal_paths(PathA, PathB, Result).

:- pred compare_goal_paths(forward_goal_path::in, forward_goal_path::in,
    comparison_result::out) is det.

compare_goal_paths(PathA, PathB, Result) :-
    (
        PathA = fgp_cons(FirstStepA, LaterPathA),
        (
            PathB = fgp_cons(FirstStepB, LaterPathB),
            compare(Result0, FirstStepA, FirstStepB),
            % Reverse the ordering here so that later goals are sorted before
            % earlier ones. This way parallelisations are placed inside later
            % goals first.
            (
                Result0 = (=),
                compare_goal_paths(LaterPathA, LaterPathB, Result)
            ;
                Result0 = (<),
                Result = (>)
            ;
                Result0 = (>),
                Result = (<)
            )
        ;
            PathB = fgp_nil,
            % PathA is longer than PathB. Make A 'less than' B so that
            % deeper parallelisations are inserted first.
            Result = (<)
        )
    ;
        PathA = fgp_nil,
        (
            PathB = fgp_cons(_, _),
            % B is 'less than' A, see above.
            Result = (>)
        ;
            PathB = fgp_nil,
            % Both goal paths are empty.
            Result = (=)
        )
    ).

%-----------------------------------------------------------------------------%

:- pred pard_goal_match_hlds_goal(prog_rep_info::in, var_name_table::in,
    instmap::in, pard_goal::in, hlds_goal::in) is semidet.

pard_goal_match_hlds_goal(ProgRepInfo, VarNameTable, Instmap,
        GoalRepA, GoalB) :-
    goal_to_goal_rep(ProgRepInfo, Instmap, GoalB, GoalRepB),
    goal_reps_match(VarNameTable, GoalRepA, GoalRepB).

:- pred goal_reps_match(var_name_table::in, goal_rep(A)::in, goal_rep(B)::in)
    is semidet.

goal_reps_match(VarNameTable, GoalA, GoalB) :-
    GoalA = goal_rep(GoalRepA, Detism, _),
    GoalB = goal_rep(GoalRepB, Detism, _),
    (
        GoalRepA = conj_rep(ConjsA),
        GoalRepB = conj_rep(ConjsB),
        zip_all_true(goal_reps_match(VarNameTable), ConjsA, ConjsB)
    ;
        GoalRepA = disj_rep(DisjsA),
        GoalRepB = disj_rep(DisjsB),
        zip_all_true(goal_reps_match(VarNameTable), DisjsA, DisjsB)
    ;
        GoalRepA = switch_rep(VarRepA, CanFail, CasesA),
        GoalRepB = switch_rep(VarRepB, CanFail, CasesB),
        var_reps_match(VarNameTable, VarRepA, VarRepB),
        % Note that GoalRepA and GoalRepB could be equivalent
        % even they contained the same cases but a different order.
        list.sort(CasesA, SortedCasesA),
        list.sort(CasesB, SortedCasesB),
        zip_all_true(case_reps_match(VarNameTable), SortedCasesA, SortedCasesB)
    ;
        GoalRepA = ite_rep(CondA, ThenA, ElseA),
        GoalRepB = ite_rep(CondB, ThenB, ElseB),
        goal_reps_match(VarNameTable, CondA, CondB),
        goal_reps_match(VarNameTable, ThenA, ThenB),
        goal_reps_match(VarNameTable, ElseA, ElseB)
    ;
        GoalRepA = negation_rep(SubGoalA),
        GoalRepB = negation_rep(SubGoalB),
        goal_reps_match(VarNameTable, SubGoalA, SubGoalB)
    ;
        GoalRepA = scope_rep(SubGoalA, MaybeCut),
        GoalRepB = scope_rep(SubGoalB, MaybeCut),
        goal_reps_match(VarNameTable, SubGoalA, SubGoalB)
    ;
        GoalRepA = atomic_goal_rep(_, _, _, AtomicGoalA),
        GoalRepB = atomic_goal_rep(_, _, _, AtomicGoalB),
        % We don't compare names and file numbers, since trivial changes
        % to e.g. comments could change line numbers dramatically without
        % changing how the program should be parallelised.
        %
        % Vars are not matched here either, we only consider the vars
        % within the atomic_goal_rep structures.
        atomic_goal_reps_match(VarNameTable, AtomicGoalA, AtomicGoalB)
    ).

:- pred atomic_goal_reps_match(var_name_table::in,
    atomic_goal_rep::in, atomic_goal_rep::in) is semidet.

atomic_goal_reps_match(VarNameTable, AtomicRepA, AtomicRepB) :-
    (
        (
            AtomicRepA = unify_construct_rep(VarA, ConsId, ArgsA),
            AtomicRepB = unify_construct_rep(VarB, ConsId, ArgsB)
        ;
            AtomicRepA = unify_deconstruct_rep(VarA, ConsId, ArgsA),
            AtomicRepB = unify_deconstruct_rep(VarB, ConsId, ArgsB)
        ;
            AtomicRepA = higher_order_call_rep(VarA, ArgsA),
            AtomicRepB = higher_order_call_rep(VarB, ArgsB)
        ;
            AtomicRepA = method_call_rep(VarA, MethodNum, ArgsA),
            AtomicRepB = method_call_rep(VarB, MethodNum, ArgsB)
        ),
        var_reps_match(VarNameTable, VarA, VarB),
        zip_all_true(var_reps_match(VarNameTable), ArgsA, ArgsB)
    ;
        (
            AtomicRepA = partial_deconstruct_rep(VarA, ConsId, MaybeArgsA),
            AtomicRepB = partial_deconstruct_rep(VarB, ConsId, MaybeArgsB)
        ;
            AtomicRepA = partial_construct_rep(VarA, ConsId, MaybeArgsA),
            AtomicRepB = partial_construct_rep(VarB, ConsId, MaybeArgsB)
        ),
        var_reps_match(VarNameTable, VarA, VarB),
        zip_all_true(maybe_var_reps_match(VarNameTable),
            MaybeArgsA, MaybeArgsB)
    ;
        (
            AtomicRepA = unify_assign_rep(VarA1, VarA2),
            AtomicRepB = unify_assign_rep(VarB1, VarB2)
        ;
            AtomicRepA = cast_rep(VarA1, VarA2),
            AtomicRepB = cast_rep(VarB1, VarB2)
        ;
            AtomicRepA = unify_simple_test_rep(VarA1, VarA2),
            AtomicRepB = unify_simple_test_rep(VarB1, VarB2)
        ),
        var_reps_match(VarNameTable, VarA1, VarB1),
        var_reps_match(VarNameTable, VarA2, VarB2)
    ;
        (
            AtomicRepA = pragma_foreign_code_rep(ArgsA),
            AtomicRepB = pragma_foreign_code_rep(ArgsB)
        ;
            AtomicRepA = plain_call_rep(ModuleName, PredName, ArgsA),
            AtomicRepB = plain_call_rep(ModuleName, PredName, ArgsB)
        ;
            AtomicRepA = builtin_call_rep(ModuleName, PredName, ArgsA),
            AtomicRepB = builtin_call_rep(ModuleName, PredName, ArgsB)
        ;
            AtomicRepA = event_call_rep(EventName, ArgsA),
            AtomicRepB = event_call_rep(EventName, ArgsB)
        ),
        zip_all_true(var_reps_match(VarNameTable), ArgsA, ArgsB)
    ).

:- pred case_reps_match(var_name_table::in, case_rep(A)::in, case_rep(B)::in)
    is semidet.

case_reps_match(VarNameTable, CaseRepA, CaseRepB) :-
    CaseRepA = case_rep(ConsId, OtherConsIds, GoalRepA),
    CaseRepB = case_rep(ConsId, OtherConsIds, GoalRepB),
    goal_reps_match(VarNameTable, GoalRepA, GoalRepB).

:- pred var_reps_match(var_name_table::in, var_rep::in, var_rep::in)
    is semidet.

var_reps_match(VarNameTable, VarA, VarB) :-
    ( search_var_name(VarNameTable, VarA, _) ->
        % Variables named by the programmer _must_ match, we expect to find
        % them in the var table, and that they would be identical.  (Since one
        % of the variables will be built using its name and the var table
        % constructed when converting the original code to byte code).
        VarA = VarB
    ;
        % Unnamed variables match implicitly. They will usually be identical,
        % but we do not REQUIRE them to be identical, to allow the program
        % to change a little after being profiled but before being
        % parallelised.
        true
    ).

:- pred maybe_var_reps_match(var_name_table::in,
    maybe(var_rep)::in, maybe(var_rep)::in) is semidet.

maybe_var_reps_match(_, no, no).
maybe_var_reps_match(VarNameTable, yes(VarA), yes(VarB)) :-
    var_reps_match(VarNameTable, VarA, VarB).

%-----------------------------------------------------------------------------%

    % zip_all_true(Pred, ListA, ListB)
    %
    % True when lists have equal length and every corresponding pair of values
    % from the lists satisifies Pred.
    %
:- pred zip_all_true(pred(A, B), list(A), list(B)).
:- mode zip_all_true(pred(in, in) is semidet, in, in) is semidet.

zip_all_true(_, [], []).
zip_all_true(Pred, [A | As], [B | Bs]) :-
    Pred(A, B),
    zip_all_true(Pred, As, Bs).

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.implicit_parallelism.introduce_parallelism.
%-----------------------------------------------------------------------------%
