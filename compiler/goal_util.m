%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% Main author: conway.
%
% This module provides some functionality for renaming variables in goals.
% The predicates rename_var* take a structure and a mapping from var -> var
% and apply that translation. If a var in the input structure does not
% occur as a key in the mapping, then the variable is left unsubstituted.

% goal_util__create_variables takes a list of variables, a varset an
% initial translation mapping and an initial mapping from variable to
% type, and creates new instances of each of the source variables in the
% translation mapping, adding the new variable to the type mapping and
% updating the varset. The type for each new variable is found by looking
% in the type map given in the 5th argument - the last input.
% (This interface will not easily admit uniqueness in the type map for this
% reason - such is the sacrifice for generality.)

:- module goal_util.

%-----------------------------------------------------------------------------%

:- interface.

:- import_module hlds_goal, llds.
:- import_module list, map, bool.

	% goal_util__rename_vars_in_goals(GoalList, MustRename, Substitution,
	%	NewGoalList).
:- pred goal_util__rename_vars_in_goals(list(hlds__goal), bool, map(var, var),
	list(hlds__goal)).
:- mode goal_util__rename_vars_in_goals(in, in, in, out) is det.

:- pred goal_util__rename_vars_in_goal(hlds__goal, map(var, var), hlds__goal).
:- mode goal_util__rename_vars_in_goal(in, in, out) is det.

:- pred goal_util__must_rename_vars_in_goal(hlds__goal,
					map(var, var), hlds__goal).
:- mode goal_util__must_rename_vars_in_goal(in, in, out) is det.

:- pred goal_util__rename_var_list(list(var), bool, map(var, var), list(var)).
:- mode goal_util__rename_var_list(in, in, in, out) is det.

	% goal_util__create_variables(OldVariables, OldVarset, InitialVarTypes,
	%	InitialSubstitution, OldVarTypes, OldVarNames,  NewVarset,
	%	NewVarTypes, NewSubstitution)
:- pred goal_util__create_variables(list(var),
			varset, map(var, type), map(var, var),
			map(var, type),
			varset, varset, map(var, type), map(var, var)).
:- mode goal_util__create_variables(in, in, in, in, in, in, out, out, out)
		is det.

:- pred goal_util__goal_is_branched(hlds__goal_expr).
:- mode goal_util__goal_is_branched(in) is semidet.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module hlds_data, mode_util, code_aux, prog_data.
:- import_module list, map, set, std_util, assoc_list, term, require, varset.

%-----------------------------------------------------------------------------%

goal_util__create_variables([], Varset, VarTypes, Subn, _OldVarTypes,
		_OldVarNames, Varset, VarTypes, Subn).
goal_util__create_variables([V|Vs], Varset0, VarTypes0, Subn0, OldVarTypes,
					OldVarNames, Varset, VarTypes, Subn) :-
	(
		map__contains(Subn0, V)
	->
		Varset2 = Varset0,
		Subn1 = Subn0,
		VarTypes1 = VarTypes0
	;
		varset__new_var(Varset0, NV, Varset1),
		(
			varset__search_name(OldVarNames, V, Name)
		->
			varset__name_var(Varset1, NV, Name, Varset2)
		;
			Varset2 = Varset1
		),
		map__set(Subn0, V, NV, Subn1),
		(
			map__search(OldVarTypes, V, VT)
		->
			map__set(VarTypes0, NV, VT, VarTypes1)
		;
			VarTypes1 = VarTypes0
		)
	),
	goal_util__create_variables(Vs, Varset2, VarTypes1, Subn1, OldVarTypes,
		OldVarNames, Varset, VarTypes, Subn).

%-----------------------------------------------------------------------------%

:- pred goal_util__init_subn(assoc_list(var, var), map(var, var), map(var, var)).
:- mode goal_util__init_subn(in, in, out) is det.

goal_util__init_subn([], Subn, Subn).
goal_util__init_subn([A-H|Vs], Subn0, Subn) :-
	map__set(Subn0, H, A, Subn1),
	goal_util__init_subn(Vs, Subn1, Subn).

%-----------------------------------------------------------------------------%

goal_util__rename_var_list([], _Must, _Subn, []).
goal_util__rename_var_list([V|Vs], Must, Subn, [N|Ns]) :-
	goal_util__rename_var(V, Must, Subn, N),
	goal_util__rename_var_list(Vs, Must, Subn, Ns).

:- pred goal_util__rename_var(var, bool, map(var, var), var).
:- mode goal_util__rename_var(in, in, in, out) is det.

