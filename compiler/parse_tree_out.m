%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2015 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% This module converts the top levels of the parse tree structure
% back into Mercury source text.
%
%---------------------------------------------------------------------------%

:- module parse_tree.parse_tree_out.
:- interface.

:- import_module libs.
:- import_module libs.globals.
:- import_module parse_tree.parse_tree_out_info.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_item.

:- import_module io.
:- import_module list.
:- import_module maybe.

%---------------------------------------------------------------------------%

    % convert_to_mercury_*(Globals, OutputFileName, ParseTree, !IO).
    %
:- pred convert_to_mercury_src(globals::in, string::in, parse_tree_src::in,
    io::di, io::uo) is det.
:- pred convert_to_mercury_int(globals::in, string::in, parse_tree_int::in,
    io::di, io::uo) is det.
:- pred convert_to_mercury_opt(globals::in, string::in, parse_tree_opt::in,
    io::di, io::uo) is det.

%---------------------------------------------------------------------------%

:- pred mercury_output_parse_tree_src(merc_out_info::in,
    parse_tree_src::in, io::di, io::uo) is det.

:- pred mercury_output_parse_tree_int(merc_out_info::in,
    parse_tree_int::in, io::di, io::uo) is det.

:- pred mercury_output_parse_tree_opt(merc_out_info::in,
    parse_tree_opt::in, io::di, io::uo) is det.

:- pred mercury_output_raw_compilation_unit(merc_out_info::in,
    raw_compilation_unit::in, io::di, io::uo) is det.

:- pred mercury_output_aug_compilation_unit(merc_out_info::in,
    aug_compilation_unit::in, io::di, io::uo) is det.

%---------------------------------------------------------------------------%

:- pred mercury_output_raw_item_blocks(merc_out_info::in,
    list(raw_item_block)::in, io::di, io::uo) is det.
:- pred mercury_output_raw_item_block(merc_out_info::in,
    raw_item_block::in, io::di, io::uo) is det.

:- pred mercury_output_src_item_blocks(merc_out_info::in,
    list(src_item_block)::in, io::di, io::uo) is det.
:- pred mercury_output_src_item_block(merc_out_info::in,
    src_item_block::in, io::di, io::uo) is det.
:- pred mercury_output_int_item_blocks(merc_out_info::in,
    list(int_item_block)::in, io::di, io::uo) is det.
:- pred mercury_output_int_item_block(merc_out_info::in,
    int_item_block::in, io::di, io::uo) is det.
:- pred mercury_output_opt_item_blocks(merc_out_info::in,
    list(opt_item_block)::in, io::di, io::uo) is det.
:- pred mercury_output_opt_item_block(merc_out_info::in,
    opt_item_block::in, io::di, io::uo) is det.
:- pred mercury_output_int_for_opt_item_blocks(merc_out_info::in,
    list(int_for_opt_item_block)::in, io::di, io::uo) is det.
:- pred mercury_output_int_for_opt_item_block(merc_out_info::in,
    int_for_opt_item_block::in, io::di, io::uo) is det.

%---------------------------------------------------------------------------%

:- pred mercury_output_item(merc_out_info::in, item::in, io::di, io::uo)
    is det.

%---------------------------------------------------------------------------%
%
% Output some components of type definitions.
%

:- pred mercury_output_where_attributes(merc_out_info::in, tvarset::in,
    maybe(solver_type_details)::in, maybe(unify_compare)::in,
    maybe(list(sym_name_and_arity))::in, io::di, io::uo) is det.

:- pred mercury_output_ctor(tvarset::in, constructor::in, io::di, io::uo)
    is det.

%---------------------------------------------------------------------------%
%
% Output some components of an instance definition.
%

:- pred mercury_output_instance_method(instance_method::in, io::di, io::uo)
    is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module libs.options.
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.
:- import_module mdbcomp.sym_name.
:- import_module parse_tree.file_kind.
:- import_module parse_tree.maybe_error.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.parse_inst_mode_name.
:- import_module parse_tree.parse_tree_out_clause.
:- import_module parse_tree.parse_tree_out_inst.
:- import_module parse_tree.parse_tree_out_pragma.
:- import_module parse_tree.parse_tree_out_pred_decl.
:- import_module parse_tree.parse_tree_out_term.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.prog_util.
:- import_module recompilation.
:- import_module recompilation.version.

:- import_module bool.
:- import_module cord.
:- import_module map.
:- import_module require.
:- import_module set.
:- import_module term.
:- import_module varset.

%---------------------------------------------------------------------------%

convert_to_mercury_src(Globals, OutputFileName, ParseTreeSrc, !IO) :-
    convert_to_mercury(Globals, OutputFileName, mercury_output_parse_tree_src,
        ParseTreeSrc, !IO).

convert_to_mercury_int(Globals, OutputFileName, ParseTreeInt, !IO) :-
    convert_to_mercury(Globals, OutputFileName, mercury_output_parse_tree_int,
        ParseTreeInt, !IO).

convert_to_mercury_opt(Globals, OutputFileName, ParseTreeOpt, !IO) :-
    convert_to_mercury(Globals, OutputFileName, mercury_output_parse_tree_opt,
        ParseTreeOpt, !IO).

:- type output_parse_tree(PT) == pred(merc_out_info, PT, io, io).
:- inst output_parse_tree == (pred(in, in, di, uo) is det).

:- pred convert_to_mercury(globals::in, string::in,
    output_parse_tree(PT)::in(output_parse_tree), PT::in,
    io::di, io::uo) is det.

convert_to_mercury(Globals, OutputFileName, OutputParseTree, ParseTree, !IO) :-
    io.open_output(OutputFileName, Res, !IO),
    (
        Res = ok(FileStream),
        globals.lookup_bool_option(Globals, verbose, Verbose),
        (
            Verbose = yes,
            io.write_string("% Writing output to ", !IO),
            io.write_string(OutputFileName, !IO),
            io.write_string("...", !IO),
            io.flush_output(!IO)
        ;
            Verbose = no
        ),
        io.set_output_stream(FileStream, OutputStream, !IO),

        % Module qualifiers on items are redundant after the
        % declaration above.
        Info = init_merc_out_info(Globals, unqualified_item_names,
            output_mercury),
        OutputParseTree(Info, ParseTree, !IO),
        io.set_output_stream(OutputStream, _, !IO),
        io.close_output(FileStream, !IO),
        (
            Verbose = yes,
            io.write_string(" done\n", !IO)
        ;
            Verbose = no
        )
    ;
        Res = error(_),
        io.write_string("Error: couldn't open file `", !IO),
        io.write_string(OutputFileName, !IO),
        io.write_string("' for output.\n", !IO)
    ).

%---------------------------------------------------------------------------%

