%%% @doc Protocol adapter behaviour.
%%%
%%% Normalizes IMAP (now), JMAP and POP3 (later) into one callback contract
%%% the sync engine drives. All ids on this boundary are protocol-native
%%% opaque terms; the mapping to immutable JMAP email ids happens in the
%%% sync engine, which persists the IMAP uid<->emailId map.
%%%
%%% The key idea is that adapters are dumb: they translate protocol to these
%%% calls and report changes since an opaque cursor. All cursoring, dedup,
%%% and conflict logic lives in the sync engine, so a new adapter only has
%%% to implement these callbacks.
-module(mailio_adapter).

-export_type([conn/0, remote_mailbox/0, remote_state/0, change/0, fetch_sink/0]).

%% Adapter-private connection handle.
-type conn() :: term().

%% A mailbox as the remote server sees it.
-type remote_mailbox() :: #{
    %% adapter-stable mailbox id (e.g. IMAP name)
    id := binary(),
    %% display name
    name := binary(),
    %% inbox|sent|drafts|trash|junk|archive|...
    role => atom() | undefined,
    parent_id => binary() | null,
    delimiter => binary(),
    %% raw server attributes (\Noselect, \Sent, ...)
    attrs => [binary()]
}.

%% Opaque per-mailbox cursor, adapter-encoded (for IMAP:
%% {uidvalidity, highestmodseq | undefined, uidnext}).
-type remote_state() :: binary() | initial.

%% A single change reported by fetch_changes_since/4.
-type change() ::
    {added, #{
        uid := term(),
        keywords := [binary()],
        internal_date => integer(),
        size => non_neg_integer()
    }}
    | {updated, #{uid := term(), keywords := [binary()]}}
    %% uid
    | {removed, term()}
    %% cursor invalid (UIDVALIDITY change): full resync
    | reset.

%% Streaming sink for raw message bytes.
-type fetch_sink() :: fun((iodata()) -> ok).

%%====================================================================
%% Callbacks
%%====================================================================

-callback connect(AccountCfg :: map()) -> {ok, conn()} | {error, mailio_error:error_map()}.

-callback close(conn()) -> ok.

-callback capabilities(conn()) -> #{atom() => boolean()}.

-callback list_mailboxes(conn()) ->
    {ok, [remote_mailbox()]} | {error, mailio_error:error_map()}.

%% Fetch changes for a mailbox since a cursor. Returns the changes, the new
%% cursor, and whether more changes remain (paging).
-callback fetch_changes_since(
    conn(),
    MailboxId :: binary(),
    remote_state(),
    Opts :: map()
) ->
    {ok, [change()], remote_state(), more | done}
    | {error, mailio_error:error_map()}.

%% Stream a message's raw RFC 5322 bytes to the sink.
-callback fetch_message(
    conn(),
    MailboxId :: binary(),
    Uid :: term(),
    fetch_sink()
) ->
    {ok, #{size := non_neg_integer()}} | {error, mailio_error:error_map()}.

-callback set_keywords(
    conn(),
    MailboxId :: binary(),
    Uid :: term(),
    Add :: [binary()],
    Remove :: [binary()]
) ->
    ok | {error, mailio_error:error_map()}.

-callback move(
    conn(),
    FromMailbox :: binary(),
    Uid :: term(),
    ToMailbox :: binary()
) ->
    {ok, NewUid :: term() | undefined} | {error, mailio_error:error_map()}.

-callback append(
    conn(),
    MailboxId :: binary(),
    Raw :: binary(),
    Keywords :: [binary()]
) ->
    {ok, Uid :: term() | undefined} | {error, mailio_error:error_map()}.

-callback expunge(conn(), MailboxId :: binary(), Uids :: [term()]) ->
    ok | {error, mailio_error:error_map()}.

%% Best-effort change notification. May report `not_supported'; the sync
%% engine then falls back to polling.
-callback watch(conn(), MailboxId :: binary(), Notify :: pid()) ->
    {ok, WatchRef :: term()} | {error, not_supported | mailio_error:error_map()}.

-callback unwatch(conn(), WatchRef :: term()) -> ok.

%% List all current message uids in a mailbox. Used by the sync engine to
%% reconcile expunges on servers without QRESYNC (diff against locally
%% known uids). Adapters that always report removals incrementally may omit
%% this.
-callback list_uids(conn(), MailboxId :: binary()) ->
    {ok, [term()]} | {error, mailio_error:error_map()}.

-optional_callbacks([watch/3, unwatch/2, append/4, move/4, expunge/3, list_uids/2]).
