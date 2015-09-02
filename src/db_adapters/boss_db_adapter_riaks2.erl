-module(boss_db_adapter_riaks2).
-behaviour(boss_db_adapter).
-export([init/1, terminate/1, start/1, stop/0, find/2, find/7]).
-export([count/3, counter/2, incr/2, incr/3, delete/2, save_record/2]).
-export([push/2, pop/2]).
-export([setup_model/1, setup_model/2, clear_index/1, reindex/1, re_index/1, re_index/2, create_schema/2, create_search_index/3, add_search_index/3, set_search_index/2]).

-define(LOG(Name, Value), lager:debug("DEBUG: ~s: ~p~n", [Name, Value])).

-define(HUGE_INT, 1000 * 1000 * 1000 * 1000).

-include("riakc.hrl").
-define(RS2_DB_HOST, "127.0.0.1").
-define(RS2_DB_PORT, 8087).

start(_) ->
    ok.

stop() ->
    ok.

init(Options) ->
    Host = proplists:get_value(db_host, Options, "localhost"),
    Port = proplists:get_value(db_port, Options, 8087),
    riakc_pb_socket:start_link(Host, Port).

terminate(Conn) ->
    riakc_pb_socket:stop(Conn).

find(Conn, Id) ->
    {Type, Bucket, Key} = infer_type_from_id(Id),
    Socket = riakc_pb_socket:get(Conn, Bucket, Key),
    query_riak_socket(Id, Type, Socket).

query_riak_socket(Id, Type, _Socket = {ok, Res} ) ->
    Value		= riakc_obj:get_value(Res),
    Data		= binary_to_term(Value),
    ConvertedData	= riak_search_decode_data(Data),
    AttributeTypes	= boss_record_lib:attribute_types(Type),
    Record              = get_record_from_riak(Type, ConvertedData,
					       AttributeTypes),
    Record:set(id, Id);
query_riak_socket(_Id, _Type, _Socket = {error, Reason} ) ->
    {error, Reason}.


get_record_from_riak(Type, ConvertedData, AttributeTypes) ->
    Lambda = fun (AttrName) ->
		     Val      = proplists:get_value(AttrName, ConvertedData),
		     AttrType = proplists:get_value(AttrName, AttributeTypes),
		     boss_record_lib:convert_value_to_type(Val, AttrType)
             end,
    apply(Type, new, lists:map(Lambda, boss_record_lib:attribute_names(Type))).

find_acc(_, _, [], Acc) ->
    lists:reverse(Acc);
find_acc(Conn, Prefix, [Id | Rest], Acc) ->
    case find(Conn, Prefix ++ binary_to_list(Id)) of
        {error, _Reason} ->
            find_acc(Conn, Prefix, Rest, Acc);

        Value ->
            find_acc(Conn, Prefix, Rest, [Value | Acc])
    end.

find(Conn, Type, Conditions, Max, Skip, Sort, SortOrder) ->
    Index = type_to_index(Type),
    Options = get_search_options(Max, Skip, Sort, SortOrder),
    %io:format("Options:~p~n", [Options]),
    {ok, Keys} = get_keys(Conn, Conditions, Index, Options),
    find_acc(Conn, atom_to_list(Type) ++ "-", Keys, []).

get_count(Conn, Type, Conditions, Max, Skip, Sort, SortOrder) ->
  Index = type_to_index(Type),
  Options = get_search_options(Max, Skip, Sort, SortOrder),
  Query = build_search_query(Conditions),
  {ok, Results} = riakc_pb_socket:search(Conn, Index, list_to_binary(Query), Options), 
  Results#search_results.num_found.

get_search_options(Max, Skip, Sort, SortOrder) ->
  case Max of
    all -> RowsOp = {rows, 10000000};
    Max -> RowsOp = {rows, Max}
  end,
  StartOp = {start, Skip},
  if Sort =/= id, Sort =/= 0 ->
	 		 case SortOrder of
	 			 ascending -> SortOp = [{sort, atom_to_list(Sort) ++ " asc"}];
		 		 descending -> SortOp = [{sort, atom_to_list(Sort) ++ " desc"}];
         _ -> SortOp = []
			 end;
     true ->
       SortOp = []
  end,
  lists:append([StartOp, RowsOp], SortOp).

get_keys(Conn, Cond, Index, Options) ->
    %io:format("Raw Conditions:~p~n",[Cond]),
    Conditions = build_search_query(Cond),
    %io:format("Query:Index(~p) Conditions(~p), Options:(~p)~n",[Index, Conditions, Options]),
    {ok, Results} = riakc_pb_socket:search(Conn, Index, list_to_binary(Conditions), Options),
    Result = Results#search_results.docs,
    {ok, lists:map(fun ({_,X}) ->
			   proplists:get_value(<<"_yz_rk">>, X)
		   end, Result)}.