goal_util__rename_var(V, Must, Subn, N) :-
	(
		map__search(Subn, V, N0)
	->
		N = N0
	;
		( Must = no, N = V
		; Must = yes, error("goal_util__rename_var: no substitute") )
	).

%-----------------------------------------------------------------------------%

goal_util__rename_vars_in_goal(Goal0, Subn, Goal) :-
	goal_util__rename_vars_in_goal(Goal0, no, Subn, Goal).

goal_util__must_rename_vars_in_goal(Goal0, Subn, Goal) :-
	goal_util__rename_vars_in_goal(Goal0, yes, Subn, Goal).

%-----------------------------------------------------------------------------%

goal_util__rename_vars_in_goals([], _, _, []).
goal_util__rename_vars_in_goals([Goal0 | Goals0], Must, Subn, [Goal | Goals]) :-
	goal_util__rename_vars_in_goal(Goal0, Must, Subn, Goal),
	goal_util__rename_vars_in_goals(Goals0, Must, Subn, Goals).

:- pred goal_util__rename_vars_in_goal(hlds__goal, bool, map(var, var),
		hlds__goal).
:- mode goal_util__rename_vars_in_goal(in, in, in, out) is det.

goal_util__rename_vars_in_goal(Goal0 - GoalInfo0, Must, Subn, Goal - GoalInfo) :-
	goal_util__name_apart_2(Goal0, Must, Subn, Goal),
	goal_util__name_apart_goalinfo(GoalInfo0, Must, Subn, GoalInfo).

%-----------------------------------------------------------------------------%

:- pred goal_util__name_apart_2(hlds__goal_expr, bool, map(var, var),
		hlds__goal_expr).
:- mode goal_util__name_apart_2(in, in, in, out) is det.

goal_util__name_apart_2(conj(Goals0), Must, Subn, conj(Goals)) :-
	goal_util__name_apart_list(Goals0, Must, Subn, Goals).

goal_util__name_apart_2(disj(Goals0, FV0), Must, Subn, disj(Goals, FV)) :-
	goal_util__name_apart_list(Goals0, Must, Subn, Goals),
	goal_util__rename_follow_vars(FV0, Must, Subn, FV).

goal_util__name_apart_2(switch(Var0, Det, Cases0, FV0), Must, Subn,
		switch(Var, Det, Cases, FV)) :-
	goal_util__rename_var(Var0, Must, Subn, Var),
	goal_util__name_apart_cases(Cases0, Must, Subn, Cases),
	goal_util__rename_follow_vars(FV0, Must, Subn, FV).

goal_util__name_apart_2(if_then_else(Vars0, Cond0, Then0, Else0, FV0),
		Must, Subn, if_then_else(Vars, Cond, Then, Else, FV)) :-
	goal_util__rename_var_list(Vars0, Must, Subn, Vars),
	goal_util__rename_vars_in_goal(Cond0, Must, Subn, Cond),
	goal_util__rename_vars_in_goal(Then0, Must, Subn, Then),
	goal_util__rename_vars_in_goal(Else0, Must, Subn, Else),
	goal_util__rename_follow_vars(FV0, Must, Subn, FV).

goal_util__name_apart_2(not(Goal0), Must, Subn, not(Goal)) :-
	goal_util__rename_vars_in_goal(Goal0, Must, Subn, Goal).

goal_util__name_apart_2(some(Vars0, Goal0), Must, Subn, some(Vars, Goal)) :-
	goal_util__rename_var_list(Vars0, Must, Subn, Vars),
	goal_util__rename_vars_in_goal(Goal0, Must, Subn, Goal).

goal_util__name_apart_2(
		call(PredId, ProcId, Args0, Builtin, Context, Sym, FV0),
		Must, Subn,
		call(PredId, ProcId, Args, Builtin, Context, Sym, FV)) :-
	goal_util__rename_var_list(Args0, Must, Subn, Args),
	goal_util__rename_follow_vars(FV0, Must, Subn, FV).

goal_util__name_apart_2(unify(TermL0,TermR0,Mode,Unify0,Context), Must, Subn,
		unify(TermL,TermR,Mode,Unify,Context)) :-
	goal_util__rename_var(TermL0, Must, Subn, TermL),
	goal_util__rename_unify_rhs(TermR0, Must, Subn, TermR),
	goal_util__rename_unify(Unify0, Must, Subn, Unify).

