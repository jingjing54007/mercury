/*
** vim: ts=4 sw=4 expandtab
*/
/*
** Copyright (C) 1996-2005 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

#include    "mercury_imp.h"
#include    "mercury_dlist.h"
#include    "mercury_regs.h"
#include    "mercury_trace_base.h"
#include    "mercury_label.h"
#include    "mercury_debug.h"

#include    <stdio.h>
#include    <stdarg.h>

#ifdef  MR_USE_MINIMAL_MODEL_OWN_STACKS
  #define   MR_in_ctxt_det_zone(ptr, ctxt)          \
                MR_in_zone(ptr, ctxt->MR_ctxt_detstack_zone)
  #define   MR_in_ctxt_non_zone(ptr, ctxt)          \
                MR_in_zone(ptr, ctxt->MR_ctxt_nondetstack_zone)

  extern  const MR_Context  *MR_find_ctxt_for_det_ptr(const MR_Word *ptr);
  extern  const MR_Context  *MR_find_ctxt_for_non_ptr(const MR_Word *ptr);

  extern  MR_MemoryZone     *MR_find_zone_for_det_ptr(const MR_Word *ptr);
  extern  MR_MemoryZone     *MR_find_zone_for_non_ptr(const MR_Word *ptr);

  extern  MR_Generator      *MR_find_gen_for_det_ptr(const MR_Word *ptr);
  extern  MR_Generator      *MR_find_gen_for_non_ptr(const MR_Word *ptr);

  #define MR_det_zone(fr)   (MR_find_zone_for_det_ptr(fr))
  #define MR_non_zone(fr)   (MR_find_zone_for_non_ptr(fr))
#else
  #define MR_det_zone(fr)   (MR_CONTEXT(MR_ctxt_detstack_zone))
  #define MR_non_zone(fr)   (MR_CONTEXT(MR_ctxt_nondetstack_zone))
#endif

#define MR_det_stack_min(fr)    (MR_det_zone(fr)->MR_zone_min)
#define MR_det_stack_offset(fr) (fr - MR_det_stack_min(fr))
#define MR_non_stack_min(fr)    (MR_non_zone(fr)->MR_zone_min)
#define MR_non_stack_offset(fr) (fr - MR_non_stack_min(fr))

/*--------------------------------------------------------------------*/

#ifdef  MR_DEEP_PROFILING
static void     MR_check_watch_csd_start(MR_Code *proc);
static MR_bool  MR_csds_are_different(MR_CallSiteDynamic *csd1,
                    MR_CallSiteDynamic *csd2);
static void     MR_assign_csd(MR_CallSiteDynamic *csd1,
                    MR_CallSiteDynamic *csd2);
#endif

static void     MR_count_call(MR_Code *proc);
static void     MR_print_ordinary_regs(void);
static void     MR_do_watches(void);
static MR_bool  MR_proc_matches_name(MR_Code *proc, const char *name);

#ifdef  MR_LOWLEVEL_ADDR_DEBUG
  #define   MR_PRINT_RAW_ADDRS  MR_TRUE
#else
  #define   MR_PRINT_RAW_ADDRS  MR_FALSE
#endif

static  MR_bool MR_print_raw_addrs = MR_PRINT_RAW_ADDRS;

/* auxiliary routines for the code that prints debugging messages */

#ifdef  MR_USE_MINIMAL_MODEL_OWN_STACKS

const MR_Context *
MR_find_ctxt_for_det_ptr(const MR_Word *ptr)
{
    const MR_Dlist      *item;
    const MR_Context    *ctxt;

    if (MR_in_ctxt_det_zone(ptr, MR_ENGINE(MR_eng_main_context))) {
        return MR_ENGINE(MR_eng_main_context);
    }

    MR_for_dlist(item, MR_ENGINE(MR_eng_gen_contexts)) {
        ctxt = (MR_Context *) MR_dlist_data(item);
        if (MR_in_ctxt_det_zone(ptr, ctxt)) {
            return ctxt;
        }
    }

    return NULL;
}

const MR_Context *
MR_find_ctxt_for_non_ptr(const MR_Word *ptr)
{
    const MR_Dlist      *item;
    const MR_Context    *ctxt;

    if (MR_in_ctxt_non_zone(ptr, MR_ENGINE(MR_eng_main_context))) {
        return MR_ENGINE(MR_eng_main_context);
    }

    MR_for_dlist(item, MR_ENGINE(MR_eng_gen_contexts)) {
        ctxt = (MR_Context *) MR_dlist_data(item);
        if (MR_in_ctxt_non_zone(ptr, ctxt)) {
            return ctxt;
        }
    }

    return NULL;
}

