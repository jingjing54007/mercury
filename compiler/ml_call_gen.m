%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1999-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: ml_call_gen.m.
% Main author: fjh.
%
% This module is part of the MLDS code generator. It handles code generation
% for both generic and plain procedure calls, and calls to builtins.
%
%---------------------------------------------------------------------------%

:- module ml_backend.ml_call_gen.
:- interface.

:- import_module hlds.
:- import_module hlds.code_model.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_pred.
:- import_module hlds.mark_tail_calls.          % for nontail_rec_call_reason
:- import_module ml_backend.ml_args_util.
:- import_module ml_backend.ml_gen_info.
:- import_module ml_backend.mlds.
:- import_module parse_tree.
:- import_module parse_tree.prog_data.

:- import_module list.
:- import_module set.

%---------------------------------------------------------------------------%

    % Generate MLDS code for an HLDS generic_call goal.
    % This includes boxing/unboxing the arguments if necessary.
    %
:- pred ml_gen_generic_call(generic_call::in, list(prog_var)::in,
    list(mer_mode)::in, determinism::in, prog_context::in,
    list(mlds_local_var_defn)::out, list(mlds_function_defn)::out,
    list(mlds_stmt)::out, ml_gen_info::in, ml_gen_info::out) is det.

    % ml_gen_plain_call(PredId, ProcId, CodeModel, GoalInfo,
    %   Args, LocalVarDefns, FuncDefns, Stmts):
    %
    % Generate MLDS code for a plain HLDS procedure call, making sure to
    % box/unbox the arguments if necessary.
    %
    % If the arguments are arg_for_closure_wrapper, then the type_info
    % for type variables in the caller type may not be available in the
    % current procedure, so the GC tracing code for temps introduced for
    % boxing/unboxing (if any) should obtain the type_info from the
    % corresponding entry in the `type_params' local.
    %
:- pred ml_gen_plain_call(pred_id::in, proc_id::in, code_model::in,
    hlds_goal_info::in, list(prog_var)::in, list(mlds_local_var_defn)::out,
    list(mlds_function_defn)::out, list(mlds_stmt)::out,
    ml_gen_info::in, ml_gen_info::out) is det.

:- pred ml_gen_plain_non_tail_call(pred_proc_id, code_model, prog_context,
    list(ml_call_arg), nontail_rec_call_reason, set(goal_feature),
    list(mlds_local_var_defn), list(mlds_function_defn), list(mlds_stmt),
    ml_gen_info, ml_gen_info).
:- mode ml_gen_plain_non_tail_call(in, in, in, in(list_skel(not_fcw)), in, in,
    out, out, out, in, out) is det.
:- mode ml_gen_plain_non_tail_call(in, in, in, in(list_skel(fcw)), in, in,
    out, out, out, in, out) is det.

    % Generate MLDS code for a call to a builtin procedure.
    %
:- pred ml_gen_builtin(pred_id::in, proc_id::in, list(prog_var)::in,
    code_model::in, prog_context::in,
    list(mlds_local_var_defn)::out, list(mlds_function_defn)::out,
    list(mlds_stmt)::out, ml_gen_info::in, ml_gen_info::out) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.
:- import_module backend_libs.builtin_ops.
:- import_module check_hlds.
:- import_module check_hlds.type_util.
:- import_module hlds.hlds_module.
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.
:- import_module mdbcomp.sym_name.
:- import_module ml_backend.ml_code_util.
:- import_module ml_backend.ml_optimize.
:- import_module ml_backend.ml_tailcall.
:- import_module parse_tree.prog_data_foreign.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module term.

%---------------------------------------------------------------------------%
%
% Code for generic calls.
%

ml_gen_generic_call(GenericCall, ArgVars, ArgModes, Determinism, Context,
        LocalVarDefns, FuncDefns, Stmts, !Info) :-
    % XXX For typeclass method calls, we do some unnecessary
    % boxing/unboxing of the arguments.
    (
        GenericCall = higher_order(_, _, _, _),
        ml_gen_main_generic_call(GenericCall, ArgVars, ArgModes, Determinism,
            Context, LocalVarDefns, FuncDefns, Stmts, !Info)
    ;
        GenericCall = class_method(_, _, _, _),
        ml_gen_main_generic_call(GenericCall, ArgVars, ArgModes, Determinism,
            Context, LocalVarDefns, FuncDefns, Stmts, !Info)
    ;
        GenericCall = event_call(_),
        % XXX For now, we can't generate events from the MLDS backend.
        LocalVarDefns = [],
        FuncDefns = [],
        Stmts = []
    ;
        GenericCall = cast(_),
        ml_gen_cast(Context, ArgVars, LocalVarDefns, FuncDefns, Stmts, !Info)
    ).

:- inst main_generic_call for generic_call/0
    --->    higher_order(ground, ground, ground, ground)
    ;       class_method(ground, ground, ground, ground).

:- pred ml_gen_main_generic_call(generic_call::in(main_generic_call),
    list(prog_var)::in, list(mer_mode)::in, determinism::in, prog_context::in,
    list(mlds_local_var_defn)::out, list(mlds_function_defn)::out,
    list(mlds_stmt)::out, ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_main_generic_call(GenericCall, ArgVars, ArgModes, Determinism, Context,
        LocalVarDefns, FuncDefns, Stmts, !Info) :-
    % Allocate some fresh type variables to use as the Mercury types
    % of the boxed arguments.
    NumArgs = list.length(ArgVars),
    BoxedArgTypes = ml_make_boxed_types(NumArgs),

    % Create the boxed parameter types for the called function.
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ml_gen_info_get_varset(!.Info, VarSet),
    ArgNames = ml_gen_local_var_names(VarSet, ArgVars),
    PredOrFunc = generic_call_pred_or_func(GenericCall),
    determinism_to_code_model(Determinism, CodeModel),
    ml_gen_params_no_gc_stmts(ModuleInfo, PredOrFunc, CodeModel,
        ArgVars, ArgNames, BoxedArgTypes, ArgModes, _ArgTuples, Params0),

    % Insert the `closure_arg' parameter.
    %
    % The GCStmt for `closure_arg' here is wrong, but it doesn't matter,
    % since `closure_arg' is only part of a type (a function parameter in the
    % function type). We won't use the GC tracing code generated here, since
    % we don't generate any actual local variable or parameter for
    % `closure_arg'.
    GCStmt = gc_no_stmt,
    ClosureArgType = mlds_generic_type,
    ClosureArg = mlds_argument(lvn_comp_var(lvnc_closure_arg), ClosureArgType,
        GCStmt),
    Params0 = mlds_func_params(ArgParams0, RetParam),
    Params = mlds_func_params([ClosureArg | ArgParams0], RetParam),
    Signature = mlds_get_func_signature(Params),

    % Compute the function address.
    (
        GenericCall = higher_order(ClosureVar, _Purity, _PredOrFunc, _Arity),
        ml_gen_var(!.Info, ClosureVar, ClosureLval),
        FieldId = ml_field_offset(ml_const(mlconst_int(1))),
        % XXX are these types right?
        FuncLval = ml_field(yes(0), ml_lval(ClosureLval), FieldId,
            mlds_generic_type, ClosureArgType),
        FuncType = mlds_func_type(Params),
        FuncRval = ml_unop(unbox(FuncType), ml_lval(FuncLval))
    ;
        GenericCall = class_method(TypeClassInfoVar, MethodNum,
            _ClassId, _PredName),

        % Create the lval for the typeclass_info, which is also the closure
        % in this case.
        ml_gen_var(!.Info, TypeClassInfoVar, TypeClassInfoLval),
        ClosureLval = TypeClassInfoLval,

        % Extract the base_typeclass_info from the typeclass_info.
        BaseTypeclassInfoFieldId = ml_field_offset(ml_const(mlconst_int(0))),
        BaseTypeclassInfoLval = ml_field(yes(0),
            ml_lval(TypeClassInfoLval), BaseTypeclassInfoFieldId,
            mlds_generic_type, ClosureArgType),

        % Extract the method address from the base_typeclass_info.
        Offset = ml_base_typeclass_info_method_offset,
        MethodFieldNum = MethodNum + Offset,
        MethodFieldId = ml_field_offset(ml_const(mlconst_int(MethodFieldNum))),
        FuncLval = ml_field(yes(0), ml_lval(BaseTypeclassInfoLval),
            MethodFieldId, mlds_generic_type, mlds_generic_type),
        FuncType = mlds_func_type(Params),
        FuncRval = ml_unop(unbox(FuncType), ml_lval(FuncLval))
    ),

    % Assign the function address rval to a new local variable. This makes
    % the generated code slightly more readable. More importantly, this is also
    % necessary when using a non-standard calling convention with GNU C,
    % since GNU C (2.95.2) ignores the function attributes on function
    % pointer types in casts.
    % XXX Is this limitation still there in currently used C compilers?
    %
    ml_gen_info_new_conv_var(ConvVarSeq, !Info),
    ConvVarSeq = conv_seq(ConvVarNum),
    FuncVarName = lvn_comp_var(lvnc_conv_var(ConvVarNum)),
    % The function address is always a pointer to code,
    % not to the heap, so the GC doesn't need to trace it.
    GCStmt = gc_no_stmt,
    FuncVarDecl = ml_gen_mlds_var_decl(FuncVarName, FuncType, GCStmt, Context),
    FuncVarLval = ml_local_var(FuncVarName, FuncType),
    AssignFuncVar = ml_gen_assign(FuncVarLval, FuncRval, Context),
    FuncVarRval = ml_lval(FuncVarLval),

    % Generate code to box/unbox the arguments and compute the list of properly
    % converted rvals/lvals to pass as the function call's arguments and
    % return values.
    CallerArgs = wrap_plain_not_fcw_args(ArgVars),
    ml_gen_args(PredOrFunc, CodeModel, Context, input_and_output_params,
        BoxedArgTypes, ArgModes, CallerArgs, InputRvals, OutputLvalsTypes,
        ConvArgLocalVarDefns, ConvOutputStmts, !Info),
    ClosureRval = ml_unop(unbox(ClosureArgType), ml_lval(ClosureLval)),

    ( if
        ConvArgLocalVarDefns = [],
        ConvOutputStmts = []
    then
        % Generate the call directly (as opposed to via DoGenCall)
        % in the common case.
        ml_gen_mlds_call(Signature, FuncVarRval,
            [ClosureRval | InputRvals], OutputLvalsTypes,
            Determinism, Context, LocalVarDefns0, FuncDefns0, Stmts0, !Info)
    else
        % Prepare to generate the call, passing the closure as the first
        % argument. We can't actually generate the call yet, since it might be
        % nondet, and we don't yet know what its success continuation will be.
        % Instead we construct a higher-order term `DoGenCall', which, when
        % called by ml_combine_conj, will generate it.
        DoGenCall = ml_gen_mlds_call(Signature, FuncVarRval,
            [ClosureRval | InputRvals], OutputLvalsTypes,
            Determinism, Context),

        % Construct a closure to generate code to convert the output arguments
        % and then succeed.
        DoGenConvOutputAndSucceed =
            ( pred(COAS_LocalVarDefns::out, COAS_FuncDefns::out,
                    COAS_Stmts::out, Info0::in, Info::out) is det :-
                COAS_LocalVarDefns = [],
                COAS_FuncDefns = [],
                ml_gen_success(CodeModel, Context, SucceedStmts, Info0, Info),
                COAS_Stmts = ConvOutputStmts ++ SucceedStmts
            ),

        % Conjoin the code generated by the two closures that we computed
        % above. `ml_combine_conj' will generate whatever kind of sequence
        % is necessary for this code model.
        ml_combine_conj(CodeModel, Context, DoGenCall,
            DoGenConvOutputAndSucceed,
            CallAndConvOutputLocalVarDefns, CallAndConvOutputFuncDefns,
            CallAndConvOutputStmts, !Info),
        LocalVarDefns0 =
            ConvArgLocalVarDefns ++ CallAndConvOutputLocalVarDefns,
        FuncDefns0 = CallAndConvOutputFuncDefns,
        Stmts0 = CallAndConvOutputStmts
    ),
    LocalVarDefns = [FuncVarDecl | LocalVarDefns0],
    FuncDefns = FuncDefns0,
    Stmts = [AssignFuncVar | Stmts0].

    % Generate MLDS code for a cast. The list of argument variables
    % must have only two elements, the input and the output.
    %
:- pred ml_gen_cast(prog_context::in, list(prog_var)::in,
    list(mlds_local_var_defn)::out, list(mlds_function_defn)::out,
    list(mlds_stmt)::out, ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_cast(Context, ArgVars, LocalVarDefns, FuncDefns, Stmts, !Info) :-
    ml_gen_var_list(!.Info, ArgVars, ArgLvals),
    ml_variable_types(!.Info, ArgVars, ArgTypes),
    ( if
        ArgVars = [SrcVar, DestVar],
        ArgLvals = [SrcLval, DestLval],
        ArgTypes = [SrcType, DestType]
    then
        ml_gen_info_get_module_info(!.Info, ModuleInfo),
        IsDummy = check_dummy_type(ModuleInfo, DestType),
        (
            IsDummy = is_dummy_type,
            Stmts = []
        ;
            IsDummy = is_not_dummy_type,
            ml_gen_box_or_unbox_rval(ModuleInfo, SrcType, DestType,
                bp_native_if_possible, ml_lval(SrcLval), CastRval),
            Assign = ml_gen_assign(DestLval, CastRval, Context),
            Stmts = [Assign]
        ),
        LocalVarDefns = [],
        FuncDefns = [],
        ( if ml_gen_info_search_const_var(!.Info, SrcVar, GroundTerm) then
            % If the source variable is a constant, so is the target after
            % this cast.
            ml_gen_info_set_const_var(DestVar, GroundTerm, !Info)
        else
            true
        )
    else
        unexpected($pred, "wrong number of args for cast")
    ).

%---------------------------------------------------------------------------%
%
% Code for ordinary calls.
%

ml_gen_plain_call(CalleePredId, CalleeProcId, CodeModel, GoalInfo, ArgVars,
        LocalVarDefns, FuncDefns, Stmts, !Info) :-
    CalleePredProcId = proc(CalleePredId, CalleeProcId),
    Context = goal_info_get_context(GoalInfo),
    Features = goal_info_get_features(GoalInfo),
    ( if set.contains(Features, feature_self_or_mutual_tail_rec_call) then
        ml_gen_plain_tail_call(CalleePredProcId, CodeModel, Context,
            ArgVars, Features,
            LocalVarDefns, FuncDefns, Stmts, !Info)
    else
        % We change representation because ml_closure_gen.m also calls
        % ml_gen_plain_non_tail_call with a different mechanism for specifying
        % the actual parameters.
        CallerArgs = wrap_plain_not_fcw_args(ArgVars),
        ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel, Context,
            CallerArgs, ntrcr_program, Features,
            LocalVarDefns, FuncDefns, Stmts, !Info)
    ).

:- pred ml_gen_plain_tail_call(pred_proc_id::in, code_model::in,
    prog_context::in, list(prog_var)::in, set(goal_feature)::in,
    list(mlds_local_var_defn)::out,
    list(mlds_function_defn)::out, list(mlds_stmt)::out,
    ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_plain_tail_call(CalleePredProcId, CodeModel, Context, ArgVars, Features,
        LocalVarDefns, FuncDefns, Stmts, !Info) :-
    % Compute the callee's Mercury argument types and modes.
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    module_info_pred_proc_info(ModuleInfo, CalleePredProcId,
        PredInfo, ProcInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    pred_info_get_arg_types(PredInfo, CalleeArgTypes),
    proc_info_get_argmodes(ProcInfo, CalleeArgModes),

    % Generate code to box/unbox the arguments and compute the list of
    % properly converted rvals/lvals to pass as the function call's
    % *input* arguments. We don't need to handle the output arguments.
    CallerArgs = wrap_plain_not_fcw_args(ArgVars),
    ml_gen_args(PredOrFunc, CodeModel, Context, input_params_only,
        CalleeArgTypes, CalleeArgModes, CallerArgs,
        InputRvals, OutputLvalsTypes,
        ConvOutputDefns, ConvOutputStmts, !Info),
    expect(unify(OutputLvalsTypes, []), $pred, "OutputLvalsTypes != []"),
    expect(unify(ConvOutputDefns, []), $pred, "ConvOutputDefns != []"),
    expect(unify(ConvOutputStmts, []), $pred, "ConvOutputStmts != []"),

    ml_gen_info_get_tail_rec_info(!.Info, TailRecInfo0),
    InSccMap0 = TailRecInfo0 ^ tri_in_scc_map,
    % The callee of this tail call will be in InSccMap0 only if it can
    % call the caller back directly or indirectly.
    ( if map.search(InSccMap0, CalleePredProcId, InSccInfo0) then
        InSccInfo0 = in_scc_info(MaybeInTscc, 
            IsTargetOfSelfTRCall0, IsTargetOfMutualTRCall0, _),
        (
            MaybeInTscc = in_tscc(IdInTSCC, FuncInputArgs),
            DanglingStackRef = may_rvals_yield_dangling_stack_ref(InputRvals),
            (
                DanglingStackRef = will_not_yield_dangling_stack_ref,
                ml_gen_info_get_func_nest_depth(!.Info, FuncNestDepth),
                ( if FuncNestDepth = 0 then
                    CommentStmt =
                        ml_stmt_atomic(comment("direct tailcall eliminated"),
                        Context),

                    ml_gen_info_get_module_name(!.Info, ModuleName),
                    MLDS_ModuleName = mercury_module_name_to_mlds(ModuleName),
                    tail_rec_call_assign_input_args(MLDS_ModuleName, Context,
                        FuncInputArgs, InputRvals, InitStmts, AssignStmts,
                        LocalVarDefns),
                    FuncDefns = [],
                    LoopKind = TailRecInfo0 ^ tri_loop_kind,
                    TsccKind = TailRecInfo0 ^ tri_tscc_kind,
                    (
                        LoopKind = tail_rec_loop_while_continue,
                        (
                            TsccKind = tscc_self_rec_only,
                            SetSelectorStmts = []
                        ;
                            TsccKind = tscc_self_and_mutual_rec,
                            IdInTSCC = proc_id_in_tscc(TsccProcNum),
                            SelectorVar = lvn_comp_var(lvnc_tscc_proc_selector),
                            SelectorLval = ml_local_var(SelectorVar, ml_int_type),
                            SetSelectorStmt = ml_stmt_atomic(
                                assign(SelectorLval,
                                    ml_const(mlconst_int(TsccProcNum))),
                                Context),
                            SetSelectorStmts = [SetSelectorStmt]
                        ),
                        GotoTarget = goto_continue
                    ;
                        LoopKind = tail_rec_loop_label_goto,
                        SetSelectorStmts = [],
                        StartLabel = generate_tail_rec_start_label(TsccKind,
                            IdInTSCC),
                        GotoTarget = goto_label(StartLabel)
                    ),
                    GotoStmt = ml_stmt_goto(GotoTarget, Context),
                    Stmts = [CommentStmt] ++ InitStmts ++ AssignStmts ++
                        SetSelectorStmts ++ [GotoStmt],

                    ml_gen_info_get_pred_proc_id(!.Info, CallerPredProcId),
                    ( if CalleePredProcId = CallerPredProcId then
                        (
                            IsTargetOfSelfTRCall0 = is_target_of_self_trcall
                        ;
                            IsTargetOfSelfTRCall0 = is_not_target_of_self_trcall,
                            InSccInfo = InSccInfo0 ^ isi_is_target_of_self_tr
                                := is_target_of_self_trcall,
                            map.det_update(CalleePredProcId, InSccInfo,
                                InSccMap0, InSccMap),
                            TailRecInfo = TailRecInfo0 ^
                                tri_in_scc_map := InSccMap,
                            ml_gen_info_set_tail_rec_info(TailRecInfo, !Info)
                        )
                    else
                        (
                            IsTargetOfMutualTRCall0 = is_target_of_mutual_trcall
                        ;
                            IsTargetOfMutualTRCall0 =
                                is_not_target_of_mutual_trcall,
                            InSccInfo = InSccInfo0 ^ isi_is_target_of_mutual_tr
                                := is_target_of_mutual_trcall,
                            map.det_update(CalleePredProcId, InSccInfo,
                                InSccMap0, InSccMap),
                            TailRecInfo = TailRecInfo0 ^
                                tri_in_scc_map := InSccMap,
                            ml_gen_info_set_tail_rec_info(TailRecInfo, !Info)
                        )
                    )
                else
                    ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel,
                        Context, CallerArgs,
                        ntrcr_mlds_model_non_in_cont_func, Features,
                        LocalVarDefns, FuncDefns, Stmts, !Info)
                )
            ;
                DanglingStackRef = may_yield_dangling_stack_ref,
                ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel,
                    Context, CallerArgs,
                    ntrcr_mlds_in_tscc_stack_ref, Features,
                    LocalVarDefns, FuncDefns, Stmts, !Info)
            )
        ;
            MaybeInTscc = not_in_tscc,
            ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel,
                Context, CallerArgs, ntrcr_mlds_in_scc_not_in_tscc, Features,
                LocalVarDefns, FuncDefns, Stmts, !Info)
        )
    else
        ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel,
            Context, CallerArgs, ntrcr_program, Features,
            LocalVarDefns, FuncDefns, Stmts, !Info)
    ).

ml_gen_plain_non_tail_call(CalleePredProcId, CodeModel, Context, CallerArgs,
        NonTailCallReason, Features, LocalVarDefns, FuncDefns, Stmts, !Info) :-
    % Generate the various parts of the code that is needed
    % for a procedure call:
    %
    % - declarations of variables needed for boxing/unboxing output arguments;
    % - code to call the function with the input arguments appropriately boxed,
    %   and
    % - code to unbox/box the return values.
    %
    % For example, if the callee is declared as
    %
    %   :- some [T2]
    %      pred callee(float::in, T1::in, float::out, T2::out, ...).
    %
    % then for a call `callee(Arg1, Arg2, Arg3, Arg4, ...)'
    % with arguments of types `U1, float, U2, float, ...',
    % we generate the following fragments:
    %
    %   /* declarations of variables needed for boxing/unboxing */
    %   Float conv_Arg3;
    %   MR_Box conv_Arg4;
    %   ...
    %
    %   /* code to call the function */
    %   func(unbox(Arg1), box(Arg2), &conv0_Arg3, &conv1_Arg4);
    %
    %   /* code to box/unbox the output arguments */
    %   *Arg3 = box(conv0_Arg3);
    %   *Arg4 = unbox(conv1_Arg4);
    %   ...
    %
    % Note that in general not every argument will need to be boxed/unboxed;
    % for those where no conversion is required, we just pass the
    % original argument unchanged.
    %

    % Compute the function signature.
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ml_gen_proc_params_no_gc_stmts(ModuleInfo, CalleePredProcId,
        _ArgTuples, Params),
    Signature = mlds_get_func_signature(Params),

    % Compute the function address.
    ml_gen_proc_addr_rval(CalleePredProcId, _FuncProcLabel, FuncRval, !Info),

    % Compute the callee's Mercury argument types and modes.
    module_info_pred_proc_info(ModuleInfo, CalleePredProcId,
        PredInfo, ProcInfo),
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    pred_info_get_arg_types(PredInfo, CalleeArgTypes),
    proc_info_get_argmodes(ProcInfo, CalleeArgModes),

    % Generate code to box/unbox the arguments and compute the list of
    % properly converted rvals/lvals to pass as the function call's arguments
    % and return values.
    ml_gen_args(PredOrFunc, CodeModel, Context, input_and_output_params,
        CalleeArgTypes, CalleeArgModes, CallerArgs,
        InputRvals, OutputLvalsTypes,
        ConvOutputDefns, ConvOutputStmts, !Info),

    proc_info_interface_determinism(ProcInfo, Detism),

    ( if
        ConvOutputDefns = [],
        ConvOutputStmts = []
    then
        % Generate the call directly (as opposed to via DoGenCall)
        % in the common case.
        ml_gen_mlds_call(Signature, FuncRval,
            InputRvals, OutputLvalsTypes, Detism, Context,
            LocalVarDefns, FuncDefns, Stmts, !Info)
    else
        % Construct a closure to generate the call. We can't actually generate
        % the call yet, since it might be nondet, and we don't yet know
        % what its success continuation will be. That is why we construct
        % a closure `DoGenCall', which, when called by ml_combine_conj, will
        % generate it.
        DoGenCall = ml_gen_mlds_call(Signature, FuncRval,
            InputRvals, OutputLvalsTypes, Detism, Context),

        % Construct a closure to generate code to convert the output arguments
        % and then succeed.
        DoGenConvOutputAndSucceed =
            ( pred(COAS_LocalVarDefns::out, COAS_FuncDefns::out,
                    COAS_Stmts::out, Info0::in, Info::out) is det :-
                COAS_LocalVarDefns = [],
                COAS_FuncDefns = [],
                ml_gen_success(CodeModel, Context, SucceedStmts, Info0, Info),
                COAS_Stmts = ConvOutputStmts ++ SucceedStmts
            ),

        % Conjoin the code generated by the two closures that we computed
        % above. `ml_combine_conj' will generate whatever kind of sequence
        % is necessary for this code model.
        ml_combine_conj(CodeModel, Context, DoGenCall,
            DoGenConvOutputAndSucceed,
            CallAndConvOutputLocalVarDefns, CallAndConvOutputFuncDefns,
            CallAndConvOutputStmts, !Info),
        LocalVarDefns = ConvOutputDefns ++ CallAndConvOutputLocalVarDefns,
        FuncDefns = CallAndConvOutputFuncDefns,
        Stmts = CallAndConvOutputStmts
    ),

    % If this is a non-tail call to a procedure in the current TSCC (if any),
    % we need to mark the callee as being an entry point.
    ml_gen_info_get_tail_rec_info(!.Info, TailRecInfo0),
    InSccMap0 = TailRecInfo0 ^ tri_in_scc_map,
    ( if map.search(InSccMap0, CalleePredProcId, InSccInfo0) then
        ml_gen_info_get_pred_proc_id(!.Info, CallerPredProcId),
        ml_gen_info_get_disabled_warnings(!.Info, Warnings),
        ( if set.contains(Warnings, goal_warning_non_tail_recursive_calls) then
            Status = nontail_rec_call_warn_disabled
        else
            Status = nontail_rec_call_warn_enabled
        ),
        ( if set.contains(Features, feature_obvious_nontail_rec_call) then
            Obviousness = obvious_nontail_rec
        else
            Obviousness = non_obvious_nontail_rec
        ),
        NonTailRecCall = nontail_rec_call(CallerPredProcId, CalleePredProcId,
            Context, NonTailCallReason, Obviousness, Status),
        NonTailRecCalls0 = InSccInfo0 ^ isi_is_target_of_non_tail_rec,
        NonTailRecCalls = [NonTailRecCall | NonTailRecCalls0],
        InSccInfo = InSccInfo0 ^ isi_is_target_of_non_tail_rec
            := NonTailRecCalls,
        map.det_update(CalleePredProcId, InSccInfo, InSccMap0, InSccMap),
        TailRecInfo = TailRecInfo0 ^ tri_in_scc_map := InSccMap,
        ml_gen_info_set_tail_rec_info(TailRecInfo, !Info)
    else
        true
    ).

    % Generate an rval containing the address of the specified procedure.
    %
:- pred ml_gen_proc_addr_rval(pred_proc_id::in, mlds_proc_label::out,
    mlds_rval::out, ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_proc_addr_rval(PredProcId, ProcLabel, CodeAddrRval, !Info) :-
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ml_gen_pred_label(ModuleInfo, PredProcId, PredLabel, PredModule),
    ml_gen_info_proc_params(PredProcId, _ArgTuples, Params,
        _ByRefOutputVars, _CopiedOutputVars, !Info),
    Signature = mlds_get_func_signature(Params),
    PredProcId = proc(_PredId, ProcId),
    ProcLabel = mlds_proc_label(PredLabel, ProcId),
    FuncLabel = mlds_func_label(ProcLabel, proc_func),
    QualFuncLabel = qual_func_label(PredModule, FuncLabel),
    CodeAddrRval = ml_const(mlconst_code_addr(
        mlds_code_addr(QualFuncLabel, Signature))).

%---------------------------------------------------------------------------%

    % This generates a call in the specified code model.
    % This is a lower-level routine called by both ml_gen_call
    % and ml_gen_generic_call.
    %
:- pred ml_gen_mlds_call(mlds_func_signature::in,
    mlds_rval::in, list(mlds_rval)::in, assoc_list(mlds_lval, mlds_type)::in,
    determinism::in, prog_context::in,
    list(mlds_local_var_defn)::out, list(mlds_function_defn)::out,
    list(mlds_stmt)::out, ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_mlds_call(Signature, FuncRval, ArgRvals0, RetLvalsTypes0,
        Detism, Context, LocalVarDefns, FuncDefns, Stmts, !Info) :-
    % Append the extra arguments or return val for this code_model.
    determinism_to_code_model(Detism, CodeModel),
    (
        CodeModel = model_non,
        % Create a new success continuation, if necessary.
        ml_gen_success_cont(RetLvalsTypes0, Context, Cont, FuncDefns, !Info),
        % Append the success continuation to the ordinary arguments.
        Cont = success_cont(FuncPtrRval, EnvPtrRval, _),
        ArgRvals = ArgRvals0 ++ [FuncPtrRval, EnvPtrRval],
        % For --nondet-copy-out, the output arguments will be passed to the
        % continuation rather than being returned.
        ml_gen_info_get_nondet_copy_out(!.Info, NondetCopyOut),
        (
            NondetCopyOut = yes,
            RetLvals = []
        ;
            NondetCopyOut = no,
            assoc_list.keys(RetLvalsTypes0, RetLvals)
        )
    ;
        CodeModel = model_semi,
        % Return a bool indicating whether or not it succeeded.
        ml_success_lval(Success, !Info),
        ArgRvals = ArgRvals0,
        assoc_list.keys(RetLvalsTypes0, RetLvals0),
        RetLvals = [Success | RetLvals0],
        FuncDefns = []
    ;
        CodeModel = model_det,
        ArgRvals = ArgRvals0,
        assoc_list.keys(RetLvalsTypes0, RetLvals),
        FuncDefns = []
    ),
    LocalVarDefns = [],

    % Build the MLDS call statement.
    %
    % If the called procedure has determinism `erroneous', then mark it
    % as never returning (this will ensure that it gets treated as a tail
    % call).
    ( if Detism = detism_erroneous then
        CallKind = no_return_call
    else
        CallKind = ordinary_call
    ),
    ml_gen_info_get_disabled_warnings(!.Info, Warnings),
    ( if set.contains(Warnings, goal_warning_non_tail_recursive_calls) then
        Markers = set.make_singleton_set(mcm_disable_non_tail_rec_warning)
    else
        set.init(Markers)
    ),
    Stmt = ml_stmt_call(Signature, FuncRval, ArgRvals, RetLvals,
        CallKind, Markers, Context),
    Stmts = [Stmt].

