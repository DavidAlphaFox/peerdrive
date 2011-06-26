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

-module(hotchpotch_ifc_vfs_common).

-export([init/1, getattr/2, lookup/3, forget/3, open/4, create/6, opendir/2,
	close/2, read/4, write/4, readdir/2, setattr/3, unlink/3, rename/5, link/4,
	mkdir/3, statfs/2]).

-include("store.hrl").
-include("vfs.hrl").

-define(VFS_CC, <<"org.hotchpotch.vfs">>).  % creator code

%% inode: integer number identifying a vnode
%% vnode: structure describing the file system object
%% OID: object identifier for hotchpotch doc/rev:
%%      {doc, Store::guid(), Doc::guid()} | {rev, Store::guid(), Rev::guid()}

-record(state, {
	inodes,  % gb_trees: inode -> #vnode
	imap,    % gb_trees: OID -> inode
	count    % int: next free inode
}).

-record(vnode, {
	refcnt,  % int:  how many time lookup'ed by fuse (reference count)
	parent,  % int:  parent inode
	timeout, % int:  timeout of this node's information in ms
	ifc,     % #ifc: file system functions of node
	oid,     % term: information to find corresponding hotchpotch object
	cache    % private information of #ifc functions
}).

-record(ifc, {
	getattr,
	truncate = fun(_, _) -> {error, enosys} end,
	lookup   = fun(_, _, _) -> {error, enoent} end,
	getnode  = fun(_, _) -> error end,
	readdir  = fun(_, _) -> {errror, eio} end,
	open     = fun(_, _, _) -> {error, eisdir} end,
	create   = fun(_, _, _, _) -> {error, enotdir} end,
	link     = fun(_, _, _, _) -> {error, enotdir} end,
	unlink   = fun(_, _, _) -> {error, eacces} end,
	mkdir    = fun(_, _, _) -> {error, enotdir} end,
	rename   = fun(_, _, _, _) -> {error, enotdir} end
}).

-record(handler, {read, write, release, changed=false, rewritten=false}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public interface
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Options) ->
	put(dir_type, proplists:get_value(dir_type, Options, set)),
	#state{
		inodes = gb_trees:from_orddict([ {1, root_make_node() } ]),
		imap   = gb_trees:empty(),
		count  = 2 % 1 is the root inode
	}.


getattr(Ino, #state{inodes=Inodes} = S) ->
	#vnode{
		oid     = Oid,
		timeout = Timeout,
		ifc     = #ifc{getattr=GetAttr}
	} = gb_trees:get(Ino, Inodes),
	case catch GetAttr(Oid) of
		{ok, Attr} ->
			{ok, {Attr, Timeout}, S};

		{error, Reason} ->
			{error, Reason, S}
	end.


lookup(Parent, Name, S) ->
	LookupOp = fun(ParentNode) ->
		#vnode{oid=Oid, ifc=#ifc{lookup=Lookup}, cache=Cache} = ParentNode,
		Lookup(Oid, Name, Cache)
	end,
	case do_lookup(Parent, LookupOp, S) of
		{ok, ChildIno, ChildNode, ParentTimeout, S2} ->
			case make_entry(ChildIno, ChildNode, ParentTimeout) of
				{ok, Entry} ->
					{ok, Entry, S2};

				error ->
					{error, enoent, do_forget(ChildIno, 1, S2)}
			end;

		{error, _Error, _S2} = Error ->
			Error
	end.


forget(Ino, N, S) ->
	{ok, ok, do_forget(Ino, N, S)}.