MR_MemoryZone *
MR_find_zone_for_det_ptr(const MR_Word *ptr)
{
    const MR_Context    *ctxt;

    ctxt = MR_find_ctxt_for_det_ptr(ptr);
    if (ctxt != NULL) {
        return ctxt->MR_ctxt_detstack_zone;
    }

    MR_fatal_error("MR_find_zone_for_det_ptr: not in any context");
}

MR_MemoryZone *
MR_find_zone_for_non_ptr(const MR_Word *ptr)
{
    const MR_Context    *ctxt;

    ctxt = MR_find_ctxt_for_non_ptr(ptr);
    if (ctxt != NULL) {
        return ctxt->MR_ctxt_nondetstack_zone;
    }

    MR_fatal_error("MR_find_zone_for_non_ptr: not in any context");
}

MR_Generator *
MR_find_gen_for_det_ptr(const MR_Word *ptr)
{
    const MR_Context    *ctxt;

    ctxt = MR_find_ctxt_for_det_ptr(ptr);
    if (ctxt != NULL) {
        return ctxt->MR_ctxt_owner_generator;
    }

    MR_fatal_error("MR_find_gen_for_det_ptr: not in any context");
}

MR_Generator *
MR_find_gen_for_non_ptr(const MR_Word *ptr)
{
    const MR_Context    *ctxt;

    ctxt = MR_find_ctxt_for_non_ptr(ptr);
    if (ctxt != NULL) {
        return ctxt->MR_ctxt_owner_generator;
    }

    MR_fatal_error("MR_find_gen_for_non_ptr: not in any context");
}

#endif  /* MR_USE_MINIMAL_MODEL_OWN_STACKS */

/* debugging messages */

#ifdef MR_DEBUG_HEAP_ALLOC

void
MR_unravel_univ_msg(MR_Word univ, MR_TypeInfo type_info, MR_Word value)
{
    if (MR_lld_print_enabled && MR_heapdebug) {
        printf("unravel univ %p: typeinfo %p, value %p\n",
            (void *) univ, (void *) type_info, (void *) value);
        fflush(stdout);
    }
}

void
MR_new_univ_on_hp_msg(MR_Word univ, MR_TypeInfo type_info, MR_Word value)
{
    if (MR_lld_print_enabled && MR_heapdebug) {
        printf("new univ on hp: typeinfo %p, value %p => %p\n",
            (void *) type_info, (void *) value, (void *) univ);
        fflush(stdout);
    }
}

void
MR_debug_tag_offset_incr_hp_base_msg(MR_Word ptr, int tag, int offset,
    int count, int is_atomic)
{
    if (MR_lld_print_enabled && MR_heapdebug) {
        printf("tag_offset_incr_hp: "
            "tag %d, offset %d, count %d%s => %p\n",
            tag, offset, count, (is_atomic ? ", atomic" : ""), (void *) ptr);
        fflush(stdout);
    }
}

#endif /* MR_DEBUG_HEAP_ALLOC */

#ifdef MR_LOWLEVEL_DEBUG

void 
MR_mkframe_msg(const char *predname)
{
    MR_restore_transient_registers();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nnew choice point for procedure %s\n", predname);
    printf("new  fr: "); MR_printnondstack(MR_curfr);
    printf("prev fr: "); MR_printnondstack(MR_prevfr_slot(MR_curfr));
    printf("succ fr: "); MR_printnondstack(MR_succfr_slot(MR_curfr));
    printf("succ ip: "); MR_printlabel(stdout, MR_succip_slot(MR_curfr));
    printf("redo fr: "); MR_printnondstack(MR_redofr_slot(MR_curfr));
    printf("redo ip: "); MR_printlabel(stdout, MR_redoip_slot(MR_curfr));
#ifdef  MR_USE_MINIMAL_MODEL_OWN_STACKS
    printf("det fr:  "); MR_printdetstack(MR_table_detfr_slot(MR_curfr));
#endif

    if (MR_detaildebug) {
        MR_dumpnondstack();
    }
}

