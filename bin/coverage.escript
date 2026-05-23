#!/usr/bin/env escript

%% Test-coverage runner for the Gleam app.
%%
%% Cover-compiles the application's source modules (not the test modules),
%% runs the gleeunit test suite under instrumentation via EUnit, prints a
%% per-module + total line-coverage summary, and writes a Cobertura XML
%% report (via the `covertool` dev dependency) for CI consumption.
%%
%% Requires the project to be compiled first (`gleam test`); the wrapper
%% script `bin/coverage` does that before invoking this escript.

-define(APP, "notyet").
-define(EBIN, "build/dev/erlang/" ?APP "/ebin").
-define(OUT_DIR, "build/coverage").

main(_) ->
    ok = code:add_pathsa([filename:absname(D)
                          || D <- filelib:wildcard("build/dev/erlang/*/ebin")]),
    Beams = filelib:wildcard(?EBIN "/*.beam"),
    {SrcBeams, TestMods} = classify(Beams),

    %% A stale-beam skip or a mis-mapped layout could leave no test modules to
    %% run; eunit:test([]) returns `ok`, which would report a vacuous pass.
    case TestMods of
        [] -> halt_with("no test modules found", 1);
        _ -> ok
    end,

    {ok, _} = cover:start(),
    [cover_compile(B) || B <- SrcBeams],

    %% DB-backed tests run real queries through pgo, whose query-cache ETS table
    %% is created by the pgo *application* start (pgo_app -> pgo_query_cache).
    %% `gleam test` boots the app tree; this escript runs EUnit directly, so we
    %% must start pgo ourselves or every DB query crashes with a `badarg` ETS
    %% lookup on a missing `pgo_query_cache` table.
    {ok, _} = application:ensure_all_started(pgo),

    %% This escript runs EUnit in its own BEAM and never calls
    %% notyet_test:main, so it must provision the test database itself, the
    %% same way the gleam test runner does: start a postgres testcontainer, set
    %% DATABASE_URL, and migrate. `application:load(notyet)` makes
    %% `code:priv_dir(notyet)` resolve so cigogne finds priv/migrations. The
    %% container is reaped when this process exits.
    {ok, _} = application:ensure_all_started(testcontainers),
    _ = application:load(notyet),
    testdb:setup(),

    case eunit:test(TestMods, [verbose]) of
        ok -> ok;
        error -> halt_with("tests failed", 1)
    end,

    SrcMods = [beam_module(B) || B <- SrcBeams],
    {TotalLc, TotalLn, TotalCc, TotalCn} = print_summary(SrcMods),
    write_reports(),
    LinePct = pct(TotalLc, TotalLn),
    ClausePct = pct(TotalCc, TotalCn),
    %% Two gates: lines >= 80% and clauses >= 90%. The line floor is bounded by
    %% the irreducible boot glue in notyet:main/0 (mist + supervisor + pog
    %% wiring + sleep_forever), which cannot run under a unit test; the clause
    %% metric, where main/0 is a single clause, is the stronger branch proxy.
    case LinePct >= 80.0 andalso ClausePct >= 90.0 of
        true ->
            io:format("~nCoverage gate passed: lines ~.2f% (>= 80%), "
                      "clauses ~.2f% (>= 90%)~n", [LinePct, ClausePct]),
            ok;
        false ->
            halt_with(lists:flatten(io_lib:format(
                "coverage gate failed: lines ~.2f% (need >= 80%), "
                "clauses ~.2f% (need >= 90%)", [LinePct, ClausePct])), 1)
    end.

%% Split beams into {src beam paths, test module atoms}.
%% Test modules end in "_test"; "notyet_test" is gleeunit's generated entry
%% point and "@@"-prefixed modules are Gleam-generated wrappers — both excluded
%% from the EUnit run and from coverage (they are test/generated code, not the
%% application source under test). Everything else, including the "notyet"
%% bootstrap module, is measured.
classify(Beams) ->
    lists:foldl(
        fun(Beam, {Src, Tests}) ->
            Name = beam_name(Beam),
            case classify_name(Name) of
                src ->
                    %% A module that looks like source but whose .gleam lives
                    %% outside src/ (e.g. test/test_helper.gleam) is test
                    %% support, not application code — don't measure it.
                    case src_source_exists(Name) of
                        true -> {[Beam | Src], Tests};
                        false -> {Src, Tests}
                    end;
                test ->
                    %% `gleam test` compiles from source and ignores orphaned
                    %% beams, but this escript globs `ebin/*.beam` and would run
                    %% a stale `_test` beam whose `.gleam` source was deleted —
                    %% calling functions that no longer exist (`undef`). Only run
                    %% a test module whose source still exists.
                    case test_source_exists(Name) of
                        true -> {Src, [list_to_atom(Name) | Tests]};
                        false ->
                            io:format("cover: skipping stale test beam ~s "
                                      "(no .gleam source)~n", [Name]),
                            {Src, Tests}
                    end;
                skip -> {Src, Tests}
            end
        end,
        {[], []},
        Beams
    ).

