%% Hotchpotch
%% Copyright (C) 2011  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
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

-module(revcache).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, terminate/2]).

start_link() ->
	gen_server:start_link({local, revcache}, ?MODULE, [], []).



init([]) ->
	{ok, dummy_state}.


handle_info(_Info, State) -> {noreply, State}.
handle_call(_Request, _From, State) -> {noreply, State}.
handle_cast(_Request, State) -> {noreply, State}.
code_change(_, State, _) -> {ok, State}.
terminate(_, _) -> ok.