void 
MR_mktempframe_msg(void)
{
    MR_restore_transient_registers();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nnew temp nondet frame\n");
    printf("new  fr: "); MR_printnondstack(MR_maxfr);
    printf("prev fr: "); MR_printnondstack(MR_prevfr_slot(MR_maxfr));
    printf("redo fr: "); MR_printnondstack(MR_redofr_slot(MR_maxfr));
    printf("redo ip: "); MR_printlabel(stdout, MR_redoip_slot(MR_maxfr));

    if (MR_detaildebug) {
        MR_dumpnondstack();
    }
}

void 
MR_mkdettempframe_msg(void)
{
    MR_restore_transient_registers();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nnew det temp nondet frame\n");
    printf("new  fr: "); MR_printnondstack(MR_maxfr);
    printf("prev fr: "); MR_printnondstack(MR_prevfr_slot(MR_maxfr));
    printf("redo fr: "); MR_printnondstack(MR_redofr_slot(MR_maxfr));
    printf("redo ip: "); MR_printlabel(stdout, MR_redoip_slot(MR_maxfr));
    printf("det fr:  "); MR_printdetstack(MR_tmp_detfr_slot(MR_maxfr));

    if (MR_detaildebug) {
        MR_dumpnondstack();
    }
}

void 
MR_succeed_msg(void)
{
    MR_restore_transient_registers();

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nsucceeding from procedure\n");
    printf("curr fr: "); MR_printnondstack(MR_curfr);
    printf("succ fr: "); MR_printnondstack(MR_succfr_slot(MR_curfr));
    printf("succ ip: "); MR_printlabel(stdout, MR_succip_slot(MR_curfr));

    if (MR_detaildebug) {
        MR_printregs("registers at success");
    }
}

void 
MR_succeeddiscard_msg(void)
{
    MR_restore_transient_registers();

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nsucceeding from procedure\n");
    printf("curr fr: "); MR_printnondstack(MR_curfr);
    printf("succ fr: "); MR_printnondstack(MR_succfr_slot(MR_curfr));
    printf("succ ip: "); MR_printlabel(stdout, MR_succip_slot(MR_curfr));

    if (MR_detaildebug) {
        MR_printregs("registers at success");
    }
}

void 
MR_fail_msg(void)
{
    MR_restore_transient_registers();

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nfailing from procedure\n");
    printf("curr fr: "); MR_printnondstack(MR_curfr);
    printf("fail fr: "); MR_printnondstack(MR_prevfr_slot(MR_curfr));
    printf("fail ip: "); MR_printlabel(stdout,
        MR_redoip_slot(MR_prevfr_slot(MR_curfr)));
}

void 
MR_redo_msg(void)
{
    MR_restore_transient_registers();

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nredo from procedure\n");
    printf("curr fr: "); MR_printnondstack(MR_curfr);
    printf("redo fr: "); MR_printnondstack(MR_maxfr);
    printf("redo ip: "); MR_printlabel(stdout, MR_redoip_slot(MR_maxfr));
}

void 
MR_call_msg(/* const */ MR_Code *proc, /* const */ MR_Code *succ_cont)
{
    MR_count_call(proc);

#ifdef  MR_DEEP_PROFILING
    MR_check_watch_csd_start(proc);
#endif  /* MR_DEEP_PROFILING */

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\ncall %lu: ", MR_lld_cur_call);
    MR_printlabel(stdout, proc);
    printf("cont ");
    MR_printlabel(stdout, succ_cont);

    if (MR_anyregdebug) {
        MR_printregs("at call:");
    }

#ifdef  MR_DEEP_PROFILING
    MR_print_deep_prof_vars(stdout, "MR_call_msg");
#endif
}

void 
MR_tailcall_msg(/* const */ MR_Code *proc)
{
    MR_restore_transient_registers();

    MR_count_call(proc);

#ifdef  MR_DEEP_PROFILING
    MR_check_watch_csd_start(proc);
#endif  /* MR_DEEP_PROFILING */

    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\ntail call %lu: ", MR_lld_cur_call);
    MR_printlabel(stdout, proc);
    printf("cont ");
    MR_printlabel(stdout, MR_succip);

    if (MR_anyregdebug) {
        MR_printregs("at tailcall:");
    }

#ifdef  MR_DEEP_PROFILING
    MR_print_deep_prof_vars(stdout, "MR_tailcall_msg");
#endif
}