open(Ino, Trunc, Mode, #state{inodes=Inodes} = S) ->
	#vnode{oid=Oid, ifc=#ifc{open=Open}} = gb_trees:get(Ino, Inodes),
	case catch Open(Oid, Trunc, Mode) of
		{ok, Handler} ->
			{ok, Handler, S};

		{error, Error} ->
			{error, Error, S}
	end.


create(Parent, Name, MustCreate, Trunc, Mode, S) ->
	LookupOp = fun(ParentNode) ->
		#vnode{oid=Oid, ifc=#ifc{create=Create}, cache=Cache} = ParentNode,
		Create(Oid, Name, Cache, MustCreate)
	end,
	case do_lookup(Parent, LookupOp, S) of
		{ok, ChildIno, ChildNode, ParentTimeout, S2} ->
			case make_entry(ChildIno, ChildNode, ParentTimeout) of
				{ok, Entry} ->
					case open(ChildIno, Trunc, Mode, S2) of
						{ok, Handler, S3} ->
							% FIXME: return correct 'Existed' attribute
							{ok, {Entry, false, Handler}, S3};
						{error, Reason, S3} ->
							{error, Reason, do_forget(ChildIno, 1, S3)}
					end;

				error ->
					{error, enoent, do_forget(ChildIno, 1, S2)}
			end;

		{error, _Error, _S2} = Error ->
			Error
	end.


opendir(Ino, S) ->
	case getattr(Ino, S) of
		{ok, {#vfs_attr{dir=true}, _Timeout}, S2} ->
			{ok, Ino, S2};
		{ok, _, S2} ->
			{error, enotdir, S2};
		Error ->
			Error
	end.


close(_S, #handler{release=Release, changed=Changed, rewritten=Rewritten}) ->
	Release(Changed, Rewritten),
	{ok, ok};

close(_S, _Handler) ->
	{ok, ok}.


read(_S, #handler{read=Read}, Size, Offset) ->
	case catch Read(Size, Offset) of
		{ok, Data} -> {ok, Data};
		{error, Error} -> {error, Error}
	end;

read(_S, _Handle, _Size, _Offset) ->
	{error, ebadf}.


write(S, #handler{} = Handler, Data, Offset) ->
	#handler{
		write     = Write,
		changed   = Changed,
		rewritten = Rewritten
	} = Handler,
	case catch Write(Data, Offset) of
		ok ->
			if
				Changed and (Rewritten or (Offset > 0)) ->
					{ok, size(Data)};
				true ->
					NewHandler = Handler#handler{
						changed   = true,
						rewritten = Rewritten or (Offset == 0)
					},
					{ok, size(Data), S, NewHandler}
			end;

		{error, _Reason} = Error ->
			Error
	end;

write(_S, _Handle, _Data, _Offset) ->
	{error, ebadf}.


readdir(#state{inodes=Inodes} = S, Ino) when is_integer(Ino) ->
	#vnode{
		oid    = Oid,
		ifc    = #ifc{readdir=ReadDir},
		cache  = Cache
	} = Node = gb_trees:get(Ino, Inodes),
	case catch ReadDir(Oid, Cache) of
		{ok, Entries, NewCache} ->
			AllEntries = [
				#vfs_direntry{name= <<".">>,  attr=#vfs_attr{dir=true, size=0}},
				#vfs_direntry{name= <<"..">>, attr=#vfs_attr{dir=true, size=0}}
			] ++ Entries,
			S2 = S#state{
				inodes = gb_trees:update(Ino, Node#vnode{cache=NewCache}, Inodes)
			},
			{ok, AllEntries, S2, AllEntries};

		{error, Error, NewCache} ->
			S2 = S#state{
				inodes = gb_trees:update(Ino, Node#vnode{cache=NewCache}, Inodes)
			},
			{error, Error, S2, Ino};

		{error, Error} ->
			{error, Error}
	end;

readdir(_S, Listing) when is_list(Listing) ->
	{ok, Listing};

readdir(_S, _Handle) ->
	{error, ebadf}.


setattr(Ino, Changes, #state{inodes=Inodes} = S) ->
	#vnode{
		oid     = Oid,
		timeout = Timeout,
		ifc     = #ifc{getattr=GetAttr, truncate=Truncate}
	} = gb_trees:get(Ino, Inodes),
	try
		Attr1 = case proplists:get_value(size, Changes) of
			undefined ->
				case GetAttr(Oid) of
					{ok, TmpAttr} -> TmpAttr;
					Error         -> throw(Error)
				end;
			NewSize when is_integer(NewSize) ->
				case Truncate(Oid, NewSize) of
					{ok, TmpAttr} -> TmpAttr;
					Error         -> throw(Error)
				end
		end,
		Attr2 = case proplists:get_value(atime, Changes) of
			undefined ->
				Attr1;
			NewATime when is_integer(NewATime) ->
				Attr1#vfs_attr{atime=NewATime}
		end,
		Attr3 = case proplists:get_value(mtime, Changes) of
			undefined ->
				Attr2;
			NewMTime when is_integer(NewMTime) ->
				Attr2#vfs_attr{mtime=NewMTime}
		end,
		Attr4 = case proplists:get_value(ctime, Changes) of
			undefined ->
				Attr3;
			NewCTime when is_integer(NewCTime) ->
				Attr3#vfs_attr{ctime=NewCTime}
		end,
		{ok, {Attr4, Timeout}, S}

	catch
		throw:{error, Reason} -> {error, Reason, S}
	end.


rename(Parent, OldName, Parent, NewName, S) ->
	Inodes = S#state.inodes,
	#vnode{
		oid   = ParentOid,
		ifc   = #ifc{rename=Rename},
		cache = ParentCache
	} = ParentNode = gb_trees:get(Parent, Inodes),
	case catch Rename(ParentOid, OldName, NewName, ParentCache) of
		{ok, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{ok, ok, S2};

		{error, Error, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{error, Error, S2};

		{error, Error} ->
			{error, Error, S}
	end;

rename(OldParent, OldName, NewParent, NewName, S) ->
	Inodes = S#state.inodes,
	#vnode{
		oid   = OldOid,
		ifc   = #ifc{lookup=Lookup},
		cache = OldCache1
	} = OldParentNode = gb_trees:get(OldParent, Inodes),

	case catch Lookup(OldOid, OldName, OldCache1) of
		{entry, ChildOid, OldCache2} ->
			#vnode{oid=NewOid, ifc=#ifc{link=NewLink}} =
				gb_trees:get(NewParent, Inodes),

			% first link in new parent
			case catch NewLink(NewOid, ChildOid, NewName, OldCache2) of
				{ok, OldCache3} ->
					S2 = S#state{inodes=gb_trees:update(OldParent,
						OldParentNode#vnode{cache=OldCache3}, Inodes)},
					% then unlink form old parent
					unlink(OldParent, OldName, S2);

				{error, Error, OldCache3} ->
					S2 = S#state{inodes=gb_trees:update(OldParent,
						OldParentNode#vnode{cache=OldCache3}, Inodes)},
					{error, Error, S2};

				{error, Error} ->
					S2 = S#state{inodes=gb_trees:update(OldParent,
						OldParentNode#vnode{cache=OldCache2}, Inodes)},
					{error, Error, S2}
			end;

		{error, Error, OldCache2} ->
			S2 = S#state{inodes=gb_trees:update(OldParent,
				OldParentNode#vnode{cache=OldCache2}, Inodes)},
			{error, Error, S2};

		{error, Error} ->
			{error, Error, S}
	end.


link(Ino, NewParent, NewName, S) ->
	Inodes = S#state.inodes,
	#vnode{oid=ChildOid} = gb_trees:get(Ino, Inodes),
	#vnode{
		oid     = ParentOid,
		ifc     = #ifc{link=Link},
		cache   = ParentCache,
		timeout = Timeout
	} = ParentNode = gb_trees:get(NewParent, Inodes),
	case catch Link(ParentOid, ChildOid, NewName, ParentCache) of
		{ok, NewCache} ->
			Lookup = fun(_) -> {entry, ChildOid, NewCache} end,
			case do_lookup(NewParent, Lookup, S) of
				{ok, ChildIno, ChildNode, Timeout, S2} ->
					case make_entry(ChildIno, ChildNode, Timeout) of
						{ok, Entry} ->
							{ok, Entry, S2};

						error ->
							{error, enoent, do_forget(ChildIno, 1, S2)}
					end;

				{error, Error, S2} ->
					{error, Error, S2}
			end;

		{error, Error, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(NewParent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{error, Error, S2};

		{error, Error} ->
			{error, Error, S}
	end.


unlink(Parent, Name, S) ->
	Inodes = S#state.inodes,
	#vnode{
		oid   = Oid,
		ifc   = #ifc{unlink=Unlink},
		cache = Cache
	} = ParentNode = gb_trees:get(Parent, Inodes),
	case catch Unlink(Oid, Name, Cache) of
		{ok, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{ok, ok, S2};

		{error, Error, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{error, Error, S2};

		{error, Error} ->
			{error, Error, S}
	end.


mkdir(Parent, Name, S) ->
	Inodes = S#state.inodes,
	#vnode{
		oid     = ParentOid,
		ifc     = #ifc{mkdir=MkDir, getnode=GetNode},
		cache   = ParentCache,
		timeout = Timeout
	} = ParentNode = gb_trees:get(Parent, Inodes),
	case catch MkDir(ParentOid, Name, ParentCache) of
		{ok, ChildOid, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			case do_lookup_new(Parent, ChildOid, GetNode, Timeout, S2) of
				{ok, ChildIno, ChildNode, Timeout, S3} ->
					case make_entry(ChildIno, ChildNode, Timeout) of
						{ok, Entry} ->
							{ok, Entry, S3};

						error ->
							{error, enoent, do_forget(ChildIno, 1, S3)}
					end;

				{error, Error, S3} ->
					{error, Error, S3}
			end;

		{error, Error, NewCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewCache}, Inodes)},
			{error, Error, S2};

		{error, Error} ->
			{error, Error, S}
	end.


statfs(Ino, S) ->
	#vnode{oid=Oid} = gb_trees:get(Ino, S#state.inodes),
	Reply = case Oid of
		{doc, Store, _Doc} ->
			case hotchpotch_volman:store(Store) of
				{ok, Pid} -> hotchpotch_store:statfs(Pid);
				error     -> {error, enoent}
			end;
		{rev, Store, _Rev} ->
			case hotchpotch_volman:store(Store) of
				{ok, Pid} -> hotchpotch_store:statfs(Pid);
				error     -> {error, enoent}
			end;
		_ ->
			{ok, #fs_stat{
				bsize  = 512,
				blocks = 2048,
				bfree  = 2048,
				bavail = 2048
			}}
	end,
	case Reply of
		{ok, Stat}      -> {ok, Stat, S};
		{error, Reason} -> {error, Reason, S}
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Common local functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


do_lookup(Parent, LookupOp, S) ->
	#state{inodes=Inodes, imap=IMap} = S,
	ParentNode = gb_trees:get(Parent, Inodes),
	case catch LookupOp(ParentNode) of
		{entry, ChildOid, NewParentCache} ->
			S2 = S#state{inodes=gb_trees:update(Parent,
				ParentNode#vnode{cache=NewParentCache}, Inodes)},
			#vnode{timeout=Timeout, ifc=#ifc{getnode=GetNode}} = ParentNode,
			case gb_trees:lookup(ChildOid, IMap) of
				{value, ChildIno} ->
					do_lookup_cached(ChildIno, Timeout, S2);

				none ->
					do_lookup_new(Parent, ChildOid, GetNode, Timeout, S2)
			end;

		{error, Error, NewParentCache} ->
			{
				error,
				Error,
				S#state{inodes=gb_trees:update(Parent,
					ParentNode#vnode{cache=NewParentCache}, Inodes)}
			};

		{error, Error} ->
			{error, Error, S}
	end.


do_lookup_cached(ChildIno, Timeout, #state{inodes=Inodes}=S) ->
	ChildNode = gb_trees:get(ChildIno, Inodes),
	S2 = S#state{
		inodes = gb_trees:update(
			ChildIno,
			ChildNode#vnode{refcnt=ChildNode#vnode.refcnt+1},
			Inodes)
	},
	{ok, ChildIno, ChildNode, Timeout, S2}.


do_lookup_new(ParentIno, ChildOid, GetNode, Timeout, S) ->
	#state{inodes=Inodes, imap=IMap, count=Count} = S,
	NewCount = Count+1,
	case catch GetNode(ChildOid) of
		{ok, ChildNode} ->
			S2 = S#state{
				inodes = gb_trees:insert(
					NewCount,
					ChildNode#vnode{refcnt=1, parent=ParentIno},
					Inodes),
				imap = gb_trees:insert(ChildOid, NewCount, IMap),
				count = NewCount
			},
			{ok, NewCount, ChildNode, Timeout, S2};

		error ->
			{error, enoent, S}
	end.


do_forget(Ino, N, #state{inodes=Inodes, imap=IMap} = State) ->
	#vnode{refcnt=RefCnt, oid=OId} = Node = gb_trees:get(Ino, Inodes),
	case RefCnt - N of
		0 ->
			State#state{
				inodes = gb_trees:delete(Ino, Inodes),
				imap   = gb_trees:delete(OId, IMap)
			};

		NewRef ->
			State#state{
				inodes = gb_trees:update(Ino, Node#vnode{refcnt=NewRef}, Inodes)
			}
	end.


make_entry(ChildIno, ChildNode, ParentTimeout) ->
	#vnode{
		oid     = ChildOid,
		ifc     = #ifc{ getattr = GetAttr },
		timeout = ChildTimeout
	} = ChildNode,
	case catch GetAttr(ChildOid) of
		{ok, Attr} ->
			{
				ok,
				#vfs_entry{
					ino       = ChildIno,
					attr_tmo  = ChildTimeout,
					entry_tmo = ParentTimeout,
					attr      = Attr
				}
			};

		{error, _} ->
			error
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Root directory
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