mercury_output_parse_tree_src(Info, ParseTree, !IO) :-
    ParseTree = parse_tree_src(ModuleName, _Context, ModuleComponentsCord),
    io.write_string(":- module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO),
    ModuleComponents = cord.list(ModuleComponentsCord),
    mercury_output_module_components(Info, no, ModuleComponents, !IO),
    io.write_string(":- end_module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO).

mercury_output_parse_tree_int(Info, ParseTree, !IO) :-
    ParseTree = parse_tree_int(ModuleName, _IntFileKind, ModuleContext,
        MaybeVersionNumbers, IntIncls, ImpIncls, IntAvails, ImpAvails,
        IntItems, ImpItems),
    io.write_string(":- module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO),
    (
        MaybeVersionNumbers = no
    ;
        MaybeVersionNumbers = yes(VersionNumbers),
        mercury_output_module_version_numbers(ModuleName, VersionNumbers, !IO)
    ),
    ( if
        IntIncls = [],
        IntAvails = [],
        IntItems = []
    then
        true
    else
        IntItemBlock = item_block(ms_interface, ModuleContext,
            IntIncls, IntAvails, IntItems),
        mercury_output_raw_item_block(Info, IntItemBlock, !IO)
    ),
    ( if
        ImpIncls = [],
        ImpAvails = [],
        ImpItems = []
    then
        true
    else
        ImpItemBlock = item_block(ms_implementation, ModuleContext,
            ImpIncls, ImpAvails, ImpItems),
        mercury_output_raw_item_block(Info, ImpItemBlock, !IO)
    ).

mercury_output_parse_tree_opt(Info, ParseTree, !IO) :-
    ParseTree = parse_tree_opt(ModuleName, _OptFileKind, _Context,
        Use, Items),
    io.write_string(":- module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO),
    list.foldl(mercury_output_item_use(Info), Use, !IO),
    mercury_output_items(Info, Items, !IO).

mercury_output_raw_compilation_unit(Info, CompUnit, !IO) :-
    CompUnit = raw_compilation_unit(ModuleName, _Context, ItemBlocks),
    io.write_string(":- module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO),
    mercury_output_raw_item_blocks(Info, ItemBlocks, !IO).

mercury_output_aug_compilation_unit(Info, AugCompUnit, !IO) :-
    AugCompUnit = aug_compilation_unit(ModuleName, _Context,
        ModuleVersionNumbers, SrcItemBlocks,
        DirectIntItemBlocks, IndirectIntItemBlocks,
        OptItemBlocks, IntForOptItemBlocks),
    io.write_string(":- module ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO),
    io.write_string("% The module version numbers.\n", !IO),
    map.foldl(mercury_output_module_version_numbers,
        ModuleVersionNumbers, !IO),
    io.write_string("% The src item blocks.\n", !IO),
    mercury_output_src_item_blocks(Info, SrcItemBlocks, !IO),
    io.write_string("% The direct interface item blocks.\n", !IO),
    mercury_output_int_item_blocks(Info, DirectIntItemBlocks, !IO),
    io.write_string("% The indirect interface item blocks.\n", !IO),
    mercury_output_int_item_blocks(Info, IndirectIntItemBlocks, !IO),
    io.write_string("% The optimization item blocks.\n", !IO),
    mercury_output_opt_item_blocks(Info, OptItemBlocks, !IO),
    io.write_string("% The interface item blocks for optimization.\n", !IO),
    mercury_output_int_for_opt_item_blocks(Info, IntForOptItemBlocks, !IO).

:- pred mercury_output_module_version_numbers(module_name::in,
    version_numbers::in, io::di, io::uo) is det.

mercury_output_module_version_numbers(ModuleName, VersionNumbers, !IO) :-
    io.write_string(":- version_numbers(", !IO),
    io.write_int(version_numbers_version_number, !IO),
    io.write_string(", ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(",\n", !IO),
    recompilation.version.write_version_numbers(VersionNumbers, !IO),
    io.write_string(").\n", !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_module_components(merc_out_info::in,
    maybe(module_section)::in, list(module_component)::in,
    io::di, io::uo) is det.

mercury_output_module_components(_, _, [], !IO).
mercury_output_module_components(Info, MaybePrevSectionKind,
        [Component | Components], !IO) :-
    (
        Component = mc_section(SectionKind, _Context,
            InclsCord, AvailsCord, ItemsCord),
        mercury_output_section_marker(SectionKind, !IO),
        list.foldl(mercury_output_item_include(Info),
            cord.list(InclsCord), !IO),
        list.foldl(mercury_output_item_avail(Info),
            cord.list(AvailsCord), !IO),
        mercury_output_items(Info, cord.list(ItemsCord), !IO),
        MaybeCurSectionKind = yes(SectionKind)
    ;
        Component = mc_nested_submodule(SectionKind, _SectionContext,
            SubParseTree),
        Lang = get_output_lang(Info),
        (
            Lang = output_mercury,
            ( if
                MaybePrevSectionKind = yes(PrevSectionKind),
                PrevSectionKind = SectionKind
            then
                true
            else
                mercury_output_section_marker(SectionKind, !IO)
            )
        ;
            Lang = output_debug,
            mercury_output_section_marker(SectionKind, !IO),
            (
                SectionKind = ms_interface,
                io.write_string("% nested submodule in interface\n", !IO)
            ;
                SectionKind = ms_implementation,
                io.write_string("% nested submodule in implementation\n", !IO)
            )
        ),
        mercury_output_parse_tree_src(Info, SubParseTree, !IO),
        MaybeCurSectionKind = MaybePrevSectionKind
    ),
    mercury_output_module_components(Info, MaybeCurSectionKind,
        Components, !IO).

%---------------------------------------------------------------------------%

mercury_output_raw_item_blocks(_, [], !IO).
mercury_output_raw_item_blocks(Info, [RawItemBlock | RawItemBlocks], !IO) :-
    mercury_output_raw_item_block(Info, RawItemBlock, !IO),
    mercury_output_raw_item_blocks(Info, RawItemBlocks, !IO).

mercury_output_raw_item_block(Info, RawItemBlock, !IO) :-
    RawItemBlock = item_block(SectionKind, _Context, Incls, Avails, Items),
    mercury_output_section_marker(SectionKind, !IO),
    list.foldl(mercury_output_item_include(Info), Incls, !IO),
    list.foldl(mercury_output_item_avail(Info), Avails, !IO),
    mercury_output_items(Info, Items, !IO).

%---------------------------------------------------------------------------%

mercury_output_src_item_blocks(_, [], !IO).
mercury_output_src_item_blocks(Info, [SrcItemBlock | SrcItemBlocks], !IO) :-
    mercury_output_src_item_block(Info, SrcItemBlock, !IO),
    mercury_output_src_item_blocks(Info, SrcItemBlocks, !IO).

mercury_output_src_item_block(Info, SrcItemBlock, !IO) :-
    SrcItemBlock = item_block(SrcSectionKind, _Context, Incls, Avails, Items),
    mercury_output_src_section_marker(SrcSectionKind, !IO),
    list.foldl(mercury_output_item_include(Info), Incls, !IO),
    list.foldl(mercury_output_item_avail(Info), Avails, !IO),
    mercury_output_items(Info, Items, !IO).

mercury_output_int_item_blocks(_, [], !IO).
mercury_output_int_item_blocks(Info, [IntItemBlock | IntItemBlocks], !IO) :-
    mercury_output_int_item_block(Info, IntItemBlock, !IO),
    mercury_output_int_item_blocks(Info, IntItemBlocks, !IO).

mercury_output_int_item_block(Info, IntItemBlock, !IO) :-
    IntItemBlock = item_block(IntSectionKind, _Context, Incls, Avails, Items),
    list.foldl(mercury_output_item_include(Info), Incls, !IO),
    list.foldl(mercury_output_item_avail(Info), Avails, !IO),
    mercury_output_int_section_marker(IntSectionKind, !IO),
    mercury_output_items(Info, Items, !IO).

mercury_output_opt_item_blocks(_, [], !IO).
mercury_output_opt_item_blocks(Info, [OptItemBlock | OptItemBlocks], !IO) :-
    mercury_output_opt_item_block(Info, OptItemBlock, !IO),
    mercury_output_opt_item_blocks(Info, OptItemBlocks, !IO).

mercury_output_opt_item_block(Info, OptItemBlock, !IO) :-
    OptItemBlock = item_block(OptSectionKind, _Context, Incls, Avails, Items),
    expect(unify(Incls, []), $module, $pred, "Incls != []"),
    list.foldl(mercury_output_item_avail(Info), Avails, !IO),
    mercury_output_opt_section_marker(OptSectionKind, !IO),
    mercury_output_items(Info, Items, !IO).

mercury_output_int_for_opt_item_blocks(_, [], !IO).
mercury_output_int_for_opt_item_blocks(Info,
        [IntForOptItemBlock | IntForOptItemBlocks], !IO) :-
    mercury_output_int_for_opt_item_block(Info, IntForOptItemBlock, !IO),
    mercury_output_int_for_opt_item_blocks(Info, IntForOptItemBlocks, !IO).

mercury_output_int_for_opt_item_block(Info, IntForOptItemBlock, !IO) :-
    IntForOptItemBlock = item_block(IntForOptSectionKind, _Context,
        Incls, Avails, Items),
    list.foldl(mercury_output_item_include(Info), Incls, !IO),
    list.foldl(mercury_output_item_avail(Info), Avails, !IO),
    mercury_output_int_for_opt_section_marker(IntForOptSectionKind, !IO),
    mercury_output_items(Info, Items, !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_section_marker(module_section::in, io::di, io::uo)
    is det.

mercury_output_section_marker(Section, !IO) :-
    (
        Section = ms_interface,
        io.write_string(":- interface.\n", !IO)
    ;
        Section = ms_implementation,
        io.write_string(":- implementation.\n", !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_src_section_marker(src_module_section::in,
    io::di, io::uo) is det.

mercury_output_src_section_marker(SrcSection, !IO) :-
    (
        SrcSection = sms_interface,
        io.write_string(":- interface.\n", !IO)
    ;
        SrcSection = sms_implementation,
        io.write_string(":- implementation.\n", !IO)
    ;
        SrcSection = sms_impl_but_exported_to_submodules,
        io.write_string(":- ams_impl_but_exported_to_submodules.\n", !IO)
    ).

:- pred mercury_output_int_section_marker(int_module_section::in,
    io::di, io::uo) is det.

mercury_output_int_section_marker(IntSection, !IO) :-
    (
        IntSection = ims_imported_or_used(ModuleName, IntFileKind,
            ImportLocn, ImportedOrUsed),
        (
            ImportedOrUsed = iou_imported,
            io.write_string(":- ims_imported", !IO)
        ;
            ImportedOrUsed = iou_used,
            io.write_string(":- ims_used", !IO)
        ;
            ImportedOrUsed = iou_used_and_imported,
            io.write_string(":- ims_used_and_imported", !IO)
        ),
        io.write_string("(", !IO),
        io.write_string(sym_name_to_string(ModuleName), !IO),
        io.write_string(int_file_kind_to_extension(IntFileKind), !IO),
        io.write_string(", ", !IO),
        io.write(ImportLocn, !IO),
        io.write_string(").\n", !IO)
    ;
        IntSection = ims_abstract_imported(ModuleName, IntFileKind),
        io.write_string(":- ims_abstract_imported(", !IO),
        io.write_string(sym_name_to_string(ModuleName), !IO),
        io.write_string(int_file_kind_to_extension(IntFileKind), !IO),
        io.write_string(").\n", !IO)
    ).

:- pred mercury_output_opt_section_marker(opt_module_section::in,
    io::di, io::uo) is det.

mercury_output_opt_section_marker(OptSection, !IO) :-
    (
        OptSection = oms_opt_imported(ModuleName, OptFileKind),
        io.write_string(":- oms_opt_imported(", !IO),
        io.write_string(sym_name_to_string(ModuleName), !IO),
        io.write_string(opt_file_kind_to_extension(OptFileKind), !IO),
        io.write_string(").\n", !IO)
    ).

:- pred mercury_output_int_for_opt_section_marker(
    int_for_opt_module_section::in, io::di, io::uo) is det.

mercury_output_int_for_opt_section_marker(IntForOptSection, !IO) :-
    (
        IntForOptSection = ioms_opt_imported(ModuleName, IntFileKind),
        io.write_string(":- ioms_opt_imported(", !IO),
        io.write_string(sym_name_to_string(ModuleName), !IO),
        io.write_string(int_file_kind_to_extension(IntFileKind), !IO),
        io.write_string(").\n", !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_include(merc_out_info::in,
    item_include::in, io::di, io::uo) is det.

mercury_output_item_include(Info, ItemInclude, !IO) :-
    ItemInclude = item_include(ModuleName, Context, _SeqNum),
    Decl = "include_module",
    maybe_output_line_number(Info, Context, !IO),
    mercury_output_module_decl(Decl, ModuleName, !IO).

:- pred mercury_output_item_avail(merc_out_info::in,
    item_avail::in, io::di, io::uo) is det.

mercury_output_item_avail(Info, Avail, !IO) :-
    (
        Avail = avail_import(avail_import_info(ModuleName, Context, _SeqNum)),
        Decl = "import_module"
    ;
        Avail = avail_use(avail_use_info(ModuleName, Context, _SeqNum)),
        Decl = "use_module"
    ),
    maybe_output_line_number(Info, Context, !IO),
    mercury_output_module_decl(Decl, ModuleName, !IO).

:- pred mercury_output_item_use(merc_out_info::in,
    avail_use_info::in, io::di, io::uo) is det.

mercury_output_item_use(Info, Use, !IO) :-
    Use = avail_use_info(ModuleName, Context, _SeqNum),
    Decl = "use_module",
    maybe_output_line_number(Info, Context, !IO),
    mercury_output_module_decl(Decl, ModuleName, !IO).

:- pred mercury_output_module_decl(string::in, module_name::in,
    io::di, io::uo) is det.

mercury_output_module_decl(Decl, ModuleName, !IO) :-
    io.write_string(":- ", !IO),
    io.write_string(Decl, !IO),
    io.write_string(" ", !IO),
    mercury_output_bracketed_sym_name(ModuleName, !IO),
    io.write_string(".\n", !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_items(merc_out_info::in, list(item)::in,
    io::di, io::uo) is det.

mercury_output_items(_, [], !IO).
mercury_output_items(Info, [Item | Items], !IO) :-
    mercury_output_item(Info, Item, !IO),
    mercury_output_items(Info, Items, !IO).

mercury_output_item(Info, Item, !IO) :-
    (
        Item = item_clause(ItemClause),
        mercury_output_item_clause(Info, ItemClause, !IO)
    ;
        Item = item_type_defn(ItemTypeDefn),
        mercury_output_item_type_defn(Info, ItemTypeDefn, !IO)
    ;
        Item = item_inst_defn(ItemInstDefn),
        mercury_output_item_inst_defn(Info, ItemInstDefn, !IO)
    ;
        Item = item_mode_defn(ItemModeDefn),
        mercury_output_item_mode_defn(Info, ItemModeDefn, !IO)
    ;
        Item = item_pred_decl(ItemPredDecl),
        mercury_output_item_pred_decl(Info, ItemPredDecl, !IO)
    ;
        Item = item_mode_decl(ItemModeDecl),
        mercury_output_item_mode_decl(Info, ItemModeDecl, !IO)
    ;
        Item = item_pragma(ItemPragma),
        mercury_output_item_pragma(Info, ItemPragma, !IO)
    ;
        Item = item_promise(ItemPromise),
        mercury_output_item_promise(Info, ItemPromise, !IO)
    ;
        Item = item_typeclass(ItemTypeClass),
        mercury_output_item_typeclass(Info, ItemTypeClass, !IO)
    ;
        Item = item_instance(ItemInstance),
        mercury_output_item_instance(Info, ItemInstance, !IO)
    ;
        Item = item_initialise(ItemInitialise),
        mercury_output_item_initialise(Info, ItemInitialise, !IO)
    ;
        Item = item_finalise(ItemFinalise),
        mercury_output_item_finalise(Info, ItemFinalise, !IO)
    ;
        Item = item_mutable(ItemMutable),
        mercury_output_item_mutable(Info, ItemMutable, !IO)
    ;
        Item = item_nothing(_ItemNothing)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_type_defn(merc_out_info::in,
    item_type_defn_info::in, io::di, io::uo) is det.

mercury_output_item_type_defn(Info, ItemTypeDefn, !IO) :-
    ItemTypeDefn = item_type_defn_info(SymName0, TypeParams, TypeDefn,
        TypeVarSet, Context, _SeqNum),
    maybe_unqualify_sym_name(Info, SymName0, SymName),
    maybe_output_line_number(Info, Context, !IO),
    Args = list.map((func(V) = term.variable(V, Context)), TypeParams),
    construct_qualified_term_with_context(SymName, Args, Context, TypeTerm),
    (
        TypeDefn = parse_tree_abstract_type(DetailsAbstract),
        (
            ( DetailsAbstract = abstract_type_general
            ; DetailsAbstract = abstract_enum_type(_)
            ),
            IsSolverType = non_solver_type
        ;
            DetailsAbstract = abstract_solver_type,
            IsSolverType = solver_type
        ),
        mercury_output_begin_type_decl(IsSolverType, !IO),
        mercury_output_term_nq(TypeVarSet, print_name_only,
            next_to_graphic_token, TypeTerm, !IO),
        (
            DetailsAbstract = abstract_enum_type(NumBits),
            mercury_output_where_abstract_enum_type(NumBits, !IO)
        ;
            DetailsAbstract = abstract_type_general
        ;
            DetailsAbstract = abstract_solver_type
        ),
        io.write_string(".\n", !IO)
    ;
        TypeDefn = parse_tree_eqv_type(DetailsEqv),
        DetailsEqv = type_details_eqv(EqvType),
        mercury_output_begin_type_decl(non_solver_type, !IO),
        mercury_output_term(TypeVarSet, print_name_only, TypeTerm, !IO),
        io.write_string(" == ", !IO),
        mercury_output_type(TypeVarSet, print_name_only, EqvType, !IO),
        io.write_string(".\n", !IO)
    ;
        TypeDefn = parse_tree_du_type(DetailsDu),
        DetailsDu = type_details_du(Ctors, MaybeUserEqComp, MaybeDirectArgs),
        mercury_output_begin_type_decl(non_solver_type, !IO),
        mercury_output_term(TypeVarSet, print_name_only, TypeTerm, !IO),
        mercury_output_ctors(TypeVarSet, yes, Ctors, !IO),
        mercury_output_where_attributes(Info, TypeVarSet, no, MaybeUserEqComp,
            MaybeDirectArgs, !IO),
        io.write_string(".\n", !IO)
    ;
        TypeDefn = parse_tree_solver_type(DetailsSolver),
        DetailsSolver =
            type_details_solver(SolverTypeDetails, MaybeUserEqComp),
        mercury_output_begin_type_decl(solver_type, !IO),
        mercury_output_term(TypeVarSet, print_name_only, TypeTerm, !IO),
        mercury_output_where_attributes(Info, TypeVarSet,
            yes(SolverTypeDetails), MaybeUserEqComp, no, !IO),
        io.write_string(".\n", !IO)
    ;
        TypeDefn = parse_tree_foreign_type(DetailsForeign),
        DetailsForeign = type_details_foreign(ForeignType, MaybeUserEqComp,
            foreign_type_assertions(Assertions)),
        io.write_string(":- pragma foreign_type(", !IO),
        (
            ForeignType = c(_),
            io.write_string("c, ", !IO)
        ;
            ForeignType = java(_),
            io.write_string("java, ", !IO)
        ;
            ForeignType = csharp(_),
            io.write_string("csharp, ", !IO)
        ;
            ForeignType = erlang(_),
            io.write_string("erlang, ", !IO)
        ),
        mercury_output_term(TypeVarSet, print_name_only, TypeTerm, !IO),
        io.write_string(", \"", !IO),
        (
            ForeignType = c(c_type(ForeignTypeStr))
        ;
            ForeignType = java(java_type(ForeignTypeStr))
        ;
            ForeignType = csharp(csharp_type(ForeignTypeStr))
        ;
            ForeignType = erlang(erlang_type),
            ForeignTypeStr = ""
        ),
        io.write_string(ForeignTypeStr, !IO),
        io.write_string("\"", !IO),
        set.to_sorted_list(Assertions, AssertionsList),
        (
            AssertionsList = []
        ;
            AssertionsList = [_ | _],
            io.write_string(", [", !IO),
            io.write_list(AssertionsList, ", ",
                mercury_output_foreign_type_assertion, !IO),
            io.write_string("]", !IO)
        ),
        io.write_string(")", !IO),
        mercury_output_where_attributes(Info, TypeVarSet, no, MaybeUserEqComp,
            no, !IO),
        io.write_string(".\n", !IO)
    ).

%---------------------%
%
% Predicates needed to output more than one kind of type.
%

:- pred mercury_output_begin_type_decl(is_solver_type::in,
    io::di, io::uo) is det.

mercury_output_begin_type_decl(IsSolverType, !IO) :-
    (
        IsSolverType = solver_type,
        io.write_string(":- solver type ", !IO)
    ;
        IsSolverType = non_solver_type,
        io.write_string(":- type ", !IO)
    ).

mercury_output_where_attributes(Info, TypeVarSet,
        MaybeSolverTypeDetails, MaybeUserEqComp, MaybeDirectArgs, !IO) :-
    ( if
        MaybeSolverTypeDetails = no,
        MaybeUserEqComp        = no,
        MaybeDirectArgs        = no
    then
        true
    else
        ( if
            MaybeUserEqComp = yes(UserEqComp),
            UserEqComp = unify_compare(MaybeUnifyPred0, MaybeComparePred0)
        then
            MaybeUnifyPred   = MaybeUnifyPred0,
            MaybeComparePred = MaybeComparePred0
        else
            MaybeUnifyPred   = no,
            MaybeComparePred = no
        ),
        io.write_string("\n\twhere\t", !IO),
        ( if MaybeUserEqComp = yes(abstract_noncanonical_type(_)) then
            io.write_string("type_is_abstract_noncanonical", !IO)
        else
            (
                MaybeSolverTypeDetails = yes(SolverTypeDetails),
                mercury_output_solver_type_details(Info, TypeVarSet,
                    SolverTypeDetails, !IO),
                ( if
                    (   MaybeUnifyPred = yes(_)
                    ;   MaybeComparePred = yes(_)
                    )
                then
                    io.write_string(",\n\t\t", !IO)
                else
                    true
                )
            ;
                MaybeSolverTypeDetails = no
            )
        ),
        (
            MaybeUnifyPred = yes(UnifyPredName),
            io.write_string("equality is ", !IO),
            mercury_output_bracketed_sym_name(UnifyPredName, !IO),
            (
                MaybeComparePred = yes(_),
                io.write_string(",\n\t\t", !IO)
            ;
                MaybeComparePred = no
            )
        ;
            MaybeUnifyPred = no
        ),
        (
            MaybeComparePred = yes(ComparePredName),
            io.write_string("comparison is ", !IO),
            mercury_output_bracketed_sym_name(ComparePredName, !IO),
            (
                MaybeDirectArgs = yes(_),
                io.write_string(",\n\t\t", !IO)
            ;
                MaybeDirectArgs = no
            )
        ;
            MaybeComparePred = no
        ),
        (
            MaybeDirectArgs = yes(DirectArgFunctors),
            io.write_string("direct_arg is [", !IO),
            mercury_output_direct_arg_functors(DirectArgFunctors, !IO),
            io.write_string("]", !IO)
        ;
            MaybeDirectArgs = no
        )
    ).

:- pred mercury_output_solver_type_details(merc_out_info::in, tvarset::in,
    solver_type_details::in, io::di, io::uo) is det.

mercury_output_solver_type_details(Info, TypeVarSet, Details, !IO) :-
    Details = solver_type_details(RepresentationType, GroundInst,
        AnyInst, MutableInfos),
    io.write_string("representation is ", !IO),
    mercury_output_type(TypeVarSet, print_name_only, RepresentationType, !IO),
    Lang = get_output_lang(Info),
    varset.init(EmptyInstVarSet),
    io.write_string(",\n\t\tground is ", !IO),
    mercury_output_inst(Lang, EmptyInstVarSet, GroundInst, !IO),
    io.write_string(",\n\t\tany is ", !IO),
    mercury_output_inst(Lang, EmptyInstVarSet, AnyInst, !IO),
    (
        MutableInfos = []
    ;
        MutableInfos = [_ | _],
        io.write_string(",\n\t\tconstraint_store is [\n\t\t\t", !IO),
        io.write_list(MutableInfos, ",\n\t\t\t",
            mercury_output_item_mutable(Info), !IO),
        io.write_string("\n\t\t]", !IO)
    ).

%---------------------%
%
% Predicates needed to output abstract types.
%

:- pred mercury_output_where_abstract_enum_type(int::in, io::di, io::uo)
    is det.

mercury_output_where_abstract_enum_type(NumBits, !IO) :-
    io.write_string("\n\twhere\t", !IO),
    io.write_string("type_is_abstract_enum(", !IO),
    io.write_int(NumBits, !IO),
    io.write_string(")", !IO).

%---------------------%
%
% Predicates needed to output discriminated union types.
%

:- pred mercury_output_ctors(tvarset::in, bool::in, list(constructor)::in,
    io::di, io::uo) is det.

mercury_output_ctors(_, _, [], !IO).
mercury_output_ctors(VarSet, First, [Ctor | Ctors], !IO) :-
    (
        First = yes,
        io.write_string("\n    --->    ", !IO)
    ;
        First = no,
        io.write_string("\n    ;       ", !IO)
    ),
    mercury_output_ctor(VarSet, Ctor, !IO),
    mercury_output_ctors(VarSet, no, Ctors, !IO).

mercury_output_ctor(TypeVarSet, Ctor, !IO) :-
    Ctor = ctor(ExistQVars, Constraints, SymName, Args, Arity, _Ctxt),

    % We will have attached the module name to the type definition,
    % so there is no point adding it to the constructor as well.
    Name = unqualify_name(SymName),
    mercury_output_quantifier(TypeVarSet, print_name_only, ExistQVars, !IO),
    (
        ExistQVars = [],
        ParenWrap = no
    ;
        ExistQVars = [_ | _],
        ParenWrap = yes,
        io.write_string("(", !IO)
    ),
    % We need to quote ';'/2, '{}'/2, '=>'/2, and 'some'/2.
    % XXX I (zs) think that we should not allow these as constructor names.
    ( if
        Arity = 2,
        ( Name = ";"
        ; Name = "{}"
        ; Name = "some"
        ; Name = "=>"
        )
    then
        BraceWrap = yes,
        io.write_string("{ ", !IO)
    else
        BraceWrap = no
    ),
    (
        Args = [Arg | Rest],
        mercury_output_sym_name(unqualified(Name), !IO),
        io.write_string("(", !IO),
        mercury_output_ctor_arg(TypeVarSet, Arg, !IO),
        mercury_output_remaining_ctor_args(TypeVarSet, Rest, !IO),
        io.write_string(")", !IO)
    ;
        Args = [],
        mercury_output_bracketed_sym_name(unqualified(Name), !IO),
        % This space prevents a terminating full stop from being confused
        % as part of the sym_name if the sym_name contains graphical
        % characters.
        io.write_string(" ", !IO)
    ),
    (
        BraceWrap = yes,
        io.write_string(" }", !IO)
    ;
        BraceWrap = no
    ),
    mercury_format_prog_constraint_list(TypeVarSet, print_name_only, "=>",
        Constraints, !IO),
    (
        ParenWrap = no
    ;
        ParenWrap = yes,
        io.write_string(")", !IO)
    ).

:- pred mercury_output_ctor_arg(tvarset::in, constructor_arg::in,
    io::di, io::uo) is det.

mercury_output_ctor_arg(TVarSet, Arg, !IO) :-
    Arg = ctor_arg(Name, Type, _Width, _Context),
    mercury_output_ctor_arg_name_prefix(Name, !IO),
    mercury_output_type(TVarSet, print_name_only, Type, !IO).

:- pred mercury_output_remaining_ctor_args(tvarset::in,
    list(constructor_arg)::in, io::di, io::uo) is det.

mercury_output_remaining_ctor_args(_TVarSet, [], !IO).
mercury_output_remaining_ctor_args(TVarSet, [Arg | Args], !IO) :-
    io.write_string(", ", !IO),
    mercury_output_ctor_arg(TVarSet, Arg, !IO),
    mercury_output_remaining_ctor_args(TVarSet, Args, !IO).

:- pred mercury_output_ctor_arg_name_prefix(maybe(ctor_field_name)::in,
    io::di, io::uo) is det.

mercury_output_ctor_arg_name_prefix(no, !IO).
mercury_output_ctor_arg_name_prefix(yes(FieldName), !IO) :-
    FieldName = ctor_field_name(Name, _Ctxt),
    mercury_output_bracketed_sym_name(Name, !IO),
    io.write_string(" :: ", !IO).

:- pred mercury_output_direct_arg_functors(list(sym_name_and_arity)::in,
    io::di, io::uo) is det.

mercury_output_direct_arg_functors(Ctors, !IO) :-
    io.write_list(Ctors, ", ", mercury_format_sym_name_and_arity, !IO).

%---------------------%
%
% Predicates needed to output foreign types.
%

:- pred mercury_output_foreign_type_assertion(foreign_type_assertion::in,
    io::di, io::uo) is det.

mercury_output_foreign_type_assertion(Assertion, !IO) :-
    (
        Assertion = foreign_type_can_pass_as_mercury_type,
        io.write_string("can_pass_as_mercury_type", !IO)
    ;
        Assertion = foreign_type_stable,
        io.write_string("stable", !IO)
    ;
        Assertion = foreign_type_word_aligned_pointer,
        io.write_string("word_aligned_pointer", !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_inst_defn(merc_out_info::in,
    item_inst_defn_info::in, io::di, io::uo) is det.

mercury_output_item_inst_defn(Info, ItemInstDefn, !IO) :-
    ItemInstDefn = item_inst_defn_info(SymName0, InstParams, MaybeForTypeCtor,
        InstDefn, InstVarSet, Context, _SeqNum),
    % If the unqualified name is a builtin inst, then output the qualified
    % name. This prevents the compiler giving an error about redefining
    % builtin insts when an interface file is read back in.
    maybe_unqualify_sym_name(Info, SymName0, UnQualSymName),
    ( if is_builtin_inst_name(InstVarSet, UnQualSymName, InstParams) then
        SymName = SymName0
    else
        SymName = UnQualSymName
    ),
    maybe_output_line_number(Info, Context, !IO),
    Lang = get_output_lang(Info),
    (
        InstDefn = abstract_inst,
        io.write_string(":- inst (", !IO),
        ArgTerms = list.map(func(V) = variable(V, Context), InstParams),
        construct_qualified_term_with_context(SymName, ArgTerms, Context,
            InstTerm),
        mercury_output_term(InstVarSet, print_name_only, InstTerm, !IO),
        io.write_string(").\n", !IO)
    ;
        InstDefn = eqv_inst(Body),
        io.write_string(":- inst (", !IO),
        ArgTerms = list.map(func(V) = variable(V, Context), InstParams),
        construct_qualified_term_with_context(SymName, ArgTerms, Context,
            InstTerm),
        mercury_output_term(InstVarSet, print_name_only, InstTerm, !IO),
        io.write_string(") ", !IO),
        (
            MaybeForTypeCtor = no
        ;
            MaybeForTypeCtor = yes(ForTypeCtor),
            ForTypeCtor = type_ctor(ForTypeCtorSymName, ForTypeCtorArity),
            io.write_string("for ", !IO),
            mercury_output_sym_name(ForTypeCtorSymName, !IO),
            io.write_string("/", !IO),
            io.write_int(ForTypeCtorArity, !IO),
            io.write_string(" ", !IO)
        ),
        io.write_string("== ", !IO),
        mercury_output_inst(Lang, InstVarSet, Body, !IO),
        io.write_string(".\n", !IO)
    ).

    % Succeed if the sym_name describes a builtin inst.
    %
:- pred is_builtin_inst_name(inst_varset::in, sym_name::in, list(inst_var)::in)
    is semidet.

is_builtin_inst_name(InstVarSet, unqualified(Name), Args0) :-
    Args1 = list.map(func(V) = variable(coerce_var(V), context_init), Args0),
    Term = term.functor(term.atom(Name), Args1, term.context_init),
    varset.coerce(InstVarSet, VarSet),
    ContextPieces = cord.init,  % Dummy; not used.
    parse_inst(no_allow_constrained_inst_var(wnciv_inst_defn_lhs), VarSet,
        ContextPieces, Term, MaybeInst),
    MaybeInst = ok1(Inst),
    Inst \= defined_inst(user_inst(_, _)).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_mode_defn(merc_out_info::in,
    item_mode_defn_info::in, io::di, io::uo) is det.

mercury_output_item_mode_defn(Info, ItemModeDefn, !IO) :-
    ItemModeDefn = item_mode_defn_info(SymName, InstParams, ModeDefn, VarSet,
        Context, _SeqNum),
    maybe_unqualify_sym_name(Info, SymName, UnQualSymName),
    maybe_output_line_number(Info, Context, !IO),
    Lang = get_output_lang(Info),
    mercury_format_mode_defn(Lang, VarSet, UnQualSymName, InstParams,
        ModeDefn, Context, !IO).

    % This is defined to work on !U instead of !IO so that we can call
    % mercury_format_mode with simple_inst_info. The mercury_output_mode
    % predicate is NOT polymorphic in its second argument.
    %
:- pred mercury_format_mode_defn(output_lang::in, inst_varset::in,
    sym_name::in, list(inst_var)::in, mode_defn::in, prog_context::in,
    U::di, U::uo) is det <= output(U).

mercury_format_mode_defn(Lang, InstVarSet, Name, Args, eqv_mode(Mode), Context,
        !U) :-
    add_string(":- mode (", !U),
    ArgTerms = list.map(func(V) = variable(V, Context), Args),
    construct_qualified_term_with_context(Name, ArgTerms, Context, ModeTerm),
    mercury_format_term(InstVarSet, print_name_only, ModeTerm, !U),
    add_string(") == ", !U),
    mercury_format_mode(Lang, InstVarSet, Mode, !U),
    add_string(".\n", !U).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_pred_decl(merc_out_info::in,
    item_pred_decl_info::in, io::di, io::uo) is det.

mercury_output_item_pred_decl(Info, ItemPredDecl, !IO) :-
    % Most of the code that outputs pred declarations is in
    % parse_tree_out_pred_decl.m.
    ItemPredDecl = item_pred_decl_info(PredName0, PredOrFunc, TypesAndModes,
        WithType, WithInst, MaybeDetism, _Origin, TypeVarSet, InstVarSet,
        ExistQVars, Purity, Constraints, Context, _SeqNum),
    maybe_unqualify_sym_name(Info, PredName0, PredName),
    maybe_output_line_number(Info, Context, !IO),
    Lang = get_output_lang(Info),
    ( if
        % Function declarations using `with_type` have the same format
        % as predicate declarations, but with `func' instead of `pred'.
        PredOrFunc = pf_function,
        WithType = no
    then
        pred_args_to_func_args(TypesAndModes, FuncTypesAndModes,
            RetTypeAndMode),
        mercury_format_func_decl(Lang, TypeVarSet, InstVarSet,
            ExistQVars, PredName, FuncTypesAndModes, RetTypeAndMode,
            MaybeDetism, Purity, Constraints,
            ":- ", ".\n", ".\n", !IO)
    else
        mercury_format_pred_or_func_decl(Lang, TypeVarSet, InstVarSet,
            PredOrFunc, ExistQVars, PredName, TypesAndModes,
            WithType, WithInst, MaybeDetism, Purity, Constraints,
            ":- ", ".\n", ".\n", !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_mode_decl(merc_out_info::in,
    item_mode_decl_info::in, io::di, io::uo) is det.

mercury_output_item_mode_decl(Info, ItemModeDecl, !IO) :-
    % Most of the code that outputs mode declarations is in
    % parse_tree_out_pred_decl.m.
    ItemModeDecl = item_mode_decl_info(PredName0, PredOrFunc, Modes,
        WithInst, MaybeDet, VarSet, Context, _SeqNum),
    maybe_unqualify_sym_name(Info, PredName0, PredName),
    maybe_output_line_number(Info, Context, !IO),
    Lang = get_output_lang(Info),
    ( if
        % Function mode declarations using `with_type` have the same format
        % as predicate mode declarations.
        PredOrFunc = yes(pf_function),
        WithInst = no
    then
        pred_args_to_func_args(Modes, FuncModes, RetMode),
        mercury_output_func_mode_decl(Lang, VarSet, PredName,
            FuncModes, RetMode, MaybeDet, !IO)
    else
        mercury_output_pred_mode_decl(Lang, VarSet, PredName,
            Modes, WithInst, MaybeDet, !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_promise(merc_out_info::in, item_promise_info::in,
    io::di, io::uo) is det.

mercury_output_item_promise(_, ItemPromise, !IO) :-
    ItemPromise = item_promise_info(PromiseType, Goal0, VarSet, UnivVars,
        _Context, _SeqNum),
    Indent = 1,
    (
        PromiseType = promise_type_true,
        % For an assertion, we put back any universally quantified variables
        % that were stripped off during parsing so that the clause will
        % output correctly.
        io.write_string(":- promise ", !IO),
        (
            UnivVars = [_ | _],
            Goal = quant_expr(quant_all, quant_ordinary_vars,
                goal_get_context(Goal0), UnivVars, Goal0)
        ;
            UnivVars = [],
            Goal = Goal0
        )
    ;
        ( PromiseType = promise_type_exclusive
        ; PromiseType = promise_type_exhaustive
        ; PromiseType = promise_type_exclusive_exhaustive
        ),
        % A promise ex declaration has a slightly different standard formatting
        % from an assertion; the universal quantification comes before the rest
        % of the declaration.
        io.write_string(":- all [", !IO),
        VarNamePrint = print_name_only,
        mercury_output_vars(VarSet, VarNamePrint, UnivVars, !IO),
        io.write_string("]", !IO),
        mercury_output_newline(Indent, !IO),
        prog_out.write_promise_type(PromiseType, !IO),
        Goal0 = Goal
    ),
    mercury_output_newline(Indent, !IO),
    mercury_output_goal(VarSet, Indent, Goal, !IO),
    io.write_string(".\n", !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_typeclass(merc_out_info::in,
    item_typeclass_info::in, io::di, io::uo) is det.

mercury_output_item_typeclass(Info, ItemTypeClass, !IO) :-
    ItemTypeClass = item_typeclass_info(ClassName0, Vars, Constraints, FunDeps,
        Interface, VarSet, _Context, _SeqNum),
    maybe_unqualify_sym_name(Info, ClassName0, ClassName),
    io.write_string(":- typeclass ", !IO),

    % We put an extra set of brackets around the class name in
    % case the name is an operator.
    mercury_output_sym_name(ClassName, !IO),
    io.write_char('(', !IO),
    io.write_list(Vars, ", ",
        ( pred(V::in, IO0::di, IO::uo) is det :-
            varset.lookup_name(VarSet, V, VarName),
            io.write_string(VarName, IO0, IO)
        ), !IO),
    io.write_char(')', !IO),
    mercury_format_fundeps_and_prog_constraint_list(VarSet, print_name_only,
        FunDeps, Constraints, !IO),
    (
        Interface = class_interface_abstract,
        io.write_string(".\n", !IO)
    ;
        Interface = class_interface_concrete(Methods),
        io.write_string(" where [\n", !IO),
        Lang = get_output_lang(Info),
        output_class_methods(Lang, Methods, !IO),
        io.write_string("\n].\n", !IO)
    ).

:- pred mercury_format_fundeps_and_prog_constraint_list(tvarset::in,
    var_name_print::in, list(prog_fundep)::in, list(prog_constraint)::in,
    U::di, U::uo) is det
    <= output(U).

mercury_format_fundeps_and_prog_constraint_list(VarSet, VarNamePrint,
        FunDeps, Constraints, !U) :-
    ( if
        FunDeps = [],
        Constraints = []
    then
        true
    else
        add_string(" <= (", !U),
        add_list(FunDeps, ", ",
            mercury_format_fundep(VarSet, VarNamePrint), !U),
        (
            Constraints = []
        ;
            Constraints = [_ | _],
            (
                FunDeps = []
            ;
                FunDeps = [_ | _],
                add_string(", ", !U)
            ),
            add_list(Constraints, ", ",
                mercury_format_constraint(VarSet, VarNamePrint), !U)
        ),
        add_string(")", !U)
    ).

:- pred mercury_format_fundep(tvarset::in, var_name_print::in, prog_fundep::in,
    U::di, U::uo) is det <= output(U).

mercury_format_fundep(TypeVarSet, VarNamePrint, fundep(Domain, Range), !U) :-
    add_string("(", !U),
    add_list(Domain, ", ", mercury_format_var(TypeVarSet, VarNamePrint), !U),
    add_string(" -> ", !U),
    add_list(Range, ", ", mercury_format_var(TypeVarSet, VarNamePrint), !U),
    add_string(")", !U).

:- pred output_class_methods(output_lang::in, list(class_method)::in,
    io::di, io::uo) is det.

output_class_methods(Lang, Methods, !IO) :-
    io.write_list(Methods, ",\n", output_class_method(Lang), !IO).

:- pred output_class_method(output_lang::in, class_method::in,
    io::di, io::uo) is det.

output_class_method(Lang, Method, !IO) :-
    io.write_string("\t", !IO),
    (
        Method = method_pred_or_func(SymName, PredOrFunc, TypesAndModes,
            WithType, WithInst, MaybeDetism, TypeVarSet, InstVarSet,
            ExistQVars, Purity, ClassContext, _Context),

        % The module name is implied by the qualifier of the
        % `:- typeclass declaration'.
        Name = unqualify_name(SymName),
        ( if
            % Function declarations using `with_type` have the same format
            % as predicate declarations, but with `func' instead of `pred'.
            PredOrFunc = pf_function,
            WithType = no
        then
            pred_args_to_func_args(TypesAndModes,
                FuncTypesAndModes, RetTypeAndMode),
            mercury_format_func_decl(Lang, TypeVarSet, InstVarSet, ExistQVars,
                unqualified(Name), FuncTypesAndModes, RetTypeAndMode,
                MaybeDetism, Purity, ClassContext, "", ",\n\t", "", !IO)
        else
            mercury_format_pred_or_func_decl(Lang, TypeVarSet, InstVarSet,
                PredOrFunc, ExistQVars, unqualified(Name), TypesAndModes,
                WithType, WithInst, MaybeDetism, Purity,
                ClassContext, "", ",\n\t", "", !IO)
        )
    ;
        Method = method_pred_or_func_mode(SymName, PredOrFunc, Modes,
            WithInst, MaybeDetism, InstVarSet, _Context),

        % The module name is implied by the qualifier of the
        % `:- typeclass declaration'.
        Name = unqualify_name(SymName),
        ( if
            % Function mode declarations using `with_type` have the same format
            % as predicate mode declarations.
            PredOrFunc = yes(pf_function),
            WithInst = no
        then
            pred_args_to_func_args(Modes, FuncModes, RetMode),
            mercury_format_func_mode_decl(Lang, InstVarSet,
                unqualified(Name), FuncModes, RetMode, MaybeDetism,
                "", "", !IO)
        else
            mercury_format_pred_or_func_mode_decl(Lang, InstVarSet,
                unqualified(Name), Modes, WithInst, MaybeDetism,
                "", "", !IO)
        )
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_instance(merc_out_info::in, item_instance_info::in,
    io::di, io::uo) is det.

mercury_output_item_instance(_, ItemInstance, !IO) :-
    % XXX When prettyprinting a Mercury module, we want to print the original
    % types. When generating interface types, we want to print the
    % equiv-type-expanded types. We do the latter.
    ItemInstance = item_instance_info(ClassName,Types, _OriginalTypes,
        Constraints, Body, VarSet, _InstanceModuleName, _Context, _SeqNum),
    io.write_string(":- instance ", !IO),
    % We put an extra set of brackets around the class name in case
    % the name is an operator.
    io.write_char('(', !IO),
    mercury_output_sym_name(ClassName, !IO),
    io.write_char('(', !IO),
    io.write_list(Types, ", ",
        mercury_output_type(VarSet, print_name_only), !IO),
    io.write_char(')', !IO),
    io.write_char(')', !IO),
    mercury_format_prog_constraint_list(VarSet, print_name_only, "<=",
        Constraints, !IO),
    (
        Body = instance_body_abstract
    ;
        Body = instance_body_concrete(Methods),
        io.write_string(" where [\n", !IO),
        mercury_output_instance_methods(Methods, !IO),
        io.write_string("\n]", !IO)
    ),
    io.write_string(".\n", !IO).

:- pred mercury_output_instance_methods(list(instance_method)::in,
    io::di, io::uo) is det.

mercury_output_instance_methods(Methods, !IO) :-
    io.write_list(Methods, ",\n", mercury_output_instance_method, !IO).

mercury_output_instance_method(Method, !IO) :-
    Method = instance_method(PredOrFunc, MethodName, Defn, Arity, _Context),
    (
        Defn = instance_proc_def_name(PredName),
        io.write_char('\t', !IO),
        (
            PredOrFunc = pf_function,
            io.write_string("func(", !IO)
        ;
            PredOrFunc = pf_predicate,
            io.write_string("pred(", !IO)
        ),
        mercury_output_bracketed_sym_name_ngt(next_to_graphic_token,
            MethodName, !IO),
        io.write_string("/", !IO),
        io.write_int(Arity, !IO),
        io.write_string(") is ", !IO),
        mercury_output_bracketed_sym_name(PredName, !IO)
    ;
        Defn = instance_proc_def_clauses(Items),
        % XXX should we output the term contexts?
        io.write_string("\t(", !IO),
        io.write_list(Items, "),\n\t(",
            output_instance_method_clause(MethodName), !IO),
        io.write_string(")", !IO)
    ).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_initialise(merc_out_info::in,
    item_initialise_info::in, io::di, io::uo) is det.

mercury_output_item_initialise(_, ItemInitialise, !IO) :-
    ItemInitialise = item_initialise_info(PredSymName, Arity, _, _Context,
        _SeqNum),
    io.write_string(":- initialise ", !IO),
    mercury_output_sym_name(PredSymName, !IO),
    io.write_string("/", !IO),
    io.write_int(Arity, !IO),
    io.write_string(".\n", !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_finalise(merc_out_info::in, item_finalise_info::in,
    io::di, io::uo) is det.

mercury_output_item_finalise(_, ItemFinalise, !IO) :-
    ItemFinalise = item_finalise_info(PredSymName, Arity, _, _Context,
        _SeqNum),
    io.write_string(":- finalise ", !IO),
    mercury_output_sym_name(PredSymName, !IO),
    io.write_string("/", !IO),
    io.write_int(Arity, !IO),
    io.write_string(".\n", !IO).

%---------------------------------------------------------------------------%

:- pred mercury_output_item_mutable(merc_out_info::in, item_mutable_info::in,
    io::di, io::uo) is det.

mercury_output_item_mutable(Info, ItemMutable, !IO) :-
    ItemMutable = item_mutable_info(Name, _OrigType, Type, _OrigInst, Inst,
        InitTerm, MutVarSet, Attrs, _Context, _SeqNum),
    io.write_string(":- mutable(", !IO),
    io.write_string(Name, !IO),
    io.write_string(", ", !IO),
    mercury_output_type(varset.init, print_name_only, Type, !IO),
    io.write_string(", ", !IO),

    % See the comments for read_mutable_decl for the reason we _must_ use
    % MutVarSet here.
    mercury_output_term(MutVarSet, print_name_only, InitTerm, !IO),
    io.write_string(", ", !IO),
    Lang = get_output_lang(Info),
    mercury_output_inst(Lang, varset.init, Inst, !IO),
    io.write_string(", ", !IO),
    io.print(Attrs, !IO),
    io.write_string(").\n", !IO).

%---------------------------------------------------------------------------%
:- end_module parse_tree.parse_tree_out.
%---------------------------------------------------------------------------%
