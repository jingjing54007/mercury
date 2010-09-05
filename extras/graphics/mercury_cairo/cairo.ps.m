%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Author: Julien Fischer <juliensf@csse.unimelb.edu.au>
% 
% This sub-module contains support for rendering PostScript documents.
%
%---------------------------------------------------------------------------%

:- module cairo.ps.
:- interface.

%---------------------------------------------------------------------------%

:- type ps_surface.

:- instance surface(ps_surface).

%---------------------------------------------------------------------------%

    % This type describes the language level of the PostScript Language
    % Reference that a generated PostScript file will conform to.
    %
:- type ps_level
    --->    ps_level_2
            % The language level 2 of the PostScript specification.
          
    ;       ps_level_3.
            % The language level 3 of the PostScript specification.

%---------------------------------------------------------------------------%

    % Succeeds if PostScript surfaces are supported by this implementation.
    %
:- pred have_ps_surface is semidet.

    % ps.create_surface(FileName, Height, Width, Surface, !IO):
    % Surface is a PostScript surface of the specified Height and Width in
    % in points to be written to FileName.
    % Throw an unsupported_surface_error/0 exception if PostScript surfaces
    % are not supported by this implementation.  Throws a cairo.error/0
    % exception if any other error occurs.
    %
:- pred create_surface(string::in, float::in, float::in, ps_surface::out,
	io::di, io::uo) is det.

    % ps.restrict_to_level(Surface, Level, !IO):
    % Restrict Surface to the given Level of the PostScript specification.
    %
:- pred restrict_to_level(ps_surface::in, ps_level::in,
    io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- pragma foreign_decl("C", "

#if defined(CAIRO_HAS_PS_SURFACE)
  #include <cairo-ps.h>
#endif

").

:- pragma foreign_type("C", ps_surface, "MCAIRO_surface *",
	[can_pass_as_mercury_type]).

:- instance surface(ps_surface) where [].

:- pragma foreign_enum("C", ps_level/0, [
    ps_level_2 - "CAIRO_PS_LEVEL_2",
    ps_level_3 - "CAIRO_PS_LEVEL_3"
]).

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
   have_ps_surface,
   [promise_pure, will_not_call_mercury],
"
#if defined(CAIRO_HAS_PS_SURFACE)
   SUCCESS_INDICATOR = MR_TRUE;
#else
    SUCCESS_INDICATOR = MR_FALSE;
#endif
").

%-----------------------------------------------------------------------------%
%
% PostScript surface creation
%

:- type maybe_ps_surface
    --->    ps_surface_ok(ps_surface)
    ;       ps_surface_error(cairo.status)
    ;       ps_surface_unsupported.

:- pragma foreign_export("C", make_ps_surface_ok(in) = out,
    "MCAIRO_ps_surface_ok").
:- func make_ps_surface_ok(ps_surface) = maybe_ps_surface.

make_ps_surface_ok(Surface) = ps_surface_ok(Surface).

:- pragma foreign_export("C", make_ps_surface_error(in) = out,
    "MCAIRO_ps_surface_error").
:- func make_ps_surface_error(cairo.status) = maybe_ps_surface.

make_ps_surface_error(Status) = ps_surface_error(Status).

:- pragma foreign_export("C", make_ps_surface_unsupported = out,
    "MCAIRO_ps_surface_unsupported").
:- func make_ps_surface_unsupported = maybe_ps_surface.

make_ps_surface_unsupported = ps_surface_unsupported.

create_surface(FileName, Height, Width, Surface, !IO) :-
    create_surface_2(FileName, Height, Width, MaybeSurface, !IO),
    (
        MaybeSurface = ps_surface_ok(Surface)
    ;
        MaybeSurface = ps_surface_error(ErrorStatus),
        throw(cairo.error("ps.create_surface/6", ErrorStatus))
    ;
        MaybeSurface = ps_surface_unsupported,
        throw(cairo.unsupported_surface_error("PostScript"))
    ).

:- pred create_surface_2(string::in,
    float::in, float::in, maybe_ps_surface::out, io::di, io::uo) is det.

:- pragma foreign_proc("C",
	create_surface_2(FileName::in, H::in, W::in, MaybeSurface::out,
		_IO0::di, _IO::uo),
	[promise_pure, will_not_call_mercury, tabled_for_io],
"
#if defined(CAIRO_HAS_PS_SURFACE)

    MCAIRO_surface      *surface;
    cairo_surface_t		*raw_surface;
    cairo_status_t      status;

    raw_surface = cairo_ps_surface_create(FileName, H, W);
    status = cairo_surface_status(raw_surface);
    
    switch (status) {
        case CAIRO_STATUS_SUCCESS:
            surface = MR_GC_NEW(MCAIRO_surface);
            surface->mcairo_raw_surface = raw_surface;
            MR_GC_register_finalizer(surface, MCAIRO_finalize_surface, 0);
            MaybeSurface = MCAIRO_ps_surface_ok(surface);
            break;

        case CAIRO_STATUS_NULL_POINTER:
        case CAIRO_STATUS_NO_MEMORY:
        case CAIRO_STATUS_READ_ERROR:
        case CAIRO_STATUS_INVALID_CONTENT:
        case CAIRO_STATUS_INVALID_FORMAT:
        case CAIRO_STATUS_INVALID_VISUAL:
            MaybeSurface = MCAIRO_ps_surface_error(status);
            break;

        default:
            MR_fatal_error(\"cairo: unknown PostScript surface status\");
    }

#else
    MaybeSurface = MCAIRO_ps_surface_unsupported();
#endif

").

:- pragma foreign_proc("C",
    restrict_to_level(Surface::in, Level::in, _IO0::di, _IO::uo),
	[promise_pure, will_not_call_mercury, tabled_for_io],
"
#if defined(CAIRO_HAS_PS_SURFACE)
    cairo_ps_surface_restrict_to_level(Surface->mcairo_raw_surface, Level);
#else
   MR_fatal_error(\"Cairo PDF surface not available\");
#endif
").

%---------------------------------------------------------------------------%
:- end_module cairo.ps.
%---------------------------------------------------------------------------%