root_make_node() ->
	#vnode{
		refcnt  = 1,
		parent  = 1,
		timeout = 3000,
		oid     = stores,
		ifc     = #ifc{
			getattr = fun(_) -> {ok, #vfs_attr{dir=true}} end,
			lookup  = fun stores_lookup/3,
			getnode = fun stores_getnode/1,
			readdir = fun stores_readdir/2
		}
	}.


stores_lookup(stores, Name, Cache) ->
	case find_entry(
		fun({Id, _Descr, Guid, _Tags}) ->
			BinId = atom_to_binary(Id, utf8),
			if
				BinId == Name ->
					{ok, {doc, Guid, Guid}};

				true ->
					error
			end
		end,
		hotchpotch_volman:enum())
	of
		{value, Oid} -> {entry, Oid, Cache};
		none         -> {error, enoent}
	end.


stores_getnode(Oid) ->
	case doc_make_node(Oid) of
		{ok, VNode} ->
			#vnode{ifc=OldIfc} = VNode,
			NewIfc = OldIfc#ifc{
				lookup  = fun(ObjId, Name, Cache) ->
					storewrap_lookup(ObjId, Name, Cache, OldIfc#ifc.lookup)
				end,
				getnode = fun(ObjId) ->
					storewrap_getnode(ObjId, OldIfc#ifc.getnode)
				end,
				readdir = fun(ObjId, Cache) ->
					storewrap_readdir(ObjId, Cache, OldIfc#ifc.readdir)
				end
			},
			{ok, VNode#vnode{ifc=NewIfc}};

		Error ->
			Error
	end.


stores_readdir(stores, Cache) ->
	Stores = lists:map(
		fun({Id, _Descr, _Guid, _Tags}) ->
			#vfs_direntry{name=atom_to_binary(Id, utf8), attr=#vfs_attr{dir=true}}
		end,
		lists:filter(
			fun({_Id, _Descr, _Guid, Tags}) ->
				proplists:is_defined(mounted, Tags)
			end,
			hotchpotch_volman:enum())),
	{ok, Stores, Cache}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Store wrapper: adds a '.docs' directory to each store
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

storewrap_lookup({doc, Store, Store} = Oid, Name, Cache, Lookup) ->
	case Name of
		<<".docs">> ->
			{entry, {docsdir, Store}, Cache};
		_Else ->
			Lookup(Oid, Name, Cache)
	end.


storewrap_getnode({docsdir, Store}, _GetNode) ->
	docsdir_make_node(Store);

storewrap_getnode(Oid, GetNode) ->
	GetNode(Oid).


storewrap_readdir(Oid, Cache, ReadDir) ->
	case ReadDir(Oid, Cache) of
		{ok, Entries, NewCache} ->
			DocEntry = #vfs_direntry{name= <<".docs">>, attr=#vfs_attr{dir=true}},
			{ok, [DocEntry | Entries], NewCache};

		Else ->
			Else
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% .docs directory
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

docsdir_make_node(Store) ->
	{ok, #vnode{
		refcnt  = 1,
		timeout = 30000,
		oid     = {docsdir, Store},
		ifc     = #ifc{
			getattr = fun(_) -> {ok, #vfs_attr{dir=true}} end,
			lookup  = fun docsdir_lookup/3,
			getnode = fun docsdir_getnode/1,
			readdir = fun docsdir_readdir/2
		}
	}}.


docsdir_lookup({docsdir, Store}, Name, Cache) ->
	case parse_name_to_uuid(Name) of
		{ok, Uuid} ->
			{entry, {docdir, Store, Uuid}, Cache};
		error ->
			{error, enoent}
	end.


docsdir_getnode({docdir, Store, Uuid}) ->
	docdir_make_node(Store, Uuid).


docsdir_readdir({docsdir, _Store}, Cache) ->
	{ok, [], Cache}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Document virtual directory
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

docdir_make_node(Store, Uuid) ->
	{ok, #vnode{
		refcnt  = 1,
		timeout = 1000,
		oid     = {docdir, Store, Uuid},
		cache   = {undefined, undefined},
		ifc     = #ifc{
			getattr = fun(_) -> {ok, #vfs_attr{dir=true}} end,
			lookup  = fun docdir_lookup/3,
			getnode = fun docdir_getnode/1,
			readdir = fun docdir_readdir/2
		}
	}}.


docdir_lookup({docdir, Store, Doc}, Name, Cache) ->
	case docdir_read_entry(Store, Doc, Cache) of
		{ok, Name, NewCache} ->
			{entry, {doc, Store, Doc}, NewCache};

		{ok, _OtherName, NewCache} ->
			{error, enoent, NewCache};

		error ->
			{error, enoent}
	end.


docdir_getnode(Oid) ->
	doc_make_node(Oid).


docdir_readdir({docdir, Store, Doc}, Cache) ->
	case docdir_read_entry(Store, Doc, Cache) of
		{ok, Name, NewCache} ->
			Oid = {doc, Store, Doc},
			case doc_make_node(Oid) of
				{ok, #vnode{ifc=#ifc{getattr=GetAttr}}} ->
					case catch GetAttr(Oid) of
						{ok, Attr} ->
							{ok, [#vfs_direntry{name=Name, attr=Attr}], NewCache};
						{error, _} ->
							{ok, [], NewCache}
					end;
				error ->
					{ok, [], NewCache}
			end;

		error ->
			{ok, [], Cache}
	end.


docdir_read_entry(Store, Doc, {CacheRev, CacheEntry}=Cache) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, CacheRev} ->
			{ok, CacheEntry, Cache};

		{ok, Rev} ->
			case catch read_file_name(Store, Doc, Rev) of
				{ok, Name} -> {ok, Name, {Rev, Name}};
				error      -> error
			end;

		error ->
			error
	end.


read_file_name(_Store, _Doc, Rev) ->
	Meta = case hotchpotch_util:read_rev_struct(Rev, <<"META">>) of
		{ok, Value1} when is_record(Value1, dict, 9) ->
			Value1;
		{ok, _} ->
			throw(error);
		{error, _} ->
			throw(error)
	end,
	case meta_read_entry(Meta, [<<"org.hotchpotch.annotation">>, <<"title">>]) of
		{ok, Title} when is_binary(Title) ->
			{ok, Title};
		{ok, _} ->
			error;
		error ->
			error
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Documents
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

doc_make_node({doc, Store, Doc} = Oid) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, Rev} ->
			case hotchpotch_ifc_vfs_broker:stat(Store, Rev) of
				{ok, #rev_stat{type=Type}} ->
					case Type of
						<<"org.hotchpotch.store">> ->
							doc_make_node_dict(Oid);
						<<"org.hotchpotch.dict">> ->
							doc_make_node_dict(Oid);
						<<"org.hotchpotch.set">> ->
							doc_make_node_set(Oid);
						_ ->
							doc_make_node_file(Oid)
					end;

				{error, _} ->
					error
			end;

		error ->
			error
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Directory documents
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

doc_make_node_dict(Oid) ->
	{ok, #vnode{
		timeout = 1000,
		oid     = Oid,
		ifc     = #ifc{
			getattr = fun dict_getattr/1,
			lookup  = fun dict_lookup/3,
			getnode = fun dict_getnode/1,
			readdir = fun dict_readdir/2,
			create  = fun dict_create/4,
			link    = fun dict_link/4,
			unlink  = fun dict_unlink/3,
			mkdir   = fun dict_mkdir/3,
			rename  = fun dict_rename/4
		},
		cache = {undefined, undefined}
	}}.


dict_getattr({doc, Store, Doc}) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, Rev} ->
			case hotchpotch_ifc_vfs_broker:stat(Store, Rev) of
				{ok, #rev_stat{mtime=Mtime}} ->
					{ok, #vfs_attr{
						dir   = true,
						atime = Mtime,
						mtime = Mtime,
						ctime = Mtime
					}};
				Error ->
					Error
			end;
		error ->
			{error, enoent}
	end.