goal_util__name_apart_2(pragma_c_code(A,B,C,Vars0,ArgNameMap0), Must, Subn, 
		pragma_c_code(A,B,C,Vars,ArgNameMap)) :-
	goal_util__rename_var_list(Vars0, Must, Subn, Vars),
		% also update the arg/name map since the vars have changed
	map__keys(ArgNameMap0, NArgs0),
	map__values(ArgNameMap0, Names),
	goal_util__rename_var_list(NArgs0, Must, Subn, NArgs),
	map__from_corresponding_lists(NArgs, Names, ArgNameMap).

%-----------------------------------------------------------------------------%

:- pred goal_util__name_apart_list(list(hlds__goal), bool, map(var, var),
							list(hlds__goal)).
:- mode goal_util__name_apart_list(in, in, in, out) is det.

goal_util__name_apart_list([], _Must, _Subn, []).
goal_util__name_apart_list([G0|Gs0], Must, Subn, [G|Gs]) :-
	goal_util__rename_vars_in_goal(G0, Must, Subn, G),
	goal_util__name_apart_list(Gs0, Must, Subn, Gs).

%-----------------------------------------------------------------------------%

:- pred goal_util__name_apart_cases(list(case), bool, map(var, var),
		list(case)).
:- mode goal_util__name_apart_cases(in, in, in, out) is det.

goal_util__name_apart_cases([], _Must, _Subn, []).
goal_util__name_apart_cases([case(Cons, G0)|Gs0], Must, Subn, [case(Cons, G)|Gs]) :-
	goal_util__rename_vars_in_goal(G0, Must, Subn, G),
	goal_util__name_apart_cases(Gs0, Must, Subn, Gs).

%-----------------------------------------------------------------------------%

	% These predicates probably belong in term.m.

:- pred goal_util__rename_args(list(term), bool, map(var, var), list(term)).
:- mode goal_util__rename_args(in, in, in, out) is det.

goal_util__rename_args([], _Must, _Subn, []).
goal_util__rename_args([T0|Ts0], Must, Subn, [T|Ts]) :-
	goal_util__rename_term(T0, Must, Subn, T),
	goal_util__rename_args(Ts0, Must, Subn, Ts).

:- pred goal_util__rename_term(term, bool, map(var, var), term).
:- mode goal_util__rename_term(in, in, in, out) is det.

goal_util__rename_term(term__variable(V), Must, Subn, term__variable(N)) :-
	goal_util__rename_var(V, Must, Subn, N).
goal_util__rename_term(term__functor(Cons, Terms0, Cont), Must, Subn,
				term__functor(Cons, Terms, Cont)) :-
	goal_util__rename_args(Terms0, Must, Subn, Terms).

%-----------------------------------------------------------------------------%

:- pred goal_util__rename_unify_rhs(unify_rhs, bool, map(var, var), unify_rhs).
:- mode goal_util__rename_unify_rhs(in, in, in, out) is det.

goal_util__rename_unify_rhs(var(Var0), Must, Subn, var(Var)) :-
	goal_util__rename_var(Var0, Must, Subn, Var).
goal_util__rename_unify_rhs(functor(Functor, ArgVars0), Must, Subn,
			functor(Functor, ArgVars)) :-
	goal_util__rename_var_list(ArgVars0, Must, Subn, ArgVars).
goal_util__rename_unify_rhs(lambda_goal(Vars0, Modes, Det, Goal0), Must, Subn,
			lambda_goal(Vars, Modes, Det, Goal)) :-
	goal_util__rename_var_list(Vars0, Must, Subn, Vars),
	goal_util__rename_vars_in_goal(Goal0, Must, Subn, Goal).

:- pred goal_util__rename_unify(unification, bool, map(var, var), unification).
:- mode goal_util__rename_unify(in, in, in, out) is det.

goal_util__rename_unify(construct(Var0, ConsId, Vars0, Modes), Must, Subn,
			construct(Var, ConsId, Vars, Modes)) :-
	goal_util__rename_var(Var0, Must, Subn, Var),
	goal_util__rename_var_list(Vars0, Must, Subn, Vars).
goal_util__rename_unify(deconstruct(Var0, ConsId, Vars0, Modes, Cat), Must, Subn,
			deconstruct(Var, ConsId, Vars, Modes, Cat)) :-
	goal_util__rename_var(Var0, Must, Subn, Var),
	goal_util__rename_var_list(Vars0, Must, Subn, Vars).
goal_util__rename_unify(assign(L0, R0), Must, Subn, assign(L, R)) :-
	goal_util__rename_var(L0, Must, Subn, L),
	goal_util__rename_var(R0, Must, Subn, R).
