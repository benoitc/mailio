%%% @doc Per-account session process and account helpers.
%%%
%%% In M3 this is intentionally small: it resolves the account's database
%%% name, ensures the database exists, and supervises the account writer.
%%% Protocol adapters, sync, and ingest workers are added under
%%% {@link mailio_account_sup} in later milestones.
-module(mailio_account).
-behaviour(gen_server).

-export([start_link/1, db_name/1, ingest_raw/3, ingest_raw/4, state_token/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {account_id :: binary(), db :: binary()}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(AccountId) ->
    gen_server:start_link(?MODULE, AccountId, []).

%% @doc Barrel database name for an account. barrel requires lowercase
%% `[a-z0-9_-]'; account ids are uppercase Crockford ULIDs, so they are
%% lowercased here (a bijection within that alphabet, so still unique).
-spec db_name(binary()) -> binary().
db_name(AccountId) when is_binary(AccountId) ->
    <<"mailio_acct_", (mailio_ascii:lower(AccountId))/binary>>.

%% @doc Ingest raw RFC 5322 bytes into a mailbox (no flags).
-spec ingest_raw(binary(), binary(), binary()) ->
    {ok, binary()} | {error, term()}.
ingest_raw(AccountId, MailboxId, Raw) ->
    ingest_raw(AccountId, MailboxId, Raw, #{}).

%% @doc Ingest raw bytes with options (`keywords', `received_at').
-spec ingest_raw(binary(), binary(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
ingest_raw(AccountId, MailboxId, Raw, Opts) ->
    mailio_account_writer:ingest(AccountId, MailboxId, Raw, Opts).

%% @doc Current JMAP state token for the account.
-spec state_token(binary()) -> mailio_cursor:token().
state_token(AccountId) ->
    Db = db_name(AccountId),
    {ok, _Changes, Hlc} = mailio_db:changes(Db, first),
    mailio_cursor:encode(Hlc).

%%====================================================================
%% gen_server
%%====================================================================

init(AccountId) ->
    Db = db_name(AccountId),
    {ok, _Pid} = mailio_db:ensure_db(Db),
    {ok, #state{account_id = AccountId, db = Db}}.

handle_call(db, _From, #state{db = Db} = State) ->
    {reply, {ok, Db}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