% this is a stub just to make the tests runable
count(Conn, Type, Conditions) ->
  get_count(Conn, Type, Conditions, all, 0, 0, 0).

counter(_Conn, _Id) ->
    {error, notimplemented}.

incr(Conn, Id) ->
    incr(Conn, Id, 1).
incr(_Conn, _Id, _Count) ->
    {error, notimplemented}.


delete(Conn, Id) ->
    {_Type, Bucket, Key} = infer_type_from_id(Id),
    ok = riakc_pb_socket:delete(Conn, Bucket, Key).

%The call riakc_obj:new(Bucket::binary(),'undefined',PropList::[{binary(),_}]) 
% will never return since the success typing is
% ('undefined' | binary(),'undefined' | binary(),'undefined' | binary()) -> 
% {'riakc_obj','undefined' | binary(),'undefined' | binary(),'undefined',[],'undefined','undefined' | binary()} and the contract is 
% (bucket(),key(),value()) -> riakc_obj()
save_record(Conn, Record) ->
    Type = element(1, Record),
    Bucket = type_to_bucket(Type),
    PropList = [{riak_search_encode_key(K), riak_search_encode_value(V)} || {K, V} <- Record:attributes(), K =/= id],
    RiakKey = case Record:id() of
        id -> % New entry
	    GUID        = uuid:to_string(uuid:uuid4()),
            %io:format("PropList:~p~n",[PropList]),
            O		= riakc_obj:new(Bucket, list_to_binary(GUID), term_to_binary(PropList), "application/chicagobossmodel"),
            {ok, _RO}	= riakc_pb_socket:put(Conn, O, [return_body]),
            GUID;
        DefinedId when is_list(DefinedId) -> % Existing Entry
            [_ | Tail]	= string:tokens(DefinedId, "-"),
            Key		= string:join(Tail, "-"),
            BinKey	= list_to_binary(Key),
            {ok, O}	= riakc_pb_socket:get(Conn, Bucket, BinKey),
            O2		= riakc_obj:update_value(O, term_to_binary(PropList), "application/chicagobossmodel"),
            ok		= riakc_pb_socket:put(Conn, O2),
            Key
    end,
    {ok, Record:set(id, lists:concat([Type, "-", RiakKey]))}.

% These 2 functions are not part of the behaviour but are required for
% tests to pass
push(_Conn, _Depth) -> ok.

pop(_Conn, _Depth) -> ok.

% Internal functions

infer_type_from_id(Id) when is_list(Id) ->
    [Type | Tail] = string:tokens(Id, "-"),
    BossId = string:join(Tail, "-"),
    {list_to_atom(Type), type_to_bucket(Type), list_to_binary(BossId)}.

% Find bucket name from Boss type
type_to_bucket(Type) ->
    {list_to_binary(bucket_type()), list_to_binary(type_to_bucket_name(Type))}.

type_to_bucket_name(Type) when is_atom(Type) ->
    type_to_bucket_name(atom_to_list(Type));
type_to_bucket_name(Type) when is_list(Type) ->
    inflector:pluralize(Type).

build_search_query(Conditions) when Conditions =:= [] ->
    "*:*";
build_search_query(Conditions) ->
    Terms = build_search_query(Conditions, []),
    string:join(Terms, " AND ").

build_search_query([], Acc) ->
    lists:reverse(Acc);
build_search_query([{Key, 'equals', Value}|Rest], Acc) when Value =:= true;Value =:= false;is_integer(Value) ->
    build_search_query(Rest, [lists:concat([Key, ":", Value])|Acc]);
