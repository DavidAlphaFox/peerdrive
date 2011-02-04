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

-module(servlet_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([spawn_servlet/2]).
-export([init/1]).

start_link(Id, Module, ServletOpt) ->
	supervisor:start_link({local, Id}, ?MODULE, {Module, ServletOpt}).

init({Module, ServletOpt}) ->
	{ok, {
		{simple_one_for_one, 1, 10},
		[{servlet, {gen_servlet, start_link, [Module, ServletOpt]}, transient, brutal_kill, worker, []}]
	}}.

spawn_servlet(SupervisorPid, ListenSock) ->
	supervisor:start_child(SupervisorPid, [self(), ListenSock]).

