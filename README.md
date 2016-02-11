ChicagoBoss Riak Search 2.0 DB Adapter
======================================

Enable Riak Search 2.0 (Solr-based) in ChicagoBoss. 

Since `solr` needs schema files, this adapter has some API to register schmea, setup index but you have to run them in the boss console.

Each boss model will be a bucket and the whole application will be using a single bucket type. 

The drawback is that, as Basho people told me, solr search would be slow when index is set on bucket, not bucket type.

So, I have basically eliminated the possiblility of using more than one bucket type.

This is needed: https://github.com/basho/riak-erlang-client/tree/2.1.1 in rebar.config under `boss_db`

    {riakc,         ".*",   {git, "git://github.com/basho/riak-erlang-client.git", {tag, "2.1.1"}}},

You can give a ID so you can 

    user:new("1234567", "Tom", "tom@gmail.com") a new record with defined ID "1234567"

This way, you use the pre-defined key since Riak is Key-Value store.

Still, be Warned
----------------
* Solr rows defaultly returns 10 records only, so I hard-code 10 million maximum if you did not give a limit
* Make sure you follow the configuration below - it is quite easy but not simple - too many factors in play.
* You need to create and activate the bucket type before everything else, set allow_mult to false 
* You need to register extractor into riak. You can find the file at the root directory.
* Index name is set per bucket and it follows a naming convention "&lt;appname&gt;_&lt;model&gt;_idx"
* Schema xml file must be manually created and it follows a naming convention "&lt;appname&gt;_schema_&lt;model&gt;.xml"

Supported Solr Field Types
-------------------------
string
string_lc:lower case
float
boolean
int
date

Configure
---------
1. Install extractor

It is an erlang proplist extractor.

        Compile the boss_model_extractor.erl into .beam file
        Move it to /opt/beams/
        Edit `advanced.config` to add the path

        [
        	...
        	{vm_args, [
        	  {"-pa /opt/beams", ""}
        	]},
            ...
        ].
        
        Restart riak

        $>riak attach
        $>yz_extractor:register("application/chicagobossmodel", boss_model_extractor).
      
        You should see all the registered extractor.

        In your boss.config, make sure:
  
        {db_adapter, riaks2},
        {riaks2_rt, "appname"},
        {riaks2_schema_prefix, "appname"},

        riaks2_rt is bucket type you created. riaks2_schema_prefix is the prefix for the schema file.
        If your model is player, your schema file is appname_schema_player.xml in the src/model directory
   
2. Make sure your the adapter has the correct macro

        %% Host and port for protocal buffer 
        -define(RS2_DB_HOST, "127.0.0.1").
        -define(RS2_DB_PORT, 8087).
    
Create your the bucket type manually (using default `n_val`)

        $> riak-admin bucket-type create <application_name>
        $> riak-admin bucket-type activate <application_name>
      
Set your own `n_val` if you have to

        $> riak-admin bucket-type create <applcation_name> '{"props":{"n_val":1}}'

But whatever `n_val` is, if it's not the default 3, you have to run `setup_model/2` instead of `setup_model/1` later.

And you might also want to change `allow_mult` to false

        $> riak-admin bucket-type update <bucket_type> '{"props":{"allow_mult":false}}'


