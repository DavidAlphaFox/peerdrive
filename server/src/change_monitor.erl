%% Hotchpotch
%% Copyright (C) 2010  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
%%
%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(change_monitor).
-behaviour(gen_server).

-export([watch/2, unwatch/2, remove/0]).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).

% watches:  dict: {Type, Guid} --> {set(Store), set(pid())}
-record(state, {watches}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	gen_server:start_link({local, change_monitor}, ?MODULE, [], []).

%% @doc Start watching a GUID's (UUID or Rev). If a match occurs the
%%      calling process will receive the following message:
%%
%%      {watch, Cause, Type, Guid} where
%%          Cause = modified | appeared | replicated | diminished | disappeared
%%          Type  = uuid | rev
%%          Guid  = guid()
%%
%% @spec watch(Type, Guid) -> ok
%%       Type = uuid | rev
%%       Guid = guid()
watch(Type, Guid) ->
	gen_server:call(change_monitor, {watch, Type, Guid}).

%% @doc Stop watching a GUID (UUID or Rev).
%% @spec unwatch(Type, Guid) -> ok
%%       Type = uuid | rev
%%       Guid = guid()
unwatch(Type, Guid) ->
	gen_server:call(change_monitor, {unwatch, Type, Guid}).

%% @doc Remove all watch hooks of the calling process.
remove() ->
	gen_server:call(change_monitor, remove).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks implementation...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


init([]) ->
	process_flag(trap_exit, true),
	vol_monitor:register_proc(change_monitor),
	{ok, #state{watches=dict:new()}}.


handle_info({trigger_mod_uuid, Store, Uuid}, #state{watches=Watches} = State) ->
	% This is a special trigger. Only forward special locally generated events.
	% This prevents useless flooding of change notifications if the UUID exists
	% on several stores.
	case Store of
		local ->
			case dict:find({uuid, Uuid}, Watches) of
				{ok, {_StoreSet, PidSet}} ->
					fire_trigger(modified, uuid, Uuid, PidSet);
				error ->
					ok
			end,
			{noreply, State};

		_Else ->
			{noreply, State}
	end;

handle_info({trigger_add_rev, Store, Rev}, #state{watches=Watches} = State) ->
	NewWatches = trigger_inc(rev, Store, Rev, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({trigger_rm_rev, Store, Rev}, #state{watches=Watches} = State) ->
	NewWatches = trigger_dec(rev, Store, Rev, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({trigger_add_uuid, Store, Uuid}, #state{watches=Watches} = State) ->
	NewWatches = trigger_inc(uuid, Store, Uuid, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({trigger_rm_uuid, Store, Uuid}, #state{watches=Watches} = State) ->
	NewWatches = trigger_dec(uuid, Store, Uuid, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({trigger_add_store, Store}, #state{watches=Watches} = State) ->
	NewWatches = trigger_add_store(Store, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({trigger_rem_store, Store}, #state{watches=Watches} = State) ->
	NewWatches = trigger_rem_store(Store, Watches),
	{noreply, State#state{watches=NewWatches}};

handle_info({'EXIT', From, Reason}, S) ->
	case Reason of
		normal   -> {noreply, S};
		shutdown -> {noreply, S};
		_ ->
			{reply, ok, S2} = handle_call(remove, {From, 0}, S),
			{noreply, S2}
	end.


handle_call({watch, Type, Guid}, From, #state{watches=Watches} = S) ->
	{Client, _} = From,
	link(Client),
	Key = {Type, Guid},
	NewWatches = case dict:find(Key, Watches) of
		{ok, {StoreSet, PidSet}} ->
			NewPidSet = sets:add_element(Client, PidSet),
			dict:store(Key, {StoreSet, NewPidSet}, Watches);

		error ->
			NewPidSet = sets:add_element(Client, sets:new()),
			NewStoreSet =  case Type of
				uuid -> uuid_population(Guid);
				rev  -> rev_population(Guid)
			end,
			dict:store(Key, {NewStoreSet, NewPidSet}, Watches)
	end,
	{reply, ok, S#state{watches=NewWatches}};

handle_call({unwatch, Type, Guid}, From, #state{watches=Watches} = S) ->
	{Client, _} = From,
	Key = {Type, Guid},
	NewWatches = case dict:find(Key, Watches) of
		{ok, {StoreSet, PidSet}} ->
			NewPidSet = sets:del_element(Client, PidSet),
			case sets:size(NewPidSet) of
				0 -> dict:erase(Key, Watches);
				_ -> dict:store(Key, {StoreSet, NewPidSet}, Watches)
			end;

		error ->
			Watches
	end,
	{reply, ok, S#state{watches=NewWatches}};

handle_call(remove, From, #state{watches=Watches} = S) ->
	{Client, _} = From,
	unlink(Client),
	Watches1 = dict:map(
		fun (_, {StoreSet, PidSet}) ->
			{StoreSet, sets:del_element(Client, PidSet)}
		end,
		Watches),
	Watches2 = dict:filter(
		fun (_, {_StoreSet, PidSet}) ->
			sets:size(PidSet) > 0
		end,
		Watches1),
	{reply, ok, S#state{watches=Watches2}}.


handle_cast(_Request, State) -> {noreply, State}.
code_change(_, State, _) -> {ok, State}.
terminate(_, _)          -> ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Synchronous helpers...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% check all stores if they contain a certain UUID
uuid_population(Uuid) ->
	Stores = volman:stores(),
	lists:foldl(
		fun({StoreGuid, StoreIfc}, Acc) ->
			case store:lookup(StoreIfc, Uuid) of
				{ok, _Rev} -> sets:add_element(StoreGuid, Acc);
				error      -> Acc
			end
		end,
		sets:new(),
		Stores).


% check all stores if they contain a certain revision
rev_population(Rev) ->
	Stores = volman:stores(),
	lists:foldl(
		fun({StoreGuid, StoreIfc}, Acc) ->
			case store:contains(StoreIfc, Rev) of
				true  -> sets:add_element(StoreGuid, Acc);
				false -> Acc
			end
		end,
		sets:new(),
		Stores).


trigger_inc(Type, Store, Hash, Watches) ->
	Key = {Type, Hash},
	case dict:find(Key, Watches) of
		{ok, {StoreSet, PidSet}} ->
			NewStoreSet = sets:add_element(Store, StoreSet),
			case sets:size(NewStoreSet) of
				1 -> fire_trigger(appeared, Type, Hash, PidSet);
				_ -> fire_trigger(replicated, Type, Hash, PidSet)
			end,
			dict:store(Key, {NewStoreSet, PidSet}, Watches);

		error ->
			Watches
	end.


trigger_dec(Type, Store, Hash, Watches) ->
	Key = {Type, Hash},
	case dict:find(Key, Watches) of
		{ok, {StoreSet, PidSet}} ->
			NewStoreSet = sets:del_element(Store, StoreSet),
			case sets:size(NewStoreSet) of
				0 -> fire_trigger(disappeared, Type, Hash, PidSet);
				_ -> fire_trigger(diminished, Type, Hash, PidSet)
			end,
			dict:store(Key, {NewStoreSet, PidSet}, Watches);

		error ->
			Watches
	end.


trigger_add_store(StoreGuid, Watches) ->
	case volman:store(StoreGuid) of
		{ok, StoreIfc} ->
			dict:map(
				fun({Type, Hash}, {StoreSet, PidSet}) ->
					case Type of
						uuid ->
							case store:lookup(StoreIfc, Hash) of
								{ok, _Rev} ->
									case sets:size(StoreSet) of
										0 -> fire_trigger(appeared, uuid, Hash, PidSet);
										_ -> fire_trigger(replicated, uuid, Hash, PidSet)
									end,
									{sets:add_element(StoreGuid, StoreSet), PidSet};

								error ->
									{StoreSet, PidSet}
							end;

						rev ->
							case store:contains(StoreIfc, Hash) of
								true ->
									case sets:size(StoreSet) of
										0 -> fire_trigger(appeared, rev, Hash, PidSet);
										_ -> fire_trigger(replicated, rev, Hash, PidSet)
									end,
									{sets:add_element(StoreGuid, StoreSet), PidSet};

								false ->
									{StoreSet, PidSet}
							end
					end
				end,
				Watches);
				
		error ->
			% already gone :o
			Watches
	end.


trigger_rem_store(StoreGuid, Watches) ->
	dict:map(
		fun({Type, Hash}, {StoreSet, PidSet}) ->
			case sets:is_element(StoreGuid, StoreSet) of
				true ->
					NewStoreSet = sets:del_element(StoreGuid, StoreSet),
					case sets:size(NewStoreSet) of
						0 -> fire_trigger(disappeared, Type, Hash, PidSet);
						_ -> fire_trigger(diminished, Type, Hash, PidSet)
					end,
					{NewStoreSet, PidSet};

				false ->
					{StoreSet, PidSet}
			end
		end,
		Watches).


fire_trigger(Cause, Type, Hash, Pids) ->
	%io:format("trigger: ~w ~w ~s~n", [Cause, Type, util:bin_to_hexstr(Hash)]),
	lists:foreach(
		fun (Pid) -> Pid ! {watch, Cause, Type, Hash} end,
		sets:to_list(Pids)).