build_search_query([{Key, 'equals', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", quote_value(Value)])|Acc]);
build_search_query([{Key, 'neq', Value}|Rest], Acc) when Value =:= true;Value =:= false;is_integer(Value) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", Value])|Acc]);
build_search_query([{Key, 'neq', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", quote_value(Value)])|Acc]);
build_search_query([{Key, 'not_equals', Value}|Rest], Acc) when Value =:= true;Value =:= false;is_integer(Value) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", Value])|Acc]);
build_search_query([{Key, 'not_equals', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", quote_value(Value)])|Acc]);
build_search_query([{Key, 'in', Value}|Rest], Acc) when is_list(Value) ->
    build_search_query(Rest, [lists:concat(["(", string:join(lists:map(fun(Val) ->
                                    lists:concat([Key, ":", quote_value(Val)])
                            end, Value), " OR "), ")"])|Acc]);
build_search_query([{Key, 'not_in', Value}|Rest], Acc) when is_list(Value) ->
    build_search_query(Rest, [lists:concat(["(", string:join(lists:map(fun(Val) ->
                                    lists:concat(["NOT ", Key, ":", quote_value(Val)])
                            end, Value), " AND "), ")"])|Acc]);
build_search_query([{Key, 'in', {Min, Max}}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", "[", Min, " TO ", Max, "]"])|Acc]);
build_search_query([{Key, 'not_in', {Min, Max}}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", "[", Min, " TO ", Max, "]"])|Acc]);
build_search_query([{Key, 'gt', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", "{", Value, " TO *}"])|Acc]);
build_search_query([{Key, 'lt', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", "{* TO ", Value, "}"])|Acc]);
build_search_query([{Key, 'ge', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", "[", Value, " TO *]"])|Acc]);
build_search_query([{Key, 'le', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", "[* TO ", Value, "]"])|Acc]);
build_search_query([{Key, 'matches', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", Value])|Acc]);
build_search_query([{Key, 'not_matches', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", Value])|Acc]);
build_search_query([{Key, 'contains', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat([Key, ":", escape_value(Value)])|Acc]);
build_search_query([{Key, 'not_contains', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", Key, ":", escape_value(Value)])|Acc]);
build_search_query([{Key, 'contains_all', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["(", string:join(lists:map(fun(Val) ->
                                lists:concat([Key, ":", escape_value(Val)])
                        end, Value), " AND "), ")"])|Acc]);
build_search_query([{Key, 'not_contains_all', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", "(", string:join(lists:map(fun(Val) ->
                                lists:concat([Key, ":", escape_value(Val)])
                        end, Value), " AND "), ")"])|Acc]);
build_search_query([{Key, 'contains_any', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["(", string:join(lists:map(fun(Val) ->
                                lists:concat([Key, ":", escape_value(Val)])
                        end, Value), " OR "), ")"])|Acc]);
build_search_query([{Key, 'contains_none', Value}|Rest], Acc) ->
    build_search_query(Rest, [lists:concat(["NOT ", "(", string:join(lists:map(fun(Val) ->
                                lists:concat([Key, ":", escape_value(Val)])
                        end, Value), " OR "), ")"])|Acc]).

quote_value(Value) ->
    quote_value(Value, []).

quote_value([], Acc) ->
    [$"|lists:reverse([$"|Acc])];
quote_value([$"|T], Acc) ->
    quote_value(T, lists:reverse([$\\, $"], Acc));
quote_value([H|T], Acc) ->
    quote_value(T, [H|Acc]).

escape_value(Value) ->
    escape_value(Value, []).

escape_value([], Acc) ->
    lists:reverse(Acc);
escape_value([H|T], Acc) when H=:=$+; H=:=$-; H=:=$&; H=:=$|; H=:=$!; H=:=$(; H=:=$);
                              H=:=$[; H=:=$]; H=:=${; H=:=$}; H=:=$^; H=:=$"; H=:=$~;
                              H=:=$*; H=:=$?; H=:=$:; H=:=$\\ ->
    escape_value(T, lists:reverse([$\\, H], Acc));
escape_value([H|T], Acc) ->
    escape_value(T, [H|Acc]).

riak_search_encode_key(K) ->
    list_to_binary(atom_to_list(K)).

riak_search_encode_value(V) when is_list(V) ->
  list_to_binary(V);
riak_search_encode_value(V) ->
    V.

riak_search_decode_data(Data) ->
    [{riak_search_decode_key(K), riak_search_decode_value(V)} || {K, V} <- Data].

riak_search_decode_key(K) ->
    list_to_atom(binary_to_list(K)).

riak_search_decode_value(V) when is_binary(V) ->
  binary_to_list(V);
riak_search_decode_value(V) ->
    V.

%% Riak 2 introduced bucket type
type_to_index(Type) when is_atom(Type) ->
  type_to_index(atom_to_list(Type));
type_to_index(Type) when is_list(Type) ->
  list_to_binary(string:join([bucket_type(),Type,"idx"],"_")).

bucket_type() ->
  boss_env:get_env(riaks2_rt,[]).

schema_prefix() ->
  case boss_env:get_env(riaks2_schema_prefix,[]) of
    undefined                   -> bucket_type();
    Prefix when is_list(Prefix) -> Prefix;
    Prefix when is_atom(Prefix) -> list_to_atom(Prefix)
  end.

create_schema(Conn, Type) ->
  Schema = type_to_schema(Type),
  case file:read_file("src/model/" ++ Schema  ++ ".xml") of
    {error, R} -> io:format("~p not exist~n", [Schema]), {error, R};
    {ok, SchemaData} ->  
			case riakc_pb_socket:create_search_schema(Conn, list_to_binary(Schema), SchemaData) of
				ok -> io:format("Schema is created and registered:~p ~n", [Schema]), {ok, Schema};
				{error, Reason} -> io:format("Failed to create schema:~p Reason:~p (Make sure ~p file exists.)~n", [Schema, Reason, "src/model/" ++ Schema  ++ ".xml"]), {error, Reason}
			end
  end.

create_search_index(Conn, Type, Opts) ->
  Index = type_to_index(Type),
  case riakc_pb_socket:get_search_index(Conn, Index) of
    {error, <<"notfound">>} ->
      Schema = type_to_schema(Type),
      Result = riakc_pb_socket:create_search_index(Conn, Index, list_to_binary(Schema), Opts),
      io:format("Please wait for 2 secs...~n"),
      timer:sleep(2000),
      Result;
    {ok, _} ->
      io:format("Index:~p exists already! You must remove index first~n",[Index]),
      ok
  end.

set_search_index(Conn, Type) ->
  Index = type_to_index(Type),
  Bucket = type_to_bucket(Type),
  case riakc_pb_socket:set_search_index(Conn, Bucket, Index) of
    ok              -> io:format("Search Index:~p is set~n",[Index]);
    {error, Reason} -> io:format("Failed to set the index(~p) on the bucket(~p) Reason:~p ~n", [Index, Bucket, Reason])
  end.

add_search_index(Conn, Type, Opts) ->
  case create_search_index(Conn, Type, Opts) of
    ok           -> set_search_index(Conn, Type);
    Result       -> io:format("No index created:~p~n", [Result])
  end. 

type_to_schema(Type) when is_atom(Type) ->
  type_to_schema(atom_to_list(Type));
type_to_schema(Type) when is_list(Type) ->
  string:join([schema_prefix(), "schema", Type],"_").

setup_model(Model) when is_list(Model) ->
  setup_model(list_to_atom(Model));
setup_model(Model) when is_atom(Model) ->
  setup_model(Model, []).

setup_model(Model, Opts) when is_list(Model) ->
  setup_model(list_to_atom(Model), Opts);
setup_model(Model, Opts) when is_atom(Model) ->
  {ok, Conn} = riakc_pb_socket:start_link(?RS2_DB_HOST, ?RS2_DB_PORT),
  case create_schema(Conn, Model) of
    {ok, _} ->
			timer:sleep(3000),
			add_search_index(Conn, Model, Opts);
    {error, _Reason} ->
      error
  end,
  riakc_pb_socket:stop(Conn).

clear_index(Model) when is_list(Model) ->
  clear_index(list_to_atom(Model));
clear_index(Model) when is_atom(Model) ->
  {ok, Conn} = riakc_pb_socket:start_link(?RS2_DB_HOST, ?RS2_DB_PORT),
  Index = type_to_index(Model),
  case riakc_pb_socket:get_search_index(Conn, Index) of
    {error, <<"notfound">>} ->
      io:format("Index(~p) not exists!!~n", [Index]);
    {ok, _} ->
			Bucket = type_to_bucket(Model),
			BucketProps = [{search_index, <<"_dont_index_">>}],
			io:format("Clear bucket property..~n"),
			riakc_pb_socket:set_bucket(Conn, Bucket, BucketProps),
			timer:sleep(1000),
			io:format("Delete search index..~n"),
			riakc_pb_socket:delete_search_index(Conn, Index), 
			io:format("Done!~n")
  end,
  riakc_pb_socket:stop(Conn).

reindex(Model) when is_list(Model) ->
  reindex(list_to_atom(Model));
reindex(Model) when is_atom(Model) ->
  Update = fun (RiakKey) ->
             K = lists:concat([Model, "-", binary_to_list(RiakKey)]), 
             Record = boss_db:find(K),
             Record:save()
           end,
  {ok, Conn} = riakc_pb_socket:start_link(?RS2_DB_HOST, ?RS2_DB_PORT),
  Bucket = type_to_bucket(Model),
  {ok, Keys} = riakc_pb_socket:list_keys(Conn, Bucket),
  io:format("Re-index ~p ~p record(s)..~n", [length(Keys), Model]),
  lists:map(Update, Keys),
  io:format("Done!~n"),
  riakc_pb_socket:stop(Conn).

re_index(Model) ->
  re_index(Model, []).

re_index(Model, Opts) ->
  clear_index(Model),
  timer:sleep(2000),
  setup_model(Model, Opts),
  timer:sleep(2000),
  reindex(Model).













