-module(boss_model_extractor).
-compile(export_all).

%%%===================================================================
%%% Types
%%%===================================================================

%% Shorthand for existing types
-type datetime() :: calendar:datetime().
-type proplist() :: proplists:proplist().
-type timestamp() :: erlang:timestamp().

-type base64() :: binary().
-type hash() :: binary().
-type filename() :: string().

%% milliseconds
-type ms() :: non_neg_integer().
-type seconds() :: non_neg_integer().

%% An iso8601 datetime as binary, e.g. <<"20121221T000000">>.
-type iso8601() :: binary().
-type tree_name() :: atom().

%%%===================================================================
%%% Docs
%%%===================================================================

-type field_name() :: atom() | binary().
-type field_value() :: binary().
-type field() :: {field_name(), field_value()}.
-type fields() :: [field()].
-type doc() :: {doc, fields()}.

%%%===================================================================
%%% Extractors
%%%===================================================================

-type mime_type() :: binary() | string() | default.
-type extractor_name() :: atom().
-type extractor_def() :: extractor_name() | {extractor_name(), proplist()}.
-type extractor_map() :: [{mime_type(), extractor_def()}].

extract(Value) ->
    extract(Value, []).

extract(Value, Opts) ->
  extract_fields(binary_to_term(Value)).


extract_fields([]) ->
  [];
extract_fields(Value) ->
  [{list_to_atom(binary_to_list(K)),clean_value(V)} || {K,V} <- Value].

clean_value(Value) ->
    case is_number(Value) of
        true  -> list_to_binary(mochinum:digits(Value));
        false -> Value
    end.