void 
MR_proceed_msg(void)
{
    MR_do_watches();

    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\nreturning from determinate procedure\n");
    if (MR_anyregdebug) {
        MR_printregs("at proceed:");
    }

#ifdef  MR_DEEP_PROFILING
    MR_print_deep_prof_vars(stdout, "MR_proceed_msg");
#endif
}

void 
MR_cr1_msg(const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

#ifdef  MR_RECORD_TERM_SIZES
    printf("create1: put size %ld, value %9lx at ",
        (long) (MR_Integer) addr[-2],
        (long) (MR_Integer) addr[-1]);
#else
    printf("create1: put value %9lx at ",
        (long) (MR_Integer) addr[-1]);
#endif
    MR_printheap(addr);
}

void 
MR_cr2_msg(const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

#ifdef  MR_RECORD_TERM_SIZES
    printf("create2: put size %ld, values %9lx,%9lx at ",   
        (long) (MR_Integer) addr[-3],
        (long) (MR_Integer) addr[-2],
        (long) (MR_Integer) addr[-1]);
#else
    printf("create2: put values %9lx,%9lx at ", 
        (long) (MR_Integer) addr[-2],
        (long) (MR_Integer) addr[-1]);
#endif
    MR_printheap(addr);
}

void 
MR_cr3_msg(const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

#ifdef  MR_RECORD_TERM_SIZES
    printf("create3: put size %ld, values %9lx,%9lx,%9lx at ",  
        (long) (MR_Integer) addr[-4],
        (long) (MR_Integer) addr[-3],
        (long) (MR_Integer) addr[-2],
        (long) (MR_Integer) addr[-1]);
#else
    printf("create3: put values %9lx,%9lx,%9lx at ",    
        (long) (MR_Integer) addr[-3],
        (long) (MR_Integer) addr[-2],
        (long) (MR_Integer) addr[-1]);
#endif
    MR_printheap(addr);
}

void 
MR_incr_hp_debug_msg(MR_Word val, const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

#ifdef MR_CONSERVATIVE_GC
    printf("allocated %ld words at %p\n", (long) val, addr);
#else
    printf("increment hp by %ld from ", (long) (MR_Integer) val);
    MR_printheap(addr);
#endif
}

void 
MR_incr_sp_msg(MR_Word val, const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

    printf("increment sp by %ld from ", (long) (MR_Integer) val);
    MR_printdetstack(addr);
}

void 
MR_decr_sp_msg(MR_Word val, const MR_Word *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

    printf("decrement sp by %ld from ", (long) (MR_Integer) val);
    MR_printdetstack(addr);
}

#endif /* defined(MR_LOWLEVEL_DEBUG) */

#ifdef MR_DEBUG_GOTOS

void 
MR_goto_msg(/* const */ MR_Code *addr)
{
    if (!MR_lld_print_enabled) {
        return;
    }

    printf("\ngoto ");
    MR_printlabel(stdout, addr);
}

void 
MR_reg_msg(void)
{
    int     i;
    MR_Integer  x;

    if (!MR_lld_print_enabled) {
        return;
    }

    for(i=1; i<=8; i++) {
        x = (MR_Integer) MR_get_reg(i);
#ifndef MR_CONSERVATIVE_GC
        if ((MR_Integer) MR_ENGINE(MR_eng_heap_zone)->MR_zone_min <= x
            && x < (MR_Integer) MR_ENGINE(MR_eng_heap_zone)->MR_zone_top)
        {
            x -= (MR_Integer) MR_ENGINE(MR_eng_heap_zone)->MR_zone_min;
        }
#endif
        printf("%8lx ", (long) x);
    }
    printf("\n");
}

#endif /* defined(MR_DEBUG_GOTOS) */

/*--------------------------------------------------------------------*/

#ifdef MR_LOWLEVEL_DEBUG

/* debugging printing tools */