dict_lookup({doc, Store, Doc}, Name, Cache) ->
	case dict_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case dict:find(Name, Entries) of
				{ok, {dlink, ChildDoc}} ->
					{entry, {doc, Store, ChildDoc}, NewCache};

				_ ->
					{error, enoent, NewCache}
			end;

		_ ->
			{error, enoent}
	end.


dict_create({doc, Store, Doc}, Name, Cache, MustCreate) ->
	case dict_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case dict:find(Name, Entries) of
				{ok, {dlink, ChildDoc}} ->
					case MustCreate of
						true ->
							{error, eexist, NewCache};
						false ->
							{entry, {doc, Store, ChildDoc}, NewCache}
					end;

				{ok, _} ->
					{error, eacces, NewCache};

				error ->
					case create_empty_file(Store, Name) of
						{ok, Handle, NewDoc, _NewRev} ->
							try
								Update = fun(Dict) ->
									dict:store(Name, {dlink, NewDoc}, Dict)
								end,
								case dict_update(Store, Doc, NewCache, Update) of
									{ok, AddCache} ->
										{entry, {doc, Store, NewDoc}, AddCache};
									{error, _Reason, _AddCache} = Error ->
										Error
								end
							after
								hotchpotch_broker:close(Handle)
							end;

						{error, Reason} ->
							{error, Reason, NewCache}
					end
			end;

		_ ->
			{error, eacces}
	end.


dict_mkdir({doc, Store, Doc}, Name, Cache) ->
	case dict_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case dict:find(Name, Entries) of
				{ok, _} ->
					{error, eexist, NewCache};

				error ->
					case create_empty_directory(Store, Name) of
						{ok, Handle, NewDoc, _NewRev} ->
							try
								Update = fun(Dict) ->
									dict:store(Name, {dlink, NewDoc}, Dict)
								end,
								case dict_update(Store, Doc, NewCache, Update) of
									{ok, AddCache} ->
										{ok, {doc, Store, NewDoc}, AddCache};
									{error, _Reason, _AddCache} = Error ->
										Error
								end
							after
								hotchpotch_broker:close(Handle)
							end;

						{error, Reason} ->
							{error, Reason, NewCache}
					end
			end;

		_ ->
			{error, eacces}
	end.


dict_getnode({doc, _Store, _Doc} = Oid) ->
	doc_make_node(Oid);
dict_getnode(_) ->
	error.


