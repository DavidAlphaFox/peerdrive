%% PeerDrive
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

-module(peerdrive_worker_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	RestartStrategy    = one_for_one,
	MaxRestarts        = 1,
	MaxTimeBetRestarts = 60,

	ChildSpecs = [
		{
			peerdrive_work_tags,
			{peerdrive_work_tags, start_link, []},
			permanent,
			1000,
			worker,
			[peerdrive_work_tags]
		},
		{
			peerdrive_work_monitor,
			{peerdrive_work_monitor, start_link, []},
			permanent,
			1000,
			worker,
			[peerdrive_work_monitor]
		},
		{
			peerdrive_replicator,
			{peerdrive_replicator, start_link, []},
			permanent,
			infinity,
			supervisor,
			[peerdrive_replicator]
		},
		{
			peerdrive_synchronizer,
			{peerdrive_synchronizer, start_link, []},
			permanent,
			infinity,
			supervisor,
			[peerdrive_synchronizer]
		},
		{
			peerdrive_dispatcher,
			{peerdrive_dispatcher, start_link, []},
			permanent,
			1000,
			worker,
			[peerdrive_dispatcher]
		}
	],

	{ok, {{RestartStrategy, MaxRestarts, MaxTimeBetRestarts}, ChildSpecs}}.