static void
MR_count_call(MR_Code *proc)
{
    MR_lld_cur_call++;
    if (!MR_lld_print_region_enabled) {
        if (MR_lld_cur_call == MR_lld_print_min) {
            MR_lld_print_region_enabled = MR_TRUE;
            printf("entering printed region\n");
            printf("min %lu, max %lu, more <%s>\n",
                MR_lld_print_min, MR_lld_print_max,
                MR_lld_print_more_min_max);
        }
    } else {
        if (MR_lld_cur_call == MR_lld_print_max) {
            MR_lld_print_region_enabled = MR_FALSE;
            MR_setup_call_intervals(&MR_lld_print_more_min_max,
                &MR_lld_print_min, &MR_lld_print_max);
            printf("leaving printed region\n");
            printf("min %lu, max %lu, more <%s>\n",
                MR_lld_print_min, MR_lld_print_max,
                MR_lld_print_more_min_max);
        
        }
    }

    if (MR_proc_matches_name(proc, MR_lld_start_name)) {
        MR_lld_print_name_enabled = MR_TRUE;
        MR_lld_start_until = MR_lld_cur_call + MR_lld_start_block;
        printf("entering printed name block %s\n", MR_lld_start_name);
    } else if (MR_lld_cur_call == MR_lld_start_until) {
        MR_lld_print_name_enabled = MR_FALSE;
        printf("leaving printed name block\n");
    }

#ifdef  MR_DEEP_PROFILING
    if (MR_watch_csd_addr == MR_next_call_site_dynamic
        && MR_watch_csd_addr != NULL)
    {
        MR_lld_print_csd_enabled = MR_TRUE;
        MR_lld_csd_until = MR_lld_cur_call + MR_lld_start_block;
        MR_watch_csd_started = MR_TRUE;
        printf("entering printed csd block %p\n", MR_watch_csd_addr);
    } else if (MR_lld_cur_call == MR_lld_csd_until) {
        MR_lld_print_csd_enabled = MR_FALSE;
        printf("leaving printed csd block\n");
    }
#endif

    /* the bitwise ORs implement logical OR */
    MR_lld_print_enabled = MR_lld_print_region_enabled
        | MR_lld_print_name_enabled | MR_lld_print_csd_enabled
        | MR_lld_debug_enabled;
}

void 
MR_printint(MR_Word n)
{
    printf("int %ld\n", (long) (MR_Integer) n);
}

void 
MR_printstring(const char *s)
{
    if (MR_print_raw_addrs) {
        printf("string %p %s\n", (const void *) s, s);
    } else {
        printf("string %s\n", s);
    }
}

void 
MR_printheap(const MR_Word *h)
{
#ifndef MR_CONSERVATIVE_GC
    if (MR_print_raw_addrs) {
        printf("ptr %p, ", (const void *) h);
    }

    printf("offset %3ld words\n",
        (long) (MR_Integer) (h - MR_ENGINE(MR_eng_heap_zone)->min));
#else
    printf("ptr %p\n",
        (const void *) h);
#endif
}

void 
MR_dumpframe(/* const */ MR_Word *fr)
{
    int i;

    printf("frame at ");
    if (MR_print_raw_addrs) {
        printf("ptr %p, ", (const void *) fr);
    }

    printf("offset %3ld words\n",
        (long) (MR_Integer) MR_non_stack_offset(fr));
    printf("\t succip    "); MR_printlabel(stdout, MR_succip_slot(fr));
    printf("\t redoip    "); MR_printlabel(stdout, MR_redoip_slot(fr));
    printf("\t succfr    "); MR_printnondstack(MR_succfr_slot(fr));
    printf("\t prevfr    "); MR_printnondstack(MR_prevfr_slot(fr));

    for (i = 1; &MR_based_framevar(fr,i) > MR_prevfr_slot(fr); i++) {
        printf("\t framevar(%d)  %ld 0x%lx\n",
            i, (long) (MR_Integer) MR_based_framevar(fr,i),
            (unsigned long) MR_based_framevar(fr,i));
    }
}

void 
MR_dumpnondstack(void)
{
    MR_Word *fr;

    printf("\nnondstack dump\n");
    for (fr = MR_maxfr; fr > MR_nondet_stack_trace_bottom;
        fr = MR_prevfr_slot(fr))
    {
        MR_dumpframe(fr);
    }
}

void 
MR_printframe(const char *msg)
{
    printf("\n%s\n", msg);
    MR_dumpframe(MR_curfr);

    MR_print_ordinary_regs();
}

void 
MR_printregs(const char *msg)
{
    MR_restore_transient_registers();

    printf("\n%s\n", msg);

    if (MR_sregdebug) {
        printf("%-9s", "succip:");  MR_printlabel(stdout, MR_succip);
        printf("%-9s", "curfr:");   MR_printnondstack(MR_curfr);
        printf("%-9s", "maxfr:");   MR_printnondstack(MR_maxfr);
        printf("%-9s", "hp:");      MR_printheap(MR_hp);
        printf("%-9s", "sp:");      MR_printdetstack(MR_sp);
    }

    if (MR_ordregdebug) {
        MR_print_ordinary_regs();
    }
}