2. Create Boss Model
-----------------
2.1. Create boss model
2.2. Create a schema file under same folder(src/model/): <appname>_schema_<model>.xml

        Example:"src/model/appname_schema_rating.xml"

        <?xml version="1.0" encoding="UTF-8" ?>
        <schema name="appname_schema_rating" version="1.5">
          <fields>
            <!-- comment model fields -->
            <field name="user_id" type="string" indexed="true" stored="true" multiValued="false"/>
            <field name="sore" type="int" indexed="true" stored="true" multiValued="false"/>
            <field name="published" type="boolean" indexed="true" stored="true" multiValued="false"/>
            <field name="created" type="date" indexed="true" stored="true" multiValued="false"/>
            
            <!-- other required fields here -->
            <field name="_yz_id"   type="_yz_str" indexed="true" stored="true"  multiValued="false" required="true"/>
            <field name="_yz_ed"   type="_yz_str" indexed="true" stored="false" multiValued="false"/>
            <field name="_yz_pn"   type="_yz_str" indexed="true" stored="false" multiValued="false"/>
            <field name="_yz_fpn"  type="_yz_str" indexed="true" stored="false" multiValued="false"/>
            <field name="_yz_vtag" type="_yz_str" indexed="true" stored="false" multiValued="false"/>
            <field name="_yz_rk"   type="_yz_str" indexed="true" stored="true"  multiValued="false"/>
            <field name="_yz_rt"   type="_yz_str" indexed="true" stored="true"  multiValued="false"/>
            <field name="_yz_rb"   type="_yz_str" indexed="true" stored="true"  multiValued="false"/>
            <fi eld name="_yz_err"  type="_yz_str" indexed="true" stored="false" multiValued="false"/>
        
            <!-- catch all -->
            <dynamicField name="*" type="ignored"  />
          </fields>
    
          <uniqueKey>_yz_id</uniqueKey>
    
          <types>
            <!-- YZ String: Used for non-analyzed fields -->
            <fieldType name="_yz_str" class="solr.StrField" sortMissingLast="true" />

            <fieldType name="string" class="solr.StrField" sortMissingLast="true" />
            <fieldType name="boolean" class="solr.BoolField" sortMissingLast="true"/>
            <fieldType name="date" class="solr.TrieDateField"/>
            <fieldType name="int" class="solr.TrieIntField" precisionStep="0" positionIncrementGap="0"/>
            
            <!-- Analyzed fields -->
            <fieldType name="string_lc" class="solr.TextField">
              <analyzer>
                <tokenizer class="solr.StandardTokenizerFactory"/>
                <filter class="solr.LowerCaseFilterFactory"/>
              </analyzer>
            </fieldType>
  
            <!-- Required -->
            <fieldtype name="ignored" stored="false" indexed="false" multiValued="true" class="solr.StrField" />
          </types>
        
        </schema>

3. Setup Model & Re-indexing Model Records

    Run this in boss console for each model:
    
        #1 if your n_val on the bucket is default 3
        > boss_db_adapter_riaks2:setup_model(<model>)
        
        #2 If your n_val is not default 3
        > boss_db_adapter_riaks2:setup_mode(<model>, [{n_val, 1}]).

        #3 If you did it wrong, you can clear the index
        > boss_db_adapter_riaks2:clear_index(<model>)

        #4 Index all all existing records of the model
        # new field value will be "undefined"
        > boss_db_adapter_riaks2:index(<model>) 

        # Reindex (clear, setup, index in sequence) (  #3 -> #1/2 -> #4 )
        > boss_db_adapter_riaks2:reindex(<model>)
        > boss_db_adapter_riaks2:reindex(<model>, [{n_val, 1}]).

This will 
* register schema file
* create index based on the schema and n_val
* set the search index on the bucket associated to the model

Verify
------
    http://127.0.0.1:8098/search/schema/<appname>_schema_<model> # schema is registered
    http://127.0.0.1:8098/search/index/<appname>_<model>_idx ( After you have saved something ) # index exists
    http://127.0.0.1:8098/types/<appname>/buckets/<bucket_name>/props (<bucket_name> is the plural form of <model>) # verify index is set on bucket

Done! Now you can use boss_db module.

Other information
-----------------
Solr Admin: http://127.0.0.1:8093/internal_solr/#/

