dict_readdir({doc, Store, Doc}, Cache) ->
	case dict_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			Content = map_filter(
				fun(E) -> dict_readdir_filter(Store, E) end,
				dict:to_list(Entries)),
			{ok, Content, NewCache};

		error ->
			{error, enoent}
	end.


dict_readdir_filter(Store, {Name, {dlink, Child}}) ->
	Oid = {doc, Store, Child},
	case doc_make_node(Oid) of
		{ok, #vnode{ifc=#ifc{getattr=GetAttr}}} ->
			case catch GetAttr(Oid) of
				{ok, Attr} ->
					{ok, #vfs_direntry{name=Name, attr=Attr}};
				{error, _} ->
					skip
			end;
		error ->
			skip
	end;

dict_readdir_filter(_, _) ->
	skip.


dict_read_entries(Store, Doc, {CacheRev, CacheEntries}=Cache) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, CacheRev} ->
			{ok, CacheEntries, Cache};

		{ok, Rev} ->
			case hotchpotch_util:read_rev_struct(Rev, <<"HPSD">>) of
				{ok, Entries} when is_record(Entries, dict, 9) ->
					{ok, Entries, {Rev, Entries}};
				{ok, _} ->
					error;
				{error, _} ->
					error
			end;
		error ->
			error
	end.


dict_link({doc, Store, ParentDoc}, {doc, Store, ChildDoc}, Name, Cache) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, ChildDoc) of
		{ok, _ChildRev} ->
			Update = fun(Entries) ->
				dict:store(Name, {dlink, ChildDoc}, Entries)
			end,
			dict_update(Store, ParentDoc, Cache, Update);

		error ->
			{error, enoent}
	end;

dict_link(_, _, _, _) ->
	{error, eacces}.


dict_unlink({doc, Store, Doc}, Name, Cache) ->
	Update = fun(Entries) -> dict:erase(Name, Entries) end,
	dict_update(Store, Doc, Cache, Update).


dict_rename({doc, Store, Doc}, OldName, NewName, Cache) ->
	Update = fun(Entries) ->
		case dict:find(OldName, Entries) of
			{ok, Entry} ->
				dict:store(NewName, Entry, dict:erase(OldName, Entries));
			error ->
				{error, enoent}
		end
	end,
	dict_update(Store, Doc, Cache, Update).


dict_update(Store, Doc, Cache, Fun) ->
	case hotchpotch_ifc_vfs_broker:open_doc(Store, Doc, true) of
		{ok, Rev, Handle} ->
			case dict_update_cache(Handle, Rev, Cache) of
				{ok, Entries, NewCache} ->
					case Fun(Entries) of
						{error, Reason} ->
							hotchpotch_ifc_vfs_broker:abort(Handle),
							{error, Reason, NewCache};
						NewEntries ->
							dict_write_entries(Handle, NewEntries, NewCache)
					end;

				Error ->
					hotchpotch_ifc_vfs_broker:abort(Handle),
					Error
			end;

		Error ->
			Error
	end.


dict_update_cache(_Handle, Rev, {Rev, Struct} = Cache) ->
	{ok, Struct, Cache};

dict_update_cache(Handle, Rev, _Cache) ->
	case catch read_struct(Handle, <<"HPSD">>) of
		Struct when is_record(Struct, dict, 9) ->
			{ok, Struct, {Rev, Struct}};
		{error, _} = Error ->
			Error;
		_ ->
			{error, einval}
	end.


dict_write_entries(Handle, Entries, Cache) ->
	case write_struct(Handle, <<"HPSD">>, Entries) of
		ok ->
			case hotchpotch_ifc_vfs_broker:close(Handle) of
				{ok, Rev} ->
					{ok, {Rev, Entries}};
				{error, Reason} ->
					{error, Reason, Cache}
			end;

		{error, Error} ->
			hotchpotch_ifc_vfs_broker:abort(Handle),
			{error, Error, Cache}
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Set documents
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(se, {oid, rev, disp, title, suffix}).

doc_make_node_set(Oid) ->
	{ok, #vnode{
		timeout = 1000,
		oid     = Oid,
		ifc     = #ifc{
			getattr = fun set_getattr/1,
			lookup  = fun set_lookup/3,
			getnode = fun set_getnode/1,
			readdir = fun set_readdir/2,
			create  = fun set_create/4,
			link    = fun set_link/4,
			unlink  = fun set_unlink/3,
			mkdir   = fun set_mkdir/3,
			rename  = fun set_rename/4
		},
		cache = {undefined, undefined}
	}}.


set_getattr({doc, Store, Doc}) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, Rev} ->
			case hotchpotch_ifc_vfs_broker:stat(Store, Rev) of
				{ok, #rev_stat{mtime=Mtime}} ->
					{ok, #vfs_attr{
						dir   = true,
						atime = Mtime,
						mtime = Mtime,
						ctime = Mtime
					}};
				Error ->
					Error
			end;
		error ->
			{error, enoent}
	end.


set_lookup({doc, Store, Doc}, Name, Cache) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case set_find_name(Name, Entries) of
				{ok, Oid} -> {entry, Oid, NewCache};
				error     -> {error, enoent, NewCache}
			end;

		_ ->
			{error, enoent}
	end.


set_getnode({doc, _Store, _Doc} = Oid) ->
	doc_make_node(Oid);
set_getnode(_) ->
	error.


set_readdir({doc, Store, Doc}, Cache) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			Content = map_filter(fun set_readdir_filter/1, Entries),
			{ok, Content, NewCache};

		error ->
			{error, enoent}
	end.


set_create({doc, Store, Doc}, Name, Cache, MustCreate) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case set_find_name(Name, Entries) of
				{ok, {doc, _, _}=ChildOid} ->
					case MustCreate of
						true ->
							{error, eexist, NewCache};
						false ->
							{entry, ChildOid, NewCache}
					end;

				{ok, _} ->
					{error, eacces, NewCache};

				error ->
					case create_empty_file(Store, Name) of
						{ok, Handle, NewDoc, NewRev} ->
							try
								NewSetEntry = #se{
									oid    = {doc, Store, NewDoc},
									rev    = NewRev,
									title  = Name,
									suffix = hotchpotch_util:bin_to_hexstr(NewDoc)
								},
								Update = fun(List) ->
									[NewSetEntry | List]
								end,
								case set_update(Store, Doc, NewCache, Update) of
									{ok, AddCache} ->
										{entry, {doc, Store, NewDoc}, AddCache};
									{error, _Reason, _AddCache} = Error ->
										Error
								end
							after
								hotchpotch_broker:close(Handle)
							end;

						{error, Reason} ->
							{error, Reason, NewCache}
					end
			end;

		_ ->
			{error, enoent}
	end.