static void 
MR_print_ordinary_regs(void)
{
    int     i;
    MR_Integer  value;

    for (i = 0; i < 8; i++) {
        printf("r%d:      ", i + 1);
        value = (MR_Integer) MR_get_reg(i+1);

#ifndef MR_CONSERVATIVE_GC
        if ((MR_Integer) MR_ENGINE(MR_eng_heap_zone)->min <= value
                && value < (MR_Integer)
                    MR_ENGINE(MR_eng_heap_zone)->top)
        {
            printf("(heap) ");
        }
#endif

        printf("%ld %lx\n", (long) value, (long) value);
    }
}

#ifdef  MR_DEEP_PROFILING

static struct MR_CallSiteDynamic_Struct MR_watched_csd_last_value =
{
    /* MR_csd_callee_ptr */ NULL,
    { 
  #ifdef MR_DEEP_PROFILING_PORT_COUNTS
    #ifdef MR_DEEP_PROFILING_EXPLICIT_CALL_COUNTS
    /* MR_own_calls */ 0,
    #else
    /* calls are computed from the other fields */
    #endif
    /* MR_own_exits */ 0,
    /* MR_own_fails */ 0,
    /* MR_own_redos */ 0,
  #endif
  #ifdef MR_DEEP_PROFILING_TIMING
    /* MR_own_quanta */ 0,
  #endif
  #ifdef MR_DEEP_PROFILING_MEMORY
    /* MR_own_allocs */ 0,
    /* MR_own_words */ 0,
  #endif
    },
    /* MR_csd_depth_count */ 0
};

static void
MR_check_watch_csd_start(MR_Code *proc)
{
#if 0
    if (MR_watch_csd_start_name == NULL) {
        return;
    }

    if (MR_proc_matches_name(proc, MR_watch_csd_start_name)) {
        if (MR_watch_csd_addr == MR_next_call_site_dynamic) {
            /*
            ** Optimize future checks and make
            ** MR_watch_csd_addr static.
            */
            MR_watch_csd_started = MR_TRUE;
            MR_watch_csd_start_name = NULL;
        }
    }
#endif
}

static MR_bool
MR_csds_are_different(MR_CallSiteDynamic *csd1, MR_CallSiteDynamic *csd2)
{
    MR_ProfilingMetrics *pm1;
    MR_ProfilingMetrics *pm2;

    if (csd1->MR_csd_callee_ptr != csd2->MR_csd_callee_ptr)
        return MR_TRUE;

    pm1 = &csd1->MR_csd_own;
    pm2 = &csd2->MR_csd_own;

  #ifdef MR_DEEP_PROFILING_PORT_COUNTS
    #ifdef MR_DEEP_PROFILING_EXPLICIT_CALL_COUNTS
    if (pm1->MR_own_calls != pm2->MR_own_calls)
        return MR_TRUE;
    #endif
    if (pm1->MR_own_exits != pm2->MR_own_exits)
        return MR_TRUE;
    if (pm1->MR_own_fails != pm2->MR_own_fails)
        return MR_TRUE;
    if (pm1->MR_own_redos != pm2->MR_own_redos)
        return MR_TRUE;
  #endif
  #ifdef MR_DEEP_PROFILING_TIMING
    if (pm1->MR_own_quanta != pm2->MR_own_quanta)
        return MR_TRUE;
  #endif
  #ifdef MR_DEEP_PROFILING_MEMORY
    if (pm1->MR_own_allocs != pm2->MR_own_allocs)
        return MR_TRUE;
    if (pm1->MR_own_words != pm2->MR_own_words)
        return MR_TRUE;
  #endif

    if (csd1->MR_csd_depth_count != csd2->MR_csd_depth_count)
        return MR_TRUE;

    return MR_FALSE;
};