goal_util__rename_unify(simple_test(L0, R0), Must, Subn, simple_test(L, R)) :-
	goal_util__rename_var(L0, Must, Subn, L),
	goal_util__rename_var(R0, Must, Subn, R).
goal_util__rename_unify(complicated_unify(Modes, Cat, Follow0), Must, Subn,
			complicated_unify(Modes, Cat, Follow)) :-
	goal_util__rename_follow_vars(Follow0, Must, Subn, Follow).

%-----------------------------------------------------------------------------%

:- pred goal_util__rename_follow_vars(map(var, T), bool, map(var, var), map(var, T)).
:- mode goal_util__rename_follow_vars(in, in, in, out) is det.

goal_util__rename_follow_vars(Follow0, Must, Subn, Follow) :-
	map__to_assoc_list(Follow0, FollowList0),
	goal_util__rename_follow_vars_2(FollowList0, Must, Subn, FollowList),
	map__from_assoc_list(FollowList, Follow).

:- pred goal_util__rename_follow_vars_2(assoc_list(var, T),
				bool, map(var, var), assoc_list(var, T)).
:- mode goal_util__rename_follow_vars_2(in, in, in, out) is det.

goal_util__rename_follow_vars_2([], _Must, _Subn, []).
goal_util__rename_follow_vars_2([V - L | Vs], Must, Subn, [N - L | Ns]) :-
	goal_util__rename_var(V, Must, Subn, N),
	goal_util__rename_follow_vars_2(Vs, Must, Subn, Ns).

%-----------------------------------------------------------------------------%

:- pred goal_util__name_apart_goalinfo(hlds__goal_info,
					bool, map(var, var), hlds__goal_info).
:- mode goal_util__name_apart_goalinfo(in, in, in, out) is det.

goal_util__name_apart_goalinfo(GoalInfo0, Must, Subn, GoalInfo) :-
	goal_info_pre_delta_liveness(GoalInfo0, PreBirths0 - PreDeaths0),
	goal_util__name_apart_set(PreBirths0, Must, Subn, PreBirths),
	goal_util__name_apart_set(PreDeaths0, Must, Subn, PreDeaths),
	goal_info_set_pre_delta_liveness(GoalInfo0, PreBirths - PreDeaths,
						GoalInfo1),

	goal_info_post_delta_liveness(GoalInfo1, PostBirths0 - PostDeaths0),
	goal_util__name_apart_set(PostBirths0, Must, Subn, PostBirths),
	goal_util__name_apart_set(PostDeaths0, Must, Subn, PostDeaths),
	goal_info_set_pre_delta_liveness(GoalInfo1, PostBirths - PostDeaths,
						GoalInfo2),

	goal_info_get_nonlocals(GoalInfo2, NonLocals0),
	goal_util__name_apart_set(NonLocals0, Must, Subn, NonLocals),
	goal_info_set_nonlocals(GoalInfo2, NonLocals, GoalInfo3),

	goal_info_get_instmap_delta(GoalInfo3, MaybeInstMap0),
	(
		MaybeInstMap0 = reachable(InstMap0)
	->
		goal_util__rename_follow_vars(InstMap0, Must, Subn, InstMap),
		MaybeInstMap = reachable(InstMap)
	;
		MaybeInstMap = MaybeInstMap0
	),
	goal_info_set_instmap_delta(GoalInfo3, MaybeInstMap, GoalInfo4),

	goal_info_store_map(GoalInfo4, MaybeStoreMap0),
	(
		MaybeStoreMap0 = yes(StoreMap0)
	->
		goal_util__rename_follow_vars(StoreMap0, Must, Subn, StoreMap),
		MaybeStoreMap = yes(StoreMap)
	;
		MaybeStoreMap = MaybeStoreMap0
	),
	goal_info_set_store_map(GoalInfo4, MaybeStoreMap, GoalInfo).

%-----------------------------------------------------------------------------%

:- pred goal_util__name_apart_set(set(var), bool, map(var, var), set(var)).
:- mode goal_util__name_apart_set(in, in, in, out) is det.

goal_util__name_apart_set(Vars0, Must, Subn, Vars) :-
	set__to_sorted_list(Vars0, VarsList0),
	goal_util__rename_var_list(VarsList0, Must, Subn, VarsList),
	set__list_to_set(VarsList, Vars).

%-----------------------------------------------------------------------------%

goal_util__goal_is_branched(if_then_else(_, _, _, _, _)).
goal_util__goal_is_branched(switch(_, _, _, _)).
goal_util__goal_is_branched(disj(_, _)).

%-----------------------------------------------------------------------------%