%% Gleam test module `a@b@c_test` maps to source `test/a/b/c_test.gleam`.
test_source_exists(Name) ->
    Rel = lists:flatten(string:replace(Name, "@", "/", all)),
    filelib:is_regular("test/" ++ Rel ++ ".gleam").

%% Gleam module `a@b@c` maps to source `src/a/b/c.gleam`.
src_source_exists(Name) ->
    Rel = lists:flatten(string:replace(Name, "@", "/", all)),
    filelib:is_regular("src/" ++ Rel ++ ".gleam").

classify_name(?APP "_test") -> skip;
classify_name(Name) ->
    IsTest = lists:suffix("_test", Name),
    IsGenerated = string:find(Name, "@@") =/= nomatch,
    if
        IsTest -> test;
        IsGenerated -> skip;
        true -> src
    end.

beam_name(Beam) -> filename:basename(Beam, ".beam").
beam_module(Beam) -> list_to_atom(beam_name(Beam)).

cover_compile(Beam) ->
    case cover:compile_beam(Beam) of
        {ok, _Module} -> ok;
        {error, Reason} ->
            io:format("cover: skipping ~s (~p)~n", [beam_name(Beam), Reason])
    end.

%% Two metrics per module:
%%   lines   - executable lines hit / total (cover's `coverage`/line analysis)
%%   clauses - function clauses entered at least once / total (`calls`/clause);
%%             a clause-level proxy for statement/branch coverage, since Erlang's
%%             `cover` has no dedicated branch metric.
print_summary(Mods) ->
    io:format("~nCoverage~n~-32s ~13s  ~13s~n",
              ["module", "lines", "clauses"]),
    {LC, LN, CC, CN} =
        lists:foldl(
            fun(Mod, {ALC, ALN, ACC, ACN}) ->
                {Lc, Ln} = line_coverage(Mod),
                {Cc, Cn} = clause_coverage(Mod),
                print_row(atom_to_list(Mod), Lc, Ln, Cc, Cn),
                {ALC + Lc, ALN + Ln, ACC + Cc, ACN + Cn}
            end,
            {0, 0, 0, 0},
            lists:sort(Mods)
        ),
    print_row("TOTAL", LC, LN, CC, CN),
    {LC, LN, CC, CN}.

print_row(Name, Lc, Ln, Cc, Cn) ->
    io:format("  ~-30s ~6.2f% ~5s ~6.2f% ~5s~n",
              [Name,
               pct(Lc, Ln), io_lib:format("~p/~p", [Lc, Lc + Ln]),
               pct(Cc, Cn), io_lib:format("~p/~p", [Cc, Cc + Cn])]).

line_coverage(Mod) ->
    case cover:analyse(Mod, coverage, module) of
        {ok, {Mod, {C, N}}} -> {C, N};
        _ -> {0, 0}
    end.

clause_coverage(Mod) ->
    case cover:analyse(Mod, calls, clause) of
        {ok, Clauses} ->
            Hit = length([1 || {_Clause, Calls} <- Clauses, Calls > 0]),
            {Hit, length(Clauses) - Hit};
        _ -> {0, 0}
    end.

pct(_C, 0) -> 100.0;
pct(C, N) -> 100.0 * C / (C + N).

write_reports() ->
    ok = filelib:ensure_dir(?OUT_DIR "/"),
    CoverData = ?OUT_DIR "/" ?APP ".coverdata",
    Xml = ?OUT_DIR "/cobertura.xml",
    ok = cover:export(CoverData),
    %% Run covertool in a throwaway VM: it (and `cover` during import) write
    %% chatter straight to the `user` device, which an in-process group_leader
    %% swap can't capture. A separate process with discarded output keeps the
    %% summary above as the only signal.
    Eval = io_lib:format(
        "covertool:main([\"-cover\",\"~s\",\"-output\",\"~s\","
        "\"-ebin\",\"~s\",\"-src\",\"src\",\"-appname\",\"~s\"])",
        [CoverData, Xml, ?EBIN, ?APP]),
    Cmd = io_lib:format(
        "erl -noshell -pa build/dev/erlang/*/ebin -eval '~s' -s init stop"
        " >/dev/null 2>&1",
        [Eval]),
    [] = os:cmd(lists:flatten(Cmd)),
    io:format("~nCobertura report: ~s~n", [Xml]).

halt_with(Msg, Code) ->
    io:format(standard_error, "~s~n", [Msg]),
    halt(Code).