static void
MR_assign_csd(MR_CallSiteDynamic *csd1, MR_CallSiteDynamic *csd2)
{
    csd1->MR_csd_callee_ptr = csd2->MR_csd_callee_ptr;

  #ifdef MR_DEEP_PROFILING_PORT_COUNTS
    #ifdef MR_DEEP_PROFILING_EXPLICIT_CALL_COUNTS
    csd1->MR_csd_own.MR_own_calls = csd2->MR_csd_own.MR_own_calls;
    #endif
    csd1->MR_csd_own.MR_own_exits = csd2->MR_csd_own.MR_own_exits;
    csd1->MR_csd_own.MR_own_fails = csd2->MR_csd_own.MR_own_fails;
    csd1->MR_csd_own.MR_own_redos = csd2->MR_csd_own.MR_own_redos;
  #endif
  #ifdef MR_DEEP_PROFILING_TIMING
    /* MR_own_quanta */ 0,
    csd1->MR_csd_own.MR_own_quanta = csd2->MR_csd_own.MR_own_quanta;
  #endif
  #ifdef MR_DEEP_PROFILING_MEMORY
    csd1->MR_csd_own.MR_own_allocs = csd2->MR_csd_own.MR_own_allocs;
    csd1->MR_csd_own.MR_own_words = csd2->MR_csd_own.MR_own_words;
  #endif

    csd1->MR_csd_depth_count = csd2->MR_csd_depth_count;
};

#endif  /* MR_DEEP_PROFILING */

static void
MR_do_watches(void)
{
    if (MR_watch_addr != NULL) {
        printf("watch addr %p: 0x%lx %ld\n", MR_watch_addr,
            (long) *MR_watch_addr, (long) *MR_watch_addr);
    }

#ifdef  MR_DEEP_PROFILING
    if (MR_watch_csd_addr != NULL) {
        if (MR_watch_csd_started) {
            if (MR_csds_are_different(&MR_watched_csd_last_value,
                MR_watch_csd_addr))
            {
                MR_assign_csd(&MR_watched_csd_last_value,
                    MR_watch_csd_addr);
                printf("current call: %lu\n", MR_lld_cur_call);
                MR_print_deep_prof_var(stdout, "watch_csd",
                    MR_watch_csd_addr);
            }
        }
    }
#endif  /* MR_DEEP_PROFILING */
}

static MR_bool
MR_proc_matches_name(MR_Code *proc, const char *name)
{
#ifdef  MR_NEED_ENTRY_LABEL_ARRAY
    MR_Entry    *entry;

    entry = MR_prev_entry_by_addr(proc);
    if (entry != NULL && entry->e_addr == proc && entry->e_name != NULL) {
        if (MR_streq(entry->e_name, name)) {
            return MR_TRUE;
        }
    }

#endif  /* MR_NEED_ENTRY_LABEL_ARRAY */
    return MR_FALSE;
}

#endif /* defined(MR_DEBUG_GOTOS) */

#ifndef MR_HIGHLEVEL_CODE

void 
MR_printdetstackptr(const MR_Word *s)
{
    MR_print_detstackptr(stdout, s);
}

void 
MR_print_detstackptr(FILE *fp, const MR_Word *s)
{
    fprintf(fp, "det %3ld",
        (long) (MR_Integer) MR_det_stack_offset(s));

    if (MR_print_raw_addrs) {
        fprintf(fp, " (%p)", (const void *) s);
    }
}

void 
MR_printdetstack(const MR_Word *s)
{
    if (MR_print_raw_addrs) {
        printf("ptr %p, ", (const void *) s);
    }

    printf("offset %3ld words\n",
        (long) (MR_Integer) MR_det_stack_offset(s));
}

void 
MR_printnondstackptr(const MR_Word *s)
{
    MR_print_nondstackptr(stdout, s);
}

void 
MR_print_nondstackptr(FILE *fp, const MR_Word *s)
{
    fprintf(fp, "non %3ld",
        (long) (MR_Integer) MR_non_stack_offset(s));

    if (MR_print_raw_addrs) {
        fprintf(fp, " (%p)",
        (const void *) s);
    }
}

void 
MR_printnondstack(const MR_Word *s)
{
    if (MR_print_raw_addrs) {
        printf("ptr %p, ", (const void *) s);
    }

    printf("offset %3ld words\n",
        (long) (MR_Integer) MR_non_stack_offset(s));
}

#endif /* !MR_HIGHLEVEL_CODE */

void 
MR_print_heapptr(FILE *fp, const MR_Word *s)
{
#ifdef  MR_CONSERVATIVE_GC
    fprintf(fp, "heap %ld", (long) s);
#else
    fprintf(fp, "heap %3ld",
        (long) (MR_Integer) (s - MR_ENGINE(MR_eng_heap_zone)->MR_zone_min));
#endif

    if (MR_print_raw_addrs) {
        printf(" (%p)", (const void *) s);
    }
}