BossDB: A sharded, caching, pooling, evented ORM for Erlang
===========================================================
[![Build Status](https://travis-ci.org/ErlyORM/boss_db.svg?branch=master)](https://travis-ci.org/ErlyORM/boss_db)

Supported databases
-------------------

* *NEW* DynamoDB (experimental)
* Mnesia
* MongoDB
* MySQL
* PostgreSQL
* Riak
* Tokyo Tyrant

Complete API references
-----------------------

Querying: http://www.chicagoboss.org/doc/api-db.html

Records: http://www.chicagoboss.org/doc/api-record.html

BossNews: http://chicagoboss.org/doc/api-news.html

Write an adapter: https://github.com/ChicagoBoss/ChicagoBoss/wiki/DB-Adapter-Quickstart

Usage
-----

    boss_db:start(DBOptions),
    boss_cache:start(CacheOptions), % If you want cacheing with Memcached
    boss_news:start() % Mandatory! Hopefully will be optional one day

    DBOptions = [
        {adapter, mock | tyrant | riak | mysql | pgsql | mnesia | mongodb},
        {db_host, HostName::string()},
        {db_port, PortNumber::integer()},
        {db_username, UserName::string()},
        {db_password, Password::string()},
        {db_database, Database::string()},
        {shards, [
            {db_shard_models, [ModelName::atom()]},
            {db_shard_id, ShardId::atom()},
            {db_host, _}, {db_port, _}, ...
        ]},
        {cache_enable, true | false},
        {cache_exp_time, TTLSeconds::integer()}
    ]

    CacheOptions = [
        {adapter, memcached_bin | redis | ets},
        {cache_servers, MemcachedCacheServerOpts | RedisCacheServerOpts | EtsCacheServerOpts}
    ]

    MemcachedCacheServerOpts = [
        { HostName::string() = "localhost"
        , Port::integer()    = 11211
        , Weight::integer()  = 1
        }, ...
    ]

    RedisCacheServerOpts = [
        {host,      HostName::string()   = "localhost"},
        {port,      Port::integer()      = 6379},
        {pass,      Password::string()   = undefined},
        {db,        Db::integer()        = 0},
        {reconnect, Reconnect::boolean() = true}
    ]

    EtsCacheServerOpts = [
        {ets_maxsize,   MaxSize::integer() = 32 * 1024 * 1024},
        {ets_threshold, Threshold::float() = 0.85},
        {ets_weight,    Weight::integer()  = 30}
    ]

Introduction
------------

BossDB is a compiler chain and run-time library for accessing a database via
Erlang parameterized modules. It solves the age-old problem of retrieving
named fields without resorting to verbosities like proplists:get_value/2 or
dict:find/2. For example, if you want to look up a puppy by ID and print its
name, you would write:

    Puppy = boss_db:find("puppy-1"),
    io:format("Puppy's name: ~p~n", [Puppy:name()]).

Functions for accessing field names are generated automatically. All you need
to do is create a model file and compile it with boss_record_compiler. Example:

The model file, call it puppy.erl:

    -module(puppy, [Id, Name, BreedId]).

Then compile it like:

    {ok, puppy} = boss_record_compiler:compile("puppy.erl")

...and you're ready to go.

You can also enable boss_db_rebar plugin in your rebar.config to automatize
compilation:

    {plugin_dir, ["deps/boss_db/priv/rebar"]}.
    {plugins, [boss_db_rebar]}.
    {boss_db_opts, [
        {model_dir, "src/model"},
    ]}.

Associations
------------

BossDB supports database associations. Suppose you want to model the dog breed
(golden retriever, poodle, etc). You would create a model file with a special
"-has" attribute, like:

    -module(breed, [Id, Name]).
    -has({puppies, many}).

Then back in puppy.erl you'd add a "-belongs_to" attribute:

    -module(puppy, [Id, Name, BreedId]).
    -belongs_to(breed).

Once you've compiled breed.erl with boss_record_compiler, you can print a puppy's
associated breed like:

    Breed = Puppy:breed(),
    io:format("Puppy's breed: ~p~n", [Breed:name()]).

Similarly, you could iterate over all the puppies of a particular breed:

    Breed = boss_db:find("breed-47"),
    lists:map(fun(Puppy) -> 
            io:format("Puppy: ~p~n", [Puppy:name()]) 
        end, Breed:puppies())

Querying
--------

You can search the database with the boss_db:find functions. Example:

    Puppies = boss_db:find(puppy, [{breed_id, 'equals', "breed-47"}])

This is somewhat verbose. If you compile the source file with boss_compiler,
you'll be able to write the more simple expression:

    Puppies = boss_db:find(puppy, [breed_id = "breed-47"])

BossDB supports many query operators, as well as sorting, offsets, and limits;
see the API references at the top.

Validating and saving
---------------------

To create and save a new record, you would write:

    Breed = breed:new(id, "Golden Retriever"),
    {ok, SavedBreed} = Breed:save()

You can provide validation logic by adding a validation_tests/0 function
to your model file, e.g.

    -module(breed, [Id, Name]).
    -has({puppies, many}).
    -export([validation_tests/0]).

    validation_tests() ->
        [{fun() -> length(Name) > 0 end,
            "Name must not be empty!"}].

If validation fails, the save/0 function will return a list of error messages
instead of the saved record.

You can also provide spec strings in the parameter declaration if you want to
validate the attribute types before saving, e.g.

    -module(puppy, [Id, Name::string(), BirthDate::datetime()]).

Accepted types are:

* string()
* binary()
* datetime()
* date()
* timestamp() [e.g. returned by erlang:now()]
* integer()
* float()

If the type validation fails, then validation_tests/0 will not be called.

Working with existing SQL databases
-----------------------------------

By default, SQL columns must be underscored versions of the attribute names,
and SQL tables must be plural versions of the model names. (If the model is
"puppy", the database table should be "puppies".)

You may want to override these defaults if you are working with an existing
database. To specify your own column and table names, you can use the
-columns() and -table() attributes in a model file like so:

    -module(puppy, [Id, Name]).
    -columns([{id, "puppy_id"}, {name, "puppy_name"}]).
    -table("puppy_table").

Events
------

BossDB provides two kinds of model events: synchronous save hooks, and
asynchronous notifications via BossNews. Save hooks are simple; just
define one or more of these functions in your model file:

    before_create/0 -> ok | {ok, ModifiedRecord} | {error, Reason}
    before_update/0 -> ok | {ok, ModifiedRecord} | {error, Reason}
    after_create/0 
    after_update/0
    before_delete/0 -> ok | {error, Reason}

BossNews is more complicated but also more powerful. It is a notification
system that executes asynchronously, so the code that calls "save" does
not have to wait for callbacks to complete. The central concept in BossNews
is a "watch", which is an event observer. You can create and destroy watches
programmatically:

    {ok, WatchId} = boss_news:watch(TopicString, CallBack),
    boss_news:cancel_watch(WatchId)

Four kinds of topic strings are supported:

    "puppies" => watch for new and deleted Puppy records
    "puppy-42.*" => watch all attributes of Puppy #42
    "puppy-*.name" => watch the "name" attribute of all Puppy records
    "puppy-*.*" => watch all attributes of all Puppy records

The callback is passed two or three arguments: the event name
(created/updated/deleted), information about the event (i.e. the new and old
values of the watched record), and optionally user information passed as the
third argument to boss_news:watch/3.

BossNews is suited to providing real-time notifications and alerts. For example,
if you want to log each time a puppy's name is changed,

    boss_news:watch("puppy-*.name", 
            fun(updated, {Puppy, 'name', OldName, NewName}) ->
                error_logger:info_msg("Puppy's name changed from ~p to ~p", [OldName, NewName])
            end)

For more details see the documentation at http://www.chicagoboss.org/doc/api-news.html


Caching
-------

If caching is enabled, queries and records are automatically cached. BossDB
uses BossNews events to automatically invalidate out-of-date cache entries; you do
not need to write any cache logic in your save hooks.


Sharding
--------

Vertical sharding is supported via the db_shards config option. Simply add shard-specific
configuration in a proplist along with an extra config parameter called db_shard_models,
which should be a list of models (atoms) in the shard.


Pooling
-------

BossDB uses Poolboy to create a connection pool to the database. Connection pooling
is supported with all databases.


Primary Keys
------------

The Id field of each model is assumed to be an integer supplied by the
database (e.g., a SERIAL type in Postgres or AUTOINCREMENT in MySQL).
Specifying an Id value other than the atom 'id' for a new record will
result in an error.

When using the mock or pgsql adapters, the Id may have a type of
::uuid().  This will coerce boss_db into generating a v4 UUID for the
Id field before saving the record (in other words, the UUID is
provided by boss_db and not by the application nor by the DB).  UUIDs
are useful PKs when data are being aggregated from multiple sources.

The default Id type ::serial() may be explicitly supplied.  Note that
all Id types, valid or otherwise, pass type validation.