:- pred ml_gen_success_cont(assoc_list(mlds_lval, mlds_type)::in,
    prog_context::in, success_cont::out, list(mlds_function_defn)::out,
    ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_success_cont(OutputArgLvalsTypes, Context, NewCont, ContDecls, !Info) :-
    ml_gen_info_current_success_cont(!.Info, CurrentCont),
    CurrentCont = success_cont(_FuncPtrRval, _EnvPtrRval,
        CurrentContArgLvalsTypes),
    ( if
        % As an optimization, check if the parameters expected by the current
        % continuation are the same as the ones expected by the new
        % continuation that we are generating; if so, we can just use the
        % current continuation rather than creating a new one.
        %
        CurrentContArgLvalsTypes = OutputArgLvalsTypes
    then
        NewCont = CurrentCont,
        ContDecls = []
    else
        % Create a new continuation function that just copies the outputs
        % to locals and then calls the original current continuation.
        %
        % Note that ml_gen_cont_params does not fill in the gc_statement
        % for the parameters. This is OK, because the parameters of the
        % continuation function will not be live across any heap allocations or
        % procedure calls.
        %
        ml_gen_cont_params(OutputArgLvalsTypes, Params, !Info),
        ml_gen_new_func_label(yes(Params),
            ContFuncLabel, ContFuncLabelRval, !Info),
        % Push nesting level.
        ml_gen_copy_args_to_locals(OutputArgLvalsTypes, Context, CopyStmts),
        ml_gen_call_current_success_cont(Context, CallContStmt, !Info),
        CopyStmt = ml_gen_block([], [], CopyStmts ++ [CallContStmt], Context),
        % Pop nesting level.
        ml_gen_label_func(!.Info, ContFuncLabel, Params, Context,
            CopyStmt, ContFuncDefn),
        ContDecls = [ContFuncDefn],

        ml_get_env_ptr(EnvPtrRval),
        NewCont = success_cont(ContFuncLabelRval, EnvPtrRval,
            OutputArgLvalsTypes)
    ).

%---------------------------------------------------------------------------%

    % Generate the appropriate MLDS type for a continuation function
    % for a nondet procedure whose output arguments have the specified types.
    %
    % WARNING: this does not fill in the gc_statement for the function
    % parameters. It is the caller's responsibility to fill these in properly
    % if needed.
    %
:- pred ml_gen_cont_params(assoc_list(mlds_lval, mlds_type)::in,
    mlds_func_params::out, ml_gen_info::in, ml_gen_info::out) is det.

ml_gen_cont_params(OutputArgLvalsTypes, Params, !Info) :-
    ml_gen_cont_params_loop(OutputArgLvalsTypes, 1, Args0),
    ml_declare_env_ptr_arg(EnvPtrArg),
    Args = Args0 ++ [EnvPtrArg],
    Params = mlds_func_params(Args, []).

:- pred ml_gen_cont_params_loop(assoc_list(mlds_lval, mlds_type)::in, int::in,
    list(mlds_argument)::out) is det.

ml_gen_cont_params_loop([], _, []).
ml_gen_cont_params_loop([_Lval - Type | LvalsTypes], ArgNum,
        [Argument | Arguments]) :-
    ArgName = lvn_comp_var(lvnc_arg(ArgNum)),
    % Figuring out the correct GC code here is difficult, since doing that
    % requires knowing the HLDS types, but here we only have the MLDS types.
    % So here we just leave it blank. The caller of ml_gen_cont_param has the
    % responsibility of filling this in properly if needed.
    GCStmt = gc_no_stmt,
    Argument = mlds_argument(ArgName, Type, GCStmt),
    ml_gen_cont_params_loop(LvalsTypes, ArgNum + 1, Arguments).

:- pred ml_gen_copy_args_to_locals(assoc_list(mlds_lval, mlds_type)::in,
    prog_context::in, list(mlds_stmt)::out) is det.

ml_gen_copy_args_to_locals(ArgLvalsTypes, Context, CopyStmts) :-
    ml_gen_copy_args_to_locals_loop(ArgLvalsTypes, 1, Context, CopyStmts).

:- pred ml_gen_copy_args_to_locals_loop(assoc_list(mlds_lval, mlds_type)::in,
    int::in, prog_context::in, list(mlds_stmt)::out) is det.

ml_gen_copy_args_to_locals_loop([], _, _, []).
ml_gen_copy_args_to_locals_loop([LocalLvalType | LocalLvalsTypes], ArgNum,
        Context, [Stmt | Stmts]) :-
    LocalLvalType = LocalLval - Type,
    ArgName = lvn_comp_var(lvnc_arg(ArgNum)),
    ArgLval = ml_local_var(ArgName, Type),
    Stmt = ml_gen_assign(LocalLval, ml_lval(ArgLval), Context),
    ml_gen_copy_args_to_locals_loop(LocalLvalsTypes, ArgNum + 1,
        Context, Stmts).

%---------------------------------------------------------------------------%
%
% Code for builtins.
%

ml_gen_builtin(PredId, ProcId, ArgVars, CodeModel, Context,
        LocalVarDefns, FuncDefns, Stmts, !Info) :-
    ml_gen_var_list(!.Info, ArgVars, ArgLvals),
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ModuleName = predicate_module(ModuleInfo, PredId),
    PredName = predicate_name(ModuleInfo, PredId),
    builtin_ops.translate_builtin(ModuleName, PredName, ProcId, ArgLvals,
        SimpleCode),
    (
        CodeModel = model_det,
        (
            SimpleCode = assign(Lval, SimpleExpr),
            ( if
                % We need to avoid generating assignments to dummy variables
                % introduced for types such as io.state.
                Lval = ml_local_var(_VarName, VarType),
                VarType = mercury_type(ProgDataType, _, _),
                check_dummy_type(ModuleInfo, ProgDataType) = is_dummy_type
            then
                Stmts = []
            else
                Rval = ml_gen_simple_expr(SimpleExpr),
                Stmt = ml_gen_assign(Lval, Rval, Context),
                Stmts = [Stmt]
            )
        ;
            SimpleCode = ref_assign(AddrLval, ValueLval),
            ( if ValueLval = ml_local_var(_ValueVarName, ValueType) then
                Stmt = ml_gen_assign(
                    ml_mem_ref(ml_lval(AddrLval), ValueType),
                    ml_lval(ValueLval), Context),
                Stmts = [Stmt]
            else
                unexpected($pred, "malformed ref_assign")
            )
        ;
            SimpleCode = test(_),
            unexpected($pred, "malformed model_det builtin predicate")
        ;
            SimpleCode = noop(_),
            Stmts = []
        )
    ;
        CodeModel = model_semi,
        (
            SimpleCode = test(SimpleTest),
            TestRval = ml_gen_simple_expr(SimpleTest),
            ml_gen_set_success(TestRval, Context, Stmt, !Info),
            Stmts = [Stmt]
        ;
            SimpleCode = ref_assign(_, _),
            unexpected($pred, "malformed model_semi builtin predicate")
        ;
            SimpleCode = assign(_, _),
            unexpected($pred, "malformed model_semi builtin predicate")
        ;
            SimpleCode = noop(_),
            unexpected($pred, "malformed model_semi builtin predicate")
        )
    ;
        CodeModel = model_non,
        unexpected($pred, "model_non builtin predicate")
    ),
    LocalVarDefns = [],
    FuncDefns = [].

:- func ml_gen_simple_expr(simple_expr(mlds_lval)) = mlds_rval.

ml_gen_simple_expr(leaf(Lval)) = ml_lval(Lval).
ml_gen_simple_expr(int_const(Int)) = ml_const(mlconst_int(Int)).
ml_gen_simple_expr(uint_const(UInt)) = ml_const(mlconst_uint(UInt)).
ml_gen_simple_expr(int8_const(Int8)) = ml_const(mlconst_int8(Int8)).
ml_gen_simple_expr(uint8_const(UInt8)) = ml_const(mlconst_uint8(UInt8)).
ml_gen_simple_expr(int16_const(Int16)) = ml_const(mlconst_int16(Int16)).
ml_gen_simple_expr(uint16_const(UInt16)) = ml_const(mlconst_uint16(UInt16)).
ml_gen_simple_expr(int32_const(Int32)) = ml_const(mlconst_int32(Int32)).
ml_gen_simple_expr(uint32_const(UInt32)) = ml_const(mlconst_uint32(UInt32)).
ml_gen_simple_expr(float_const(Float)) = ml_const(mlconst_float(Float)).
ml_gen_simple_expr(unary(Op, Expr)) =
    ml_unop(std_unop(Op), ml_gen_simple_expr(Expr)).
ml_gen_simple_expr(binary(Op, ExprA, ExprB)) =
    ml_binop(Op, ml_gen_simple_expr(ExprA), ml_gen_simple_expr(ExprB)).

%---------------------------------------------------------------------------%
:- end_module ml_backend.ml_call_gen.
%---------------------------------------------------------------------------%