set_mkdir({doc, Store, Doc}, Name, Cache) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case set_find_name(Name, Entries) of
				{ok, _} ->
					{error, eexist, NewCache};

				error ->
					case create_empty_directory(Store, Name) of
						{ok, Handle, NewDoc, NewRev} ->
							try
								NewSetEntry = #se{
									oid    = {doc, Store, NewDoc},
									rev    = NewRev,
									title  = Name,
									suffix = hotchpotch_util:bin_to_hexstr(NewDoc)
								},
								Update = fun(List) ->
									[NewSetEntry | List]
								end,
								case set_update(Store, Doc, NewCache, Update) of
									{ok, AddCache} ->
										{ok, {doc, Store, NewDoc}, AddCache};
									{error, _Reason, _AddCache} = Error ->
										Error
								end
							after
								hotchpotch_broker:close(Handle)
							end;

						{error, Reason} ->
							{error, Reason, NewCache}
					end
			end;

		_ ->
			{error, enoent}
	end.


set_link({doc, Store, ParentDoc}, {doc, Store, ChildDoc}, Name, Cache) ->
	{Title, _DocId} = set_split_name(Name),
	ChildRev = case hotchpotch_ifc_vfs_broker:lookup(Store, ChildDoc) of
		{ok, Rev} ->
			case set_read_title(Rev) of
				Title -> Rev;
				_     -> throw({error, eacces})
			end;

		error ->
			throw({error, enoent})
	end,
	NewEntry = #se{
		oid    = {doc, Store, ChildDoc},
		rev    = ChildRev,
		title  = Title,
		suffix = hotchpotch_util:bin_to_hexstr(ChildDoc)
	},
	case set_read_entries(Store, ParentDoc, Cache) of
		{ok, Entries, NewCache} ->
			Update = case set_find_name(Name, Entries) of
				{ok, Oid} ->
					fun(List) -> [NewEntry | lists:keydelete(Oid, #se.oid, List)] end;
				error ->
					fun(List) -> [NewEntry | List] end
			end,
			set_update(Store, ParentDoc, NewCache, Update);

		_ ->
			{error, enoent}
	end;

set_link(_, _, _, _) ->
	{error, eacces}.


set_unlink({doc, Store, Doc}, Name, Cache) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case set_find_name(Name, Entries) of
				{ok, Oid} ->
					Update = fun(List) -> lists:keydelete(Oid, #se.oid, List) end,
					set_update(Store, Doc, NewCache, Update);

				error ->
					{error, enoent, NewCache}
			end;

		_ ->
			{error, enoent}
	end.


set_rename({doc, Store, Doc}, OldName, NewName, Cache) ->
	case set_read_entries(Store, Doc, Cache) of
		{ok, Entries, NewCache} ->
			case set_find_name(OldName, Entries) of
				{ok, {doc, Store, ChildDoc}} ->
					case set_set_title(Store, ChildDoc, NewName) of
						ok ->
							% Did we replace a file?
							case set_find_name(NewName, Entries) of
								{ok, Oid} ->
									Update = fun(List) -> lists:keydelete(Oid, #se.oid, List) end,
									set_update(Store, Doc, NewCache, Update);

								error ->
									{ok, NewCache}
							end;

						{error, Reason} ->
							{error, Reason, NewCache}
					end;

				{ok, _} ->
					{error, eacces, NewCache};
				error ->
					{error, enoent, NewCache}
			end;

		_ ->
			{error, enoent}
	end.


set_find_name(FullName, Entries) ->
	{Name, DocId} = set_split_name(FullName),
	case find_entry(fun(E) -> set_lookup_cmp(Name, DocId, E) end, Entries) of
		{value, Oid} -> {ok, Oid};
		none         -> error
	end.


set_split_name(Name) ->
	% FIXME: precompile
	RegExp = <<"(.*)~([[:xdigit:]]+)(\\.\\w+)?">>,
	case re:run(Name, RegExp, [{capture, all_but_first, binary}]) of
		{match, [Title, DocId, Extension]} ->
			{<<Title/binary, Extension/binary>>, unicode:characters_to_list(DocId)};
		{match, [Title, DocId]} ->
			{Title, unicode:characters_to_list(DocId)};
		nomatch ->
			{Name, ""}
	end.


set_lookup_cmp(Name, DocId, #se{oid=Oid, title=Title, suffix=Suffix}) ->
	case Name of
		Title ->
			case lists:prefix(DocId, Suffix) of
				true  -> {ok, Oid};
				false -> error
			end;
		_ ->
			error
	end;

set_lookup_cmp(_, _, _) ->
	error.


set_readdir_filter(#se{oid={doc,_,_}=Oid, disp=Name}) ->
	case doc_make_node(Oid) of
		{ok, #vnode{ifc=#ifc{getattr=GetAttr}}} ->
			case catch GetAttr(Oid) of
				{ok, Attr} ->
					{ok, #vfs_direntry{name=Name, attr=Attr}};
				{error, _} ->
					skip
			end;
		error ->
			skip
	end;

set_readdir_filter(_) ->
	skip.


%% Sets are special. First we have to check if the set itself has changed. Then
%% we have to lookup every child document if it has changed and re-read the
%% title if so. In any case we have to eliminate duplicates and sanitize the
%% names.
%%
%% Entry list format: [{Oid, Rev, DispTitle, RealTitle, Suffix}]
%% Cache format: {Rev, Entries}
%%
set_read_entries(Store, Doc, {CacheRev, CacheEntries}) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, CacheRev} ->
			NewCacheEntries = set_update_entries(CacheEntries),
			{ok, NewCacheEntries, {CacheRev, NewCacheEntries}};

		{ok, Rev} ->
			case hotchpotch_util:read_rev_struct(Rev, <<"HPSD">>) of
				{ok, List} when is_list(List) ->
					Entries = set_read_entries_list(Store, List),
					{ok, Entries, {Rev, Entries}};

				{ok, _} ->
					error;
				{error, _} ->
					error
			end;

		error ->
			error
	end.


set_update_entries(Cache) ->
	case lists:foldl(fun set_find_update/2, [], Cache) of
		[] ->
			Cache;
		Updates ->
			NewCache = set_apply_updates(Cache, lists:reverse(Updates), []),
			set_sanitize_entries(NewCache, 0)
	end.


set_find_update(#se{oid={doc, Store, Doc}, rev=CacheRev}=Entry, Acc) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, CacheRev} ->
			Acc;
		{ok, NewRev} ->
			[Entry#se{rev=NewRev, title=set_read_title(NewRev)} | Acc];
		error ->
			[Entry#se{rev=undefined, title= <<"">>} | Acc]
	end.


set_apply_updates([], _, Acc) ->
	Acc;

set_apply_updates([#se{oid=Oid} | Cache], [#se{oid=Oid}=New | Updates], Acc) ->
	set_apply_updates(Cache, Updates, [New | Acc]);

set_apply_updates([Entry | Cache], Updates, Acc) ->
	set_apply_updates(Cache, Updates, [Entry | Acc]).



set_read_entries_list(Store, List) ->
	RawEntries = map_filter(
		fun(E) -> set_read_entries_filter(Store, E) end,
		List),
	set_sanitize_entries(RawEntries, 0).


set_read_entries_filter(Store, {dlink, Doc}) ->
	Oid = {doc, Store, Doc},
	Suffix = hotchpotch_util:bin_to_hexstr(Doc),
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, Rev} ->
			Title = set_read_title(Rev),
			{ok, #se{oid=Oid, rev=Rev, title=Title, suffix=Suffix}};

		error ->
			{ok, #se{oid=Oid, title= <<"">>, suffix=Suffix}}
	end;

set_read_entries_filter(_, _) ->
	skip.


set_read_title(Rev) ->
	case hotchpotch_util:read_rev_struct(Rev, <<"META">>) of
		{ok, Meta} ->
			case meta_read_entry(Meta, [<<"org.hotchpotch.annotation">>, <<"title">>]) of
				{ok, Title} when is_binary(Title) ->
					unicode:characters_to_binary(sanitize(binary_to_list(Title)));
				{ok, _} ->
					<<"">>;
				error ->
					<<"">>
			end;
		{error, _} ->
			<<"">>
	end.


set_sanitize_entries(Cache, SuffixLen) ->
	Dict = lists:foldl(
		fun(#se{title=Title, suffix=Suffix}=Entry, Acc) ->
			dict:append(set_apply_suffix(Title, Suffix, SuffixLen), Entry, Acc)
		end,
		dict:new(),
		Cache),
	dict:fold(
		fun(Title, Entries, Acc) ->
			case Entries of
				[Entry] ->
					[Entry#se{disp=Title} | Acc];
				_ ->
					set_sanitize_entries(Entries, SuffixLen+4) ++ Acc
			end
		end,
		[],
		Dict).


set_apply_suffix(Title, _Suffix, 0) ->
	Title;

set_apply_suffix(Title, Suffix, Len) ->
	BinSuffix = unicode:characters_to_binary(lists:sublist(Suffix, Len)),
	Components = re:split(Title, <<"\\.">>),
	set_join_components(Components, BinSuffix).


set_join_components([Title], Suffix) ->
	<<Title/binary, "~", Suffix/binary>>;

set_join_components([Title, Ext], Suffix) ->
	<<Title/binary, "~", Suffix/binary, ".", Ext/binary>>;

set_join_components([Comp | Rest], Suffix) ->
	Joined = set_join_components(Rest, Suffix),
	<<Comp/binary, ".", Joined/binary>>.


set_update(Store, Doc, Cache, Fun) ->
	case hotchpotch_ifc_vfs_broker:open_doc(Store, Doc, true) of
		{ok, Rev, Handle} ->
			case set_update_cache(Store, Handle, Rev, Cache) of
				{ok, Entries, NewCache} ->
					case Fun(Entries) of
						{error, Reason} ->
							hotchpotch_ifc_vfs_broker:abort(Handle),
							{error, Reason, NewCache};
						NewEntries ->
							set_write_entries(Handle, NewEntries, NewCache)
					end;

				Error ->
					hotchpotch_ifc_vfs_broker:abort(Handle),
					Error
			end;

		Error ->
			Error
	end.


set_update_cache(_Store, _Handle, Rev, {Rev, Entries}) ->
	NewEntries = set_update_entries(Entries),
	{ok, NewEntries, {Rev, NewEntries}};

set_update_cache(Store, Handle, Rev, _Cache) ->
	case catch read_struct(Handle, <<"HPSD">>) of
		List when is_list(List) ->
			Entries = set_read_entries_list(Store, List),
			{ok, Entries, {Rev, Entries}};
		{error, _} = Error ->
			Error;
		_ ->
			{error, einval}
	end.


set_write_entries(Handle, Entries, Cache) ->
	List = [{dlink, Doc} || #se{oid={doc, _, Doc}} <- Entries],
	case write_struct(Handle, <<"HPSD">>, List) of
		ok ->
			case hotchpotch_ifc_vfs_broker:close(Handle) of
				{ok, Rev} ->
					{ok, {Rev, set_sanitize_entries(Entries, 0)}};
				{error, Reason} ->
					{error, Reason, Cache}
			end;

		{error, Error} ->
			hotchpotch_ifc_vfs_broker:abort(Handle),
			{error, Error, Cache}
	end.


set_set_title(Store, Doc, NewTitle) ->
	case hotchpotch_ifc_vfs_broker:open_doc(Store, Doc, true) of
		{ok, _OldRev, Handle} ->
			try
				Meta1 = read_struct(Handle, <<"META">>),
				Meta2 = meta_write_entry(Meta1,
					[<<"org.hotchpotch.annotation">>, <<"title">>],
					NewTitle),
				case write_struct(Handle, <<"META">>, Meta2) of
					ok    -> ok;
					WrErr -> throw(WrErr)
				end,
				case hotchpotch_ifc_vfs_broker:close(Handle) of
					{ok, _NewRev} -> ok;
					CloseErr      -> CloseErr
				end
			catch
				throw:Error ->
					hotchpotch_ifc_vfs_broker:abort(Handle),
					Error
			end;

		Error ->
			Error
	end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% All other documents
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

doc_make_node_file(Oid) ->
	{ok, #vnode{
		timeout = 1000,
		oid     = Oid,
		ifc     = #ifc{
			getattr  = fun file_getattr/1,
			truncate = fun file_truncate/2,
			open     = fun file_open/3
		}
	}}.


file_getattr({doc, Store, Doc}) ->
	case hotchpotch_ifc_vfs_broker:lookup(Store, Doc) of
		{ok, Rev} ->
			file_getattr_rev(Store, Rev);
		error ->
			{error, enoent}
	end.


file_getattr_rev(Store, Rev) ->
	case hotchpotch_ifc_vfs_broker:stat(Store, Rev) of
		{ok, #rev_stat{parts=Parts, mtime=Mtime}} ->
			Size = case find_entry(
				fun({FCC, Size, _Hash}) ->
					case FCC of
						<<"FILE">> -> {ok, Size};
						_          -> error
					end
				end,
				Parts)
			of
				{value, FileSize} -> FileSize;
				none              -> 0
			end,
			{ok, #vfs_attr{
				dir   = false,
				atime = Mtime,
				mtime = Mtime,
				ctime = Mtime,
				size  = Size
			}};

		Error ->
			Error
	end.


file_truncate({doc, Store, Doc}, Size) ->
	case hotchpotch_ifc_vfs_broker:open_doc(Store, Doc, true) of
		{ok, _Rev, Handle} ->
			case hotchpotch_ifc_vfs_broker:truncate(Handle, <<"FILE">>, Size) of
				ok ->
					case hotchpotch_ifc_vfs_broker:close(Handle) of
						{ok, CurRev} ->
							file_getattr_rev(Store, CurRev);
						Error ->
							Error
					end;

				{error, _} = Error ->
					hotchpotch_ifc_vfs_broker:close(Handle),
					Error
			end;

		{error, _} = Error ->
			Error
	end.


file_open({doc, Store, Doc}, Trunc, Mode) ->
	Write = Mode =/= read,
	case hotchpotch_ifc_vfs_broker:open_doc(Store, Doc, Write) of
		{ok, _Rev, Handle} ->
			Res = case Trunc of
				true  -> hotchpotch_ifc_vfs_broker:truncate(Handle, <<"FILE">>, 0);
				false -> ok
			end,
			case Res of
				ok ->
					{ok, #handler{
						read = fun(Size, Offset) ->
							file_read(Handle, Size, Offset)
						end,
						write = fun(Data, Offset) ->
							file_write(Handle, Data, Offset)
						end,
						release = fun(Changed, Rewritten) ->
							file_release(Handle, Changed, Rewritten)
						end
					}};

				{error, _} = Error ->
					Error
			end;

		{error, _} = Error ->
			Error
	end.


file_read(Handle, Size, Offset) ->
	case hotchpotch_ifc_vfs_broker:read(Handle, <<"FILE">>, Offset, Size) of
		{ok, _Data} = R  -> R;
		{error, enoent}  -> {ok, <<>>};
		{error, _}       -> {error, eio}
	end.


file_write(Handle, Data, Offset) ->
	hotchpotch_ifc_vfs_broker:write(Handle, <<"FILE">>, Offset, Data).


file_release(Handle, _Changed, _Rewritten) ->
	%case Changed of
	%	false -> ok;
	%	true  ->
	%		if
	%			Rewritten ->
	%				case hotchpotch_ifc_vfs_broker:read(Handle, <<"FILE">>, 0, 4096) of
	%					{ok, Data} ->
	%						hotchpotch_ifc_vfs_broker:set_type(Handle, registry:guess(Data));
	%					_Else ->
	%						ok
	%				end;
	%			true ->
	%				ok
	%		end
	%end,
	hotchpotch_ifc_vfs_broker:close(Handle).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utility functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

map_filter(F, L) ->
	map_filter_loop(F, L, []).

map_filter_loop(_, [], Acc) ->
	Acc;
map_filter_loop(F, [H | T], Acc) ->
	case F(H) of
		{ok, Value} -> map_filter_loop(F, T, [Value | Acc]);
		skip        -> map_filter_loop(F, T, Acc)
	end.


find_entry(_, []) ->
	none;
find_entry(F, [H|T]) ->
	case F(H) of
		{ok, Result} -> {value, Result};
		error        -> find_entry(F, T)
	end.


meta_read_entry(Meta, []) ->
	{ok, Meta};
meta_read_entry(Meta, [Step|Path]) when is_record(Meta, dict, 9) ->
	case dict:find(Step, Meta) of
		{ok, Value} -> meta_read_entry(Value, Path);
		error       -> error
	end;
meta_read_entry(_Meta, _Path) ->
	error.


meta_write_entry(_Meta, [], Value) ->
	Value;

meta_write_entry(Meta, [Step|Path], Value) when is_record(Meta, dict, 9) ->
	Sub = case dict:find(Step, Meta) of
		{ok, V} -> V;
		error   -> dict:new()
	end,
	dict:store(Step, meta_write_entry(Sub, Path, Value), Meta);

meta_write_entry(_Meta, _Path, _Value) ->
	throw({error, einval}).


sanitize(S) ->
	lists:filter(fun(C) -> (C /= $/) and (C >= 31) end, S).


read_struct(Handle, Part) ->
	Data = read_struct_loop(Handle, Part, 0, <<>>),
	case catch hotchpotch_struct:decode(Data) of
		{'EXIT', _Reason} ->
			throw({error, einval});
		Struct ->
			Struct
	end.


read_struct_loop(Handle, Part, Offset, Acc) ->
	Length = 16#10000,
	case hotchpotch_ifc_vfs_broker:read(Handle, Part, Offset, Length) of
		{ok, <<>>} ->
			Acc;
		{ok, Data} ->
			read_struct_loop(Handle, Part, Offset+size(Data), <<Acc/binary, Data/binary>>);
		{error, _Reason} = Error ->
			throw(Error)
	end.


write_struct(Handle, Part, Struct) ->
	Data = hotchpotch_struct:encode(Struct),
	case hotchpotch_ifc_vfs_broker:truncate(Handle, Part, 0) of
		ok ->
			hotchpotch_ifc_vfs_broker:write(Handle, Part, 0, Data);
		{error, _} = Error ->
			Error
	end.


create_empty_file(Store, Name) ->
	MetaData = dict:store(
		<<"org.hotchpotch.annotation">>,
		dict:store(
			<<"title">>,
			Name,
			dict:store(
				<<"comment">>,
				<<"Created by FUSE interface">>,
				dict:new())),
		dict:new()),
	case hotchpotch_broker:create(<<"public.text">>, ?VFS_CC, hotchpotch_broker:get_stores([Store])) of
		{ok, _ErrInfo, {Doc, Handle}} ->
			hotchpotch_broker:write(Handle, <<"META">>, 0, hotchpotch_struct:encode(MetaData)),
			hotchpotch_broker:write(Handle, <<"FILE">>, 0, <<>>),
			case hotchpotch_broker:commit(Handle) of
				{ok, _ErrInfo, Rev} ->
					% leave handle open, the caller has to close it
					{ok, Handle, Doc, Rev};
				{error, Reason, _ErrInfo} ->
					hotchpotch_broker:close(Handle),
					{error, Reason}
			end;

		{error, Reason, _ErrInfo} ->
			{error, Reason}
	end.


create_empty_directory(Store, Name) ->
	MetaData = dict:store(
		<<"org.hotchpotch.annotation">>,
		dict:store(
			<<"title">>,
			Name,
			dict:store(
				<<"comment">>,
				<<"Created by FUSE interface">>,
				dict:new())),
		dict:new()),
	case get(dir_type) of
		dict ->
			TypeCode = <<"org.hotchpotch.dict">>,
			Hpsd = dict:new();
		set ->
			TypeCode = <<"org.hotchpotch.set">>,
			Hpsd = []
	end,
	case hotchpotch_broker:create(TypeCode, ?VFS_CC, hotchpotch_broker:get_stores([Store])) of
		{ok, _ErrInfo, {Doc, Handle}} ->
			hotchpotch_broker:write(Handle, <<"META">>, 0,
				hotchpotch_struct:encode(MetaData)),
			hotchpotch_broker:write(Handle, <<"HPSD">>, 0,
				hotchpotch_struct:encode(Hpsd)),
			case hotchpotch_broker:commit(Handle) of
				{ok, _ErrInfo, Rev} ->
					% leave handle open, the caller has to close it
					{ok, Handle, Doc, Rev};
				{error, Reason, _ErrInfo} ->
					hotchpotch_broker:close(Handle),
					{error, Reason}
			end;

		{error, Reason, _ErrInfo} ->
			{error, Reason}
	end.


parse_name_to_uuid(Name) when is_binary(Name) and (size(Name) == 32) ->
	try
		List = binary_to_list(Name),
		{ok, <<(erlang:list_to_integer(List, 16)):128>>}
	catch
		error:_ -> error
	end;

parse_name_to_uuid(_Name) ->
	error.