void 
MR_print_label(FILE *fp, /* const */ MR_Code *w)
{
    MR_Internal *internal;

    internal = MR_lookup_internal_by_addr(w);
    if (internal != NULL) {
        if (internal->i_name != NULL) {
            fprintf(fp, "label %s", internal->i_name);
        } else {
            fprintf(fp, "unnamed label %p", internal->i_addr);
        }
#ifdef  MR_DEBUG_LABEL_GOAL_PATHS
        if (internal->i_layout != NULL) {
            fprintf(fp, " <%s>",
                MR_label_goal_path(internal->i_layout));
        }
#endif
    } else {
#ifdef  MR_NEED_ENTRY_LABEL_ARRAY
        MR_Entry    *entry;

        entry = MR_prev_entry_by_addr(w);
        if (entry != NULL && entry->e_addr == w) {
            if (entry->e_name != NULL) {
                fprintf(fp, "entry label %s", entry->e_name);
            } else {
                fprintf(fp, "unnamed entry label %p",
                    entry->e_addr);
            }
        } else {
            fprintf(fp, "label UNKNOWN %p", w);
        }
#else
        fprintf(fp, "label UNKNOWN %p", w);
#endif  /* not MR_NEED_ENTRY_LABEL_ARRAY */
    }

    if (MR_print_raw_addrs) {
        fprintf(fp, " (%p)", w);
    }
}

void 
MR_printlabel(FILE *fp, /* const */ MR_Code *w)
{
    MR_print_label(fp, w);
    fprintf(fp, "\n");
}

void
MR_print_deep_prof_var(FILE *fp, const char *name, MR_CallSiteDynamic *csd)
{
#ifdef  MR_DEEP_PROFILING
    fprintf(fp, "%s: %p", name, csd);

    if (csd == NULL) {
        fprintf(fp, "\n");
    } else {
        const MR_ProcDynamic    *pd;
        const MR_Proc_Layout    *pl;
        const MR_ProcStatic *ps;
        const MR_Proc_Id    *proc_id;

        fprintf(fp, ", depth %d,",
            csd->MR_csd_depth_count);

#ifdef  MR_DEEP_PROFILING_EXPLICIT_CALL_COUNTS
        fprintf(fp, " calls %d,",
            csd->MR_csd_own.MR_own_calls);
#endif
        fprintf(fp, " exits %d, fails %d, redos %d\n",
            csd->MR_csd_own.MR_own_exits,
            csd->MR_csd_own.MR_own_fails,
            csd->MR_csd_own.MR_own_redos);

        pd = csd->MR_csd_callee_ptr;
        fprintf(fp, "  pd: %p", pd);
        if (pd == NULL) {
            fprintf(fp, "\n");
        } else if (pd->MR_pd_proc_layout == NULL) {
            fprintf(fp, ", pl is NULL\n");
        } else {
            pl = pd->MR_pd_proc_layout;
            ps = pl->MR_sle_proc_static;
            fprintf(fp, ", pl: %p, ps: %p\n", pl, ps);
            proc_id = &pl->MR_sle_proc_id;
            if (MR_PROC_ID_IS_UCI(*proc_id)) {
                fprintf(fp, "  %s:%s %s/%d-%d\n  ",
                    proc_id->MR_proc_uci.
                        MR_uci_type_module,
                    proc_id->MR_proc_uci.
                        MR_uci_type_name,
                    proc_id->MR_proc_uci.
                        MR_uci_pred_name,
                    proc_id->MR_proc_uci.
                        MR_uci_type_arity,
                    proc_id->MR_proc_uci.MR_uci_mode);
            } else {
                fprintf(fp, "  %s.%s/%d-%d\n  ",
                    proc_id->MR_proc_user.
                        MR_user_decl_module,
                    proc_id->MR_proc_user.MR_user_name,
                    proc_id->MR_proc_user.MR_user_arity,
                    proc_id->MR_proc_user.MR_user_mode);
            }

#ifdef  MR_USE_ACTIVATION_COUNTS
            fprintf(fp, "active %d, ",
                ps->MR_ps_activation_count);
#endif
            fprintf(fp, "outermost %p, array %d\n",
                ps->MR_ps_outermost_activation_ptr,
                ps->MR_ps_num_call_sites);
        }
    }
#endif
}
