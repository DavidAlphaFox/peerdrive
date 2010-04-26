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

-module(file_store_reader).
-behaviour(gen_server).

-export([start/4]).
-export([read/4, done/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).

-include("store.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public interface...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(StorePid, Path, Parts, User) ->
	case gen_server:start(?MODULE, {StorePid, Path, Parts, User}, []) of
		{ok, Pid} ->
			{ok, #reader{
				this      = Pid,
				read_part = fun read/4,
				done      = fun done/1
			}};
		Else ->
			Else
	end.


read(Reader, Part, Offset, Length) ->
	gen_server:call(Reader, {read, Part, Offset, Length}).

done(Reader) ->
	gen_server:cast(Reader, done).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Callbacks...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({StorePid, Path, Parts, User}) ->
	case open_part_list(Path, Parts) of
		{error, Reason} ->
			{stop, Reason};
		Handles ->
			process_flag(trap_exit, true),
			link(StorePid),
			link(User),
			{ok, Handles}
	end.

% returns: {ok, Data} | eof | {error, Reason}
handle_call({read, Part, Offset, Length}, _From, Handles) ->
	Reply = case dict:find(Part, Handles) of
		{ok, Handle} -> file:pread(Handle, Offset, Length);
		error        -> {error, enoent}
	end,
	{reply, Reply, Handles}.

handle_cast(done, Handles) ->
	{stop, normal, Handles}.

terminate(_Reason, Handles) ->
	close_part_list(Handles).

handle_info({'EXIT', _From, _Reason}, S) ->
	{stop, orphaned, S}.

code_change(_, State, _) -> {ok, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Local functions...
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Open all parts.
%
% `Parts' is a list of `{FourCC, Hash}' pairs. The function either returns a dict
% which maps FourCC's to open IODevice's or `{error, Reason}' when a error happens.
open_part_list(Path, Parts) ->
	open_part_list_loop(Path, Parts, dict:new()).
open_part_list_loop(_, [], Handles) ->
	Handles;
open_part_list_loop(Path, [{Id, Hash} | Parts], Handles1) ->
	case file:open(util:build_path(Path, Hash), [read, binary]) of
		{ok, IoDevice} ->
			Handles2 = dict:store(Id, IoDevice, Handles1),
			open_part_list_loop(Path, Parts, Handles2);
		{error, Reason} ->
			close_part_list(Handles1), % close what was opened so far
			{error, Reason}            % and return the error
	end.

close_part_list(Handles1) ->
	Handles2 = dict:to_list(Handles1),
	lists:foreach(fun({_, File}) -> file:close(File) end, Handles2).
