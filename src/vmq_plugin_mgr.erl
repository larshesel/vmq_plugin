%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_plugin_mgr).
-behaviour(gen_server).

-define(CONFIG_V1, v1).

%% API
-export([start_link/0,
         stop/0
        ]).

%% runlevels
-export([goto_runlevel/1
        ,register_module_plugin/4
        ,register_module_plugin/5
        %% ,unregister_module_plugin/3
        %% ,unregister_module_plugin/4
        ,register_app_plugin/2
        ,register_app_plugin/3
        %% ,unregister_app_plugin/1
        ,dump_plugins/0
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([sample_hook/0,
         sample_hook/1,
         sample_hook/2,
         sample_hook/3,
         other_sample_hook_a/1,
         other_sample_hook_b/1,
         other_sample_hook_c/1,
         other_sample_hook_d/1,
         other_sample_hook_e/1,
         other_sample_hook_f/1,
         other_sample_hook_x/1
        ]).
-endif.

-record(state, {
          ready=false,
          plugin_dir,
          config_file,
          %% proplist of plugins, most recent added first.
          plugins=[],
          runlevel=none,
          deferred_calls=[]}).

-type plugin_runlevel() :: system
                         | user.
-type runlevel() :: none
                  | plugin_runlevel().

-define(RUNLEVELS, [{none,   0} %% the runlevel without any running plugins
                   ,{system, 1}
                   ,{user,   2}]).

%% -type plugin() :: atom()
%%                 | {atom(),
%%                    atom(),
%%                    atom(),
%%                    non_neg_integer()}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    %% only call after all application that call INTO a
    %% plugin are stopped...
    gen_server:call(?MODULE, stop, infinity).

-spec register_app_plugin(atom(), atom()) -> ok | {error, _}.
register_app_plugin(Plugin, Level) ->
    register_app_plugin(Plugin, [], Level).

-spec register_app_plugin(atom(), [string()], plugin_runlevel()) -> ok | {error, _}.
register_app_plugin(Plugin, Paths, Level) when
      is_atom(Plugin) and is_list(Paths) and is_atom(Level)  ->
    gen_server:call(?MODULE, {register_app_plugin, Plugin,
                              #{level => Level, paths => Paths}}, infinity).

-spec register_module_plugin(atom(), atom(), non_neg_integer(), plugin_runlevel()) ->
    ok | {error, _}.
register_module_plugin(Module, Fun, Arity, Level) ->
    register_module_plugin(Fun, Module, Fun, Arity, Level).

-spec register_module_plugin(atom(), atom(), atom(), non_neg_integer(), atom()) ->
    ok | {error, _}.
register_module_plugin(HookName, Module, Fun, Arity, Level) when
      is_atom(HookName) and is_atom(Module)
      and is_atom(Fun) and (Arity >= 0) and is_atom(Level) ->
    gen_server:call(?MODULE, {register_module_plugin, HookName, Module, Fun, Arity, Level},
                    infinity).

dump_plugins() ->
    gen_server:call(?MODULE, dump_plugins).

-spec goto_runlevel(runlevel()) -> ok | {error, _}.
goto_runlevel(Level) ->
    gen_server:call(?MODULE, {goto_runlevel, Level}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, PluginDir} = application:get_env(vmq_plugin, plugin_dir),
    {ok, ConfigFileName} = application:get_env(vmq_plugin, plugin_config),
    VmqSchemaDir = application:get_env(vmq_plugin, default_schema_dir, []),

    case filelib:ensure_dir(PluginDir) of
        ok ->
            ConfigFile = filename:join(PluginDir, ConfigFileName),
            Config = read_config(ConfigFile),
            case clique_config:load_schema(VmqSchemaDir) of
                {error, schema_files_not_found} ->
                    lager:debug("couldn't load cuttlefish schema for plugin: ~p", [vmq_plugin]);
                ok ->
                    ok
            end,
            case wait_until_ready(#state{plugin_dir=PluginDir,
                                         config_file=ConfigFile,
                                         plugins=Config}) of
                {ok, State} -> {ok, State};
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(stop, _From, #state{config_file=ConfigFile} = State) ->
    case file:consult(ConfigFile) of
        {ok, [{plugins, Plugins}]} ->
            lists:foreach(
              fun
                  ({application, App, _}) ->
                      catch stop_plugin(App);
                  (_) ->
                      ignore
              end, Plugins);
        _ ->
            ignore
    end,
    {reply, ok, State};
handle_call({register_app_plugin, Plugin, Opts}, _From,
            #state{plugins = Plugins} = State) ->
    PluginKey = {application, Plugin},
    case proplists:get_value(PluginKey, Plugins) of
        undefined ->
            case check_app_plugin(Plugin, Opts) of
                hooks_ok ->
                    NewPlugins = group_plugins_by_level([{PluginKey, Opts}| Plugins]),
                    write_plugin_config(State#state.config_file, NewPlugins),
                    {reply, ok, State#state{plugins = NewPlugins}};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        _ ->
            {reply, {error, already_registered}, State}
    end;
handle_call({register_module_plugin, HookName, Module, Fun, Arity, Level},
            _From, #state{plugins = Plugins} = State) ->
    PluginKey = {module, HookName, Module, Fun, Arity},
    case proplists:get_value(PluginKey, Plugins) of
        undefined ->
            case check_mfa(Module, Fun, Arity) of 
                plugin_ok ->
                    NewPlugins = group_plugins_by_level([{PluginKey, Level}|Plugins]),
                    write_plugin_config(State#state.config_file, NewPlugins),
                    {reply, ok, State#state{plugins = NewPlugins}};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        {PluginKey, Level} ->
            {reply, ok, State};
        _ ->
            {reply, {error, already_registered}, State}
    end;
handle_call(dump_plugins, _From, #state{plugins = Plugins} = State) ->
    {reply, Plugins, State};
handle_call({goto_runlevel, Level}, _From, #state{ready=true} = State) ->
    {Res, NewState} = goto_runlevel(Level, State),
    {reply, Res, NewState};
handle_call({goto_runlevel, _Level}, _From, State) ->
    {reply, {error, not_ready}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(ready, State) ->
    {ok, State#state{ready=true}};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


goto_runlevel(TargetLevel, #state{ready = true, runlevel = TargetLevel} = State) ->
    {ok, State};
goto_runlevel(TargetLevel, #state{ready = true} = State) ->
    case plugin_runlevel_diff(TargetLevel, State) of
        {start, Plugins} -> start_plugins(lists:reverse(Plugins));
        {stop, Plugins} -> stop_plugins(Plugins)
    end,
    compile_hooks(TargetLevel, State#state.plugins),
    {ok, State#state{runlevel = TargetLevel}}.

start_plugins([]) -> ok;
start_plugins([{{module, _,_,_,_},_}|T]) ->
    start_plugins(T);
start_plugins([{{application, App}, _}|T]) ->
    ok = start_plugin(App),
    ok = init_plugin_cli(App),
    start_plugins(T).

stop_plugins([]) -> ok;
stop_plugins([{{module, _,_,_,_},_}|T]) ->
    stop_plugins(T);
stop_plugins([{{application, _}, _}|T]) ->
    stop_plugin(T),
    stop_plugins(T).

plugin_runlevel_diff(TargetLevel, #state{runlevel = CurrLevel, plugins = Plugins}) ->
    CurrNum = proplists:get_value(CurrLevel, ?RUNLEVELS),
    TgtNum = proplists:get_value(TargetLevel, ?RUNLEVELS),
    case CurrNum < TgtNum of
        true ->
            StartLevels =
                lists:filter(fun({_Name, Num}) ->
                                     (CurrNum < Num) and (Num =< TgtNum)
                             end, ?RUNLEVELS),
            {start, filter_plugins(StartLevels, Plugins)};
        _ ->
            StopLevels = 
                lists:filter(fun({_Name, Num}) ->
                                     (TgtNum < Num) and (Num =< CurrNum)
                             end, ?RUNLEVELS),
            {stop, filter_plugins(StopLevels, Plugins)}
    end.

filter_plugins(RunLevels, Plugins) ->
    lists:filter(
      fun({{module, _,_,_,_}, Lvl}) ->
              lists:member(Lvl, RunLevels);
         ({{application, _}, #{level := Lvl}}) ->
              lists:member(Lvl, RunLevels)
      end, Plugins).

write_plugin_config(ConfigFile, Plugins) ->
    Data = io_lib:format("~p.", [{plugins, ?CONFIG_V1, Plugins}]),
    ok = file:write_file(ConfigFile, Data).

init_when_ready(MgrPid, RegisteredProcess) ->
    case whereis(RegisteredProcess) of
        undefined ->
            timer:sleep(10),
            init_when_ready(MgrPid, RegisteredProcess);
        _ ->
            MgrPid ! ready
    end.

wait_until_ready(#state{ready=false} = State) ->
    {ok, RegisteredProcess} = application:get_env(vmq_plugin, wait_for_proc),
    %% we start initializing the plugins as soon as
    %% the registered process is alive
    case whereis(RegisteredProcess) of
        undefined ->
            Self = self(),
            Pid = spawn_link(
                    fun() ->
                            init_when_ready(Self, RegisteredProcess)
                    end),
            {ok, State#state{ready={waiting, Pid}}};
        _ ->
            
            {ok, State#state{ready=true}}
    end.

read_config(ConfigFile) ->
    case file:consult(ConfigFile) of
        {ok, [{plugins, Plugins}]} ->
            %% convert old style config file to ?CONFIG_V1 style.
            lists:map(
              fun({application, Plugin, Opts}) ->
                      {{application, Plugin},
                       maps:merge(maps:from_list(Opts), #{level => system})};
                 ({module, Module, [{hooks, [{HookName, Fun, Arity}]}]}) ->
                      {{module, HookName, Module, Fun, Arity}, system}
              end,
              Plugins);
        {ok, [{plugins, ?CONFIG_V1, Plugins}]} ->
            lists:map(
              fun({{application, Plugin}, Opts}) ->
                      {{application, Plugin}, Opts};
                 ({{module, HookName, Module, Fun, Arity}, Level}) ->
                      {{module, HookName, Module, Fun, Arity}, Level}
              end,
              Plugins);
        {ok, _} ->
            {error, incorrect_plugin_config};
        {error, enoent} ->
            ok = write_plugin_config(ConfigFile, []);
        {error, Reason} ->
            {error, Reason}
    end.

get_level({{module, _,_,_,_}, Lvl}) ->
    Lvl;
get_level({{application, _}, #{level := Lvl}}) ->
    Lvl.

group_plugins_by_level(Plugins) ->
    lists:sort(
      fun(P1, P2) ->
              get_level(P1) >= get_level(P2)
      end,
      Plugins).

check_mfa(Module, Fun, Arity) ->
    case catch apply(Module, module_info, [exports]) of
        {'EXIT', _} ->
            {error, {unknown_module, Module}};
        Exports ->
            case lists:member({Fun, Arity}, Exports) of
                true ->
                    ok;
                false ->
                    {error, {no_matching_fun_in_module, Module, Fun, Arity}}
            end
    end.

start_plugin(App) ->
    case lists:keyfind(App, 1, application:which_applications()) of
        false ->
            case lists:keyfind(App, 1, application:loaded_applications()) of
                false ->
                    application:load(App);
                _ -> ok
            end,
            {ok, Mods} = application:get_key(App, modules),
            case lists:member(App, Mods) of
                true ->
                    %% does the App Module specifies a custom
                    %% start/1 function
                    case lists:member({start, 0}, apply(App, module_info, [exports])) of
                        true ->
                            apply(App, start, []);
                        false ->
                            {ok, _} = application:ensure_all_started(App)
                    end;
                false ->
                    {ok, _} = application:ensure_all_started(App)
            end,
            load_app_modules(App),
            ok;
        _ ->
            ok
    end.

init_plugin_cli(App) ->
    case code:priv_dir(App) of
        PrivDir ->
            case clique_config:load_schema(PrivDir) of
                {error, schema_files_not_found} ->
                    lager:debug("couldn't load cuttlefish schema for plugin: ~p", [App]);
                ok ->
                    ok
            end
    end.


stop_plugin(vmq_plugin) -> ok;
stop_plugin(App) ->
    case lists:member(App, erlang:loaded()) of
        true ->
            %% does the App Module specifies a custom
            %% stop/1 function
            case lists:member({stop, 0}, apply(App, module_info, [exports])) of
                true ->
                    apply(App, stop, []);
                false ->
                    application:stop(App)
            end;
        false ->
            application:stop(App)
    end,
    purge_app_modules(App),
    application:unload(App),
    ok.

check_app_plugin(App, #{paths := AppPaths}) ->
    case create_paths(App, AppPaths) of
        [] ->
            lager:debug("can't create paths ~p for app ~p~n", [AppPaths, App]),
            {error, plugin_not_found};
        Paths ->
            code:add_paths(Paths),
            load_application(App)
    end.

load_application(App) ->
    case application:load(App) of
        ok ->
            case find_mod_conflicts(App) of
                [] ->
                    check_app_hooks(App);
                [Err|_] ->
                    application:unload(App),
                    {error, {module_conflict, Err}}
            end;
        {error, {already_loaded, App}} ->
            check_app_hooks(App);
        E ->
            lager:debug("can't load application ~p", [E]),
            []
    end.

find_mod_conflicts(NewApp) ->
    LoadedApps = [A || {A,_,_} <- application:loaded_applications(), A =/= NewApp],
    {ok, NewMods} = application:get_key(NewApp, modules),
    find_mod_conflicts(NewMods, LoadedApps).

find_mod_conflicts(NewMods, LoadedApps) ->
    lists:filtermap(
      fun(App) ->
              {ok, Mods} = application:get_key(App, modules),
              case common_elems(NewMods, Mods) of
                  [] -> false;
                  [E|_] -> {true, {App, E}}
              end
      end, LoadedApps).

common_elems(L1, L2) ->
    S1=sets:from_list(L1), S2=sets:from_list(L2),
    sets:to_list(sets:intersection(S1,S2)).

create_paths(App, []) ->
    case application:load(App) of
        ok ->
            create_paths(App, [code:lib_dir(App)]);
        {error, {already_loaded, App}} ->
            create_paths(App, [code:lib_dir(App)]);
        _ ->
            []
    end;
create_paths(_, Paths) ->
    lists:flatmap(fun(Path) -> create_paths(Path) end, Paths).

create_paths(Path) ->
    case filelib:is_dir(Path) of
        true ->
            %% rebar2 directory structure support
            EbinDir = filelib:wildcard(filename:join(Path, "ebin")),
            DepsEbinDir = filelib:wildcard(filename:join(Path, "deps/*/ebin")),
            %% rebar3 directory structure support
            LibEbinDir = filelib:wildcard(filename:join(Path, "lib/*/ebin")),
            lists:append(LibEbinDir,lists:append(EbinDir, DepsEbinDir));
        false ->
            []
    end.

purge_app_modules(App) ->
    {ok, Modules} = application:get_key(App, modules),
    lager:debug("Purging modules: ~p", [Modules]),
    [code:purge(M) || M <- Modules].

load_app_modules(App) ->
    {ok, Modules} = application:get_key(App, modules),
    lager:info("Loading modules: ~p", [Modules]),
    [code:load_file(M) || M <- Modules].

check_app_hooks(App) ->
    Hooks = application:get_env(App, vmq_plugin_hooks, []),
    case check_app_hooks(App, Hooks) of
        hooks_ok ->
            hooks_ok;
        {error, Reason} ->
            {error, Reason}
    end.

check_app_hooks(App, [{Module, Fun, Arity}|Rest]) ->
    check_app_hooks(App, [{Module, Fun, Arity, []}|Rest]);
check_app_hooks(App, [{Module, Fun, Arity, Opts}|Rest])
  when is_list(Opts) ->
    check_app_hooks(App, [{Fun, Module, Fun, Arity, Opts}|Rest]);
check_app_hooks(App, [{HookName, Module, Fun, Arity}|Rest]) ->
    check_app_hooks(App, [{HookName, Module, Fun, Arity, []}|Rest]);
check_app_hooks(App, [{_HookName, Module, Fun, Arity, Opts}|Rest])
  when is_list(Opts) ->
    case check_mfa(Module, Fun, Arity) of
        ok ->
            check_app_hooks(App, Rest);
        {error, Reason} ->
            lager:debug("can't load specified hook module ~p in app ~p due to ~p",
                        [Module, App, Reason]),
            {error, Reason}
    end;
check_app_hooks(_, []) -> hooks_ok.

extract_hooks(CheckedPlugins) ->
    extract_hooks(CheckedPlugins, []).

extract_hooks([], Acc) ->
    lists:reverse(lists:flatten(Acc));
extract_hooks([{module, Name, Mod, Fun, Arity}|Rest], Acc) ->
    extract_hooks(Rest, [{Name, Mod, Fun, Arity} | Acc]);
extract_hooks([{application, Name}|Rest], Acc) ->
    case application:get_env(Name, vmq_plugin_hooks, []) of
        [] -> extract_hooks(Rest, Acc);
        Hooks -> extract_hooks(Rest, [extract_app_hooks(Hooks, []) | Acc])
    end.

extract_app_hooks([], Acc) -> Acc;
extract_app_hooks([{Mod, Fun, Arity}|Rest], Acc) ->
    extract_app_hooks(Rest, [{Fun, Mod, Fun, Arity, []}|Acc]);
extract_app_hooks([{Mod, Fun, Arity, Opts}|Rest], Acc) when is_list(Opts) ->
    extract_app_hooks(Rest, [{Fun, Mod, Fun, Arity, Opts}|Acc]);
extract_app_hooks([{H,M,F,A}|Rest], Acc) ->
    extract_app_hooks([{H,M,F,A,[]}|Rest], Acc);
extract_app_hooks([{H,M,F,A, Opts}|Rest], Acc) ->
    extract_app_hooks(Rest, [{H,M,F,A, Opts}|Acc]).

compile_hooks(TargetLevel, Plugins) ->
    TgtNum = proplists:get_value(TargetLevel, ?RUNLEVELS),
    Levels =
        lists:filter(fun({_Name, Num}) ->
                             Num =< TgtNum
                     end, ?RUNLEVELS),
    FilteredPlugins =
        filter_plugins(Levels, Plugins),
    compile_hooks(FilteredPlugins).

compile_hooks(Plugins) ->
    {PluginKeys, _Opts} = lists:unzip(Plugins),
    RawPlugins = extract_hooks(PluginKeys),
    Hooks = [{H,M,F,A} || {H,M,F,A,_} <-
                              lists:keysort(1, lists:flatten(RawPlugins))],
    M1 = smerl:new(vmq_plugin),
    {OnlyClauses, OnlyInfo} = only_clauses(1, Hooks, {nil, nil}, [], []),
    {ok, M2} = smerl:add_func(M1, {function, 1, only, 2, OnlyClauses}),
    {AllClauses, AllInfo} = all_clauses(1, Hooks, [], []),
    {ok, M3} = smerl:add_func(M2, {function, 1, all, 2, AllClauses}),
    AllTillOkClauses = all_till_ok_clauses(1, Hooks, []),
    {ok, M4} = smerl:add_func(M3, {function, 1, all_till_ok, 2, AllTillOkClauses}),
    InfoOnlyClause = info_only_clause(OnlyInfo),
    InfoAllClause = info_all_clause(AllInfo),
    InfoRawClause = info_raw_clause(PluginKeys),
    {ok, M5} = smerl:add_func(M4, {function, 1, info, 1, [InfoOnlyClause, InfoAllClause, InfoRawClause]}),
    smerl:compile(M5).

info_raw_clause(Hooks) ->
    {clause, 1,
     [{atom, 1, raw}],
     [],
     [erl_parse:abstract(Hooks)]
    }.
info_only_clause(Hooks) ->
    {clause, 1,
     [{atom, 1, only}],
     [],
     [list_const(true, Hooks)]
    }.
info_all_clause(Hooks) ->
    {clause, 2,
     [{atom, 1, all}],
     [],
     [list_const(true, Hooks)]
    }.

only_clauses(I, [{Name, _, _, Arity} | Rest], {Name, Arity} = Last, Acc, Info) ->
    %% we already serve this only-clause
    %% see head of Acc
    only_clauses(I, Rest, Last, Acc, Info);
only_clauses(I, [{Name, Module, Fun, Arity} = Hook | Rest], _, Acc, Info) ->
    Clause =
    clause(I, Name, Arity,
           [{call, 1, {atom, 1, apply},
             [{atom, 1, Module},
              {atom, 1, Fun},
              {var, 1, 'Params'}]
            }]),
    only_clauses(I + 1, Rest, {Name, Arity}, [Clause|Acc], [Hook|Info]);
only_clauses(I, [], _, Acc, Info) ->
    {lists:reverse([not_found_clause(I) | Acc]), lists:reverse(Info)}.

not_found_clause(I) ->
    {clause, I,
     [{var, 1, '_'}, {var, 1, '_'}],
     [],
     [{tuple, 1, [{atom, 1, error}, {atom, 1, no_matching_hook_found}]}]
    }.

all_clauses(I, [{Name, _, _, Arity} = Hook |Rest], Acc, Info) ->
    Hooks = [H || {N, _, _, A} = H <- Rest,
                  (N == Name) and (A == Arity)],
    Clause =
    clause(I, Name, Arity,
           [{call, 1, {atom, 1, apply},
             [{atom, 1, vmq_plugin_helper},
              {atom, 1, all},
              {cons, 1,
               list_const(false, [Hook|Hooks]),
               {cons, 1,
                {var, 1, 'Params'},
                {nil, 1}}}]
            }]),
    all_clauses(I + 1, Rest -- Hooks, [Clause|Acc], Info ++ [Hook|Hooks]);
all_clauses(I, [], Acc, Info) ->
    {lists:reverse([not_found_clause(I) | Acc]), Info}.


all_till_ok_clauses(I, [{Name, _, _, Arity} = Hook |Rest], Acc) ->
    Hooks = [H || {N, _, _, A} = H <- Rest,
                  (N == Name) and (A == Arity)],
    Clause =
    clause(I, Name, Arity,
           [{call, 1, {atom, 1, apply},
             [{atom, 1, vmq_plugin_helper},
              {atom, 1, all_till_ok},
              {cons, 1,
               list_const(false, [Hook|Hooks]),
               {cons, 1,
                {var, 1, 'Params'},
                {nil, 1}}}]
            }]),
    all_till_ok_clauses(I + 1, Rest -- Hooks, [Clause|Acc]);
all_till_ok_clauses(I, [], Acc) ->
    lists:reverse([not_found_clause(I) | Acc]).

clause(I, Name, Arity, Body) ->
    {clause, I,
     %% Function Header
     %% all(HookName, Params)
     %% only(HookName, Params)
     [{atom, 1, Name}, {var, 1, 'Params'}],
     %% Function Guard:
     %% all(HookName, Params) when is_list(Params)
     %%                            and (length(Params) == Arity) ->
     %% only(HookName, Params) when is_list(Params)
     %%                            and (length(Params) == Arity) ->
     [[{op, 1, 'and',
        {call, 1, {atom, 1, is_list},
         [{var, 1, 'Params'}]
        },
        {op, 1, '==',
         {call, 1, {atom, 1, length},
          [{var, 1, 'Params'}]
         },
         {integer, 1, Arity}
        }
       }]],
     %% Body
     Body}.

list_const(_, []) -> {nil, 1};
list_const(false, [{_, Module, Fun, _}|Rest]) ->
    {cons, 1,
     {tuple, 1,
      [{atom, 1, Module},
       {atom, 1, Fun}]
     }, list_const(false, Rest)};
list_const(true, [{Name, Module, Fun, Arity}|Rest]) ->
    {cons, 1,
     {tuple, 1,
      [{atom, 1, Name},
       {atom, 1, Module},
       {atom, 1, Fun},
       {integer, 1, Arity}]
     }, list_const(true, Rest)}.

-ifdef(TEST).
%%%===================================================================
%%% Tests
%%%===================================================================
sample_hook() ->
    io:format(user, "called sample_hook()~n", []),
    {sample_hook,0}.

sample_hook(A) ->
    io:format(user, "called sample_hook(~p)~n", [A]),
    {sample_hook,1,A}.

sample_hook(A, B) ->
    io:format(user, "called sample_hook(~p, ~p)~n", [A, B]),
    {sample_hook, 2, A, B}.

sample_hook(A, B, C) ->
    io:format(user, "called sample_hook(~p, ~p, ~p)~n", [A, B, C]),
    {sample_hook, 3, A, B, C}.

other_sample_hook_a(V) ->
    io:format(user, "called other_sample_hook_a(~p)~n", [V]),
    {other_sample_hook_a, 1, V}.

other_sample_hook_b(V) ->
    io:format(user, "called other_sample_hook_b(~p)~n", [V]),
    {other_sample_hook_b, 1, V}.

other_sample_hook_c(V) ->
    io:format(user, "called other_sample_hook_c(~p)~n", [V]),
    {other_sample_hook_c, 1, V}.

other_sample_hook_d(V) ->
    io:format(user, "called other_sample_hook_d(~p)~n", [V]),
    {error, not_ok}.

other_sample_hook_e(V) ->
    io:format(user, "called other_sample_hook_e(~p)~n", [V]),
    {error, not_ok}.

other_sample_hook_f(V) ->
    io:format(user, "called other_sample_hook_f(~p)~n", [V]),
    ok.

other_sample_hook_x(V) ->
    exit({other_sampl_hook_x_called_but_should_not, V}).


check_plugin_for_app_plugins_test() ->
    Hooks = [{?MODULE, sample_hook, 0, []},
             {?MODULE, sample_hook, 1, []},
             {?MODULE, sample_hook, 2, []},
             {?MODULE, sample_hook, 3, []},
             {sample_all_hook, ?MODULE, other_sample_hook_a, 1, []},
             {sample_all_hook, ?MODULE, other_sample_hook_b, 1, []},
             {sample_all_hook, ?MODULE, other_sample_hook_c, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_d, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_e, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_f, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_x, 1, []}
            ],
    application:load(vmq_plugin),
    application:set_env(vmq_plugin, vmq_plugin_hooks, Hooks),
    {ok, CheckedPlugins} = check_plugins([{application, vmq_plugin, []}], []),
    ?assertEqual([{application,vmq_plugin,
                  [{hooks,
                    [{vmq_plugin_mgr,sample_hook,0, []},
                     {vmq_plugin_mgr,sample_hook,1, []},
                     {vmq_plugin_mgr,sample_hook,2, []},
                     {vmq_plugin_mgr,sample_hook,3, []},
                     {sample_all_hook,vmq_plugin_mgr,other_sample_hook_a,1, []},
                     {sample_all_hook,vmq_plugin_mgr,other_sample_hook_b,1, []},
                     {sample_all_hook,vmq_plugin_mgr,other_sample_hook_c,1, []},
                     {sample_all_till_ok_hook,vmq_plugin_mgr, other_sample_hook_d,1, []},
                     {sample_all_till_ok_hook,vmq_plugin_mgr, other_sample_hook_e,1, []},
                     {sample_all_till_ok_hook,vmq_plugin_mgr, other_sample_hook_f,1, []},
                     {sample_all_till_ok_hook,vmq_plugin_mgr, other_sample_hook_x,1, []}]}]}],
                 CheckedPlugins),
    application:unload(vmq_plugin).

check_plugin_for_module_plugin_test() ->
    Plugins = [{module, ?MODULE, [{hooks, [{sample_hook1, sample_hook, 0},
                                           {sample_hook2, sample_hook, 1}]}]}],
    {ok, CheckedPlugins} = check_plugins(Plugins, []),
    ?assertEqual([{module, ?MODULE,
                   [{hooks, [{sample_hook1, sample_hook, 0},
                             {sample_hook2, sample_hook, 1}]}]}],
                 CheckedPlugins).

vmq_plugin_test() ->
    application:load(vmq_plugin),
    Hooks = [{?MODULE, sample_hook, 0, []},
             {?MODULE, sample_hook, 1, []},
             {?MODULE, sample_hook, 2, []},
             {?MODULE, sample_hook, 3, []},
             {sample_all_hook, ?MODULE, other_sample_hook_a, 1, []},
             {sample_all_hook, ?MODULE, other_sample_hook_b, 1, []},
             {sample_all_hook, ?MODULE, other_sample_hook_c, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_d, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_e, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_f, 1, []},
             {sample_all_till_ok_hook, ?MODULE, other_sample_hook_x, 1, []}
            ],
    application:set_env(vmq_plugin, vmq_plugin_hooks, Hooks),
    %% we have to step out .eunit
    application:set_env(vmq_plugin, plugin_dir, "."),
    {ok, _} = application:ensure_all_started(vmq_plugin),
    %% no plugin is yet registered
    call_no_hooks(),

    %% ENABLE PLUGIN
    ?assertEqual(ok, vmq_plugin_mgr:enable_plugin(
                       vmq_plugin,
                       ["./_build/test/lib/vmq_plugin"])),
    ?assert(lists:keyfind(vmq_plugin, 1, application:which_applications()) /= false),

    io:format(user, "info all ~p~n", [vmq_plugin:info(all)]),
    io:format(user, "info only ~p~n", [vmq_plugin:info(only)]),

    %% the plugins are sorted (stable) by the plugin name.
    ?assertEqual([{sample_all_hook,vmq_plugin_mgr,other_sample_hook_a,1},
                  {sample_all_hook,vmq_plugin_mgr,other_sample_hook_b,1},
                  {sample_all_hook,vmq_plugin_mgr,other_sample_hook_c,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_d,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_e,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_f,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_x,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,0},
                  {sample_hook,vmq_plugin_mgr,sample_hook,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,2},
                  {sample_hook,vmq_plugin_mgr,sample_hook,3}], vmq_plugin:info(all)),

    %% the plugins are sorted (stable) by the plugin name.
    ?assertEqual([{sample_all_hook,vmq_plugin_mgr,other_sample_hook_a,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_d,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,0},
                  {sample_hook,vmq_plugin_mgr,sample_hook,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,2},
                  {sample_hook,vmq_plugin_mgr,sample_hook,3}], vmq_plugin:info(only)),

    call_hooks(),

    %% Disable Plugin
    ?assertEqual(ok, vmq_plugin_mgr:disable_plugin(vmq_plugin)),
    %% no plugin is registered
    call_no_hooks().

vmq_module_plugin_test() ->
    application:load(vmq_plugin),
    application:set_env(vmq_plugin, plugin_dir, ".."),

    {ok, _} = application:ensure_all_started(vmq_plugin),
    call_no_hooks(),
    vmq_plugin_mgr:enable_module_plugin(?MODULE, sample_hook, 0),
    vmq_plugin_mgr:enable_module_plugin(?MODULE, sample_hook, 1),
    vmq_plugin_mgr:enable_module_plugin(?MODULE, sample_hook, 2),
    vmq_plugin_mgr:enable_module_plugin(?MODULE, sample_hook, 3),
    vmq_plugin_mgr:enable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_a, 1),
    vmq_plugin_mgr:enable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_b, 1),
    vmq_plugin_mgr:enable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_c, 1),
    %% ordering matters, we don't want other_sample_hook_x to be called
    vmq_plugin_mgr:enable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_d, 1),
    vmq_plugin_mgr:enable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_e, 1),
    vmq_plugin_mgr:enable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_f, 1),
    vmq_plugin_mgr:enable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_x, 1),

    %% the plugins are sorted (stable) by the plugin name.
    ?assertEqual([{sample_all_hook,vmq_plugin_mgr,other_sample_hook_a,1},
                  {sample_all_hook,vmq_plugin_mgr,other_sample_hook_b,1},
                  {sample_all_hook,vmq_plugin_mgr,other_sample_hook_c,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_d,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_e,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_f,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_x,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,0},
                  {sample_hook,vmq_plugin_mgr,sample_hook,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,2},
                  {sample_hook,vmq_plugin_mgr,sample_hook,3}], vmq_plugin:info(all)),

    %% the plugins are sorted (stable) by the plugin name.
    ?assertEqual([{sample_all_hook,vmq_plugin_mgr,other_sample_hook_a,1},
                  {sample_all_till_ok_hook,vmq_plugin_mgr,other_sample_hook_d,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,0},
                  {sample_hook,vmq_plugin_mgr,sample_hook,1},
                  {sample_hook,vmq_plugin_mgr,sample_hook,2},
                  {sample_hook,vmq_plugin_mgr,sample_hook,3}], vmq_plugin:info(only)),

    call_hooks(),

    % disable hooks
    vmq_plugin_mgr:disable_module_plugin(?MODULE, sample_hook, 0),
    vmq_plugin_mgr:disable_module_plugin(?MODULE, sample_hook, 1),
    vmq_plugin_mgr:disable_module_plugin(?MODULE, sample_hook, 2),
    vmq_plugin_mgr:disable_module_plugin(?MODULE, sample_hook, 3),
    vmq_plugin_mgr:disable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_a, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_b, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_hook, ?MODULE, other_sample_hook_c, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_d, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_e, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_f, 1),
    vmq_plugin_mgr:disable_module_plugin(sample_all_till_ok_hook, ?MODULE, other_sample_hook_x, 1),
    call_no_hooks().

call_no_hooks() ->
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(sample_hook, [])),
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(sample_hook, [1])),
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(sample_hook, [1, 2])),
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(sample_hook, [1, 2, 3])).


call_hooks() ->
    %% ONLY HOOK Tests
    ?assertEqual({sample_hook, 0}, vmq_plugin:only(sample_hook, [])),
    ?assertEqual({sample_hook, 1, 1}, vmq_plugin:only(sample_hook, [1])),
    ?assertEqual({sample_hook, 2, 1, 2}, vmq_plugin:only(sample_hook, [1, 2])),
    ?assertEqual({sample_hook, 3, 1, 2, 3}, vmq_plugin:only(sample_hook, [1, 2, 3])),

    %% call hook with wrong arity
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(sample_hook, [1, 2, 3, 4])),
    %% call unknown hook
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:only(unknown_hook, [])),

    %% ALL HOOK Tests
    ?assertEqual([{sample_hook, 0}], vmq_plugin:all(sample_hook, [])),

    %% call hook with wrong arity
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:all(sample_hook, [1, 2, 3, 4])),

    %% call unknown hook
    ?assertEqual({error, no_matching_hook_found},
                 vmq_plugin:all(unknown_hook, [])),

    %% hook order
    ?assertEqual([{other_sample_hook_a, 1, 10},
                  {other_sample_hook_b, 1, 10},
                  {other_sample_hook_c, 1, 10}], vmq_plugin:all(sample_all_hook, [10])),

    %% ALL_TILL_OK Hook Tests
    ?assertEqual(ok, vmq_plugin:all_till_ok(sample_all_till_ok_hook, [10])).
-endif.
