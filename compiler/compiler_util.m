%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1997-2006, 2009-2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: compiler_util.
% Main author: zs.
%
% This module contains code that can be helpful in any compiler module.
%
%-----------------------------------------------------------------------------%

:- module libs.compiler_util.
:- interface.

:- import_module libs.globals.
:- import_module parse_tree.
:- import_module parse_tree.error_util.

:- import_module io.
:- import_module list.

%-----------------------------------------------------------------------------%

:- pred add_error(error_phase::in, list(format_component)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

:- pred add_warning(error_phase::in, list(format_component)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

%-----------------------------------------------------------------------------%

    % Record the fact that a warning has been issued; set the exit status
    % to error if the `--halt-at-warn' option is set.
    %
:- pred record_warning(globals::in, io::di, io::uo) is det.

    % Report a warning, and set the exit status to error if the
    % `--halt-at-warn' option is set.
    %
:- pred report_warning(globals::in, string::in, io::di, io::uo) is det.

    % Report a warning to the specified stream, and set the exit status
    % to error if the --halt-at-warn option is set.
    %
:- pred report_warning_to_stream(globals::in, io.output_stream::in, string::in,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.options.

:- import_module bool.
:- import_module maybe.

%-----------------------------------------------------------------------------%

add_error(Phase, Pieces, !Specs) :-
    Msg = error_msg(no, do_not_treat_as_first, 0, [always(Pieces)]),
    Spec = error_spec(severity_error, Phase, [Msg]),
    !:Specs = [Spec | !.Specs].

add_warning(Phase, Pieces, !Specs) :-
    Msg = error_msg(no, do_not_treat_as_first, 0, [always(Pieces)]),
    Spec = error_spec(severity_warning, Phase, [Msg]),
    !:Specs = [Spec | !.Specs].

%-----------------------------------------------------------------------------%

record_warning(Globals, !IO) :-
    globals.lookup_bool_option(Globals, halt_at_warn, HaltAtWarn),
    (
        HaltAtWarn = yes,
        io.set_exit_status(1, !IO)
    ;
        HaltAtWarn = no
    ).

report_warning(Globals, Message, !IO) :-
    record_warning(Globals, !IO),
    io.write_string(Message, !IO).

report_warning_to_stream(Globals, Stream, Message, !IO) :-
    record_warning(Globals, !IO),
    io.write_string(Stream, Message, !IO).

%-----------------------------------------------------------------------------%
:- end_module libs.compiler_util.
%-----------------------------------------------------------------------------%
