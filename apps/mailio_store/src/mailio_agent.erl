%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Capability-scoped surface for AI agents.
%%%
%%% Gives an agent controlled, high-level access to mail without exposing
%%% raw protocol or storage internals: it searches, reads rendered threads,
%%% builds token-budgeted context windows, and applies tags/flags — each
%%% checked against the agent's {@link mailio_grant} (account, scope, and
%%% mailbox visibility) and audited. Every read result is filtered to the
%%% mailboxes the agent may see; every write is stamped with the agent id.
-module(mailio_agent).

-include("mailio_store.hrl").

-export([open/2, open/1]).
-export([search/3, get_thread/3, context_window/4]).
-export([tag/4, mark/4]).

-export_type([session/0]).

-opaque session() :: #{agent_id := binary(), grant := map()}.

%%====================================================================
%% Session
%%====================================================================

-spec open(binary(), binary()) -> {ok, session()} | {error, denied}.
open(AgentId, Secret) ->
    case mailio_grant:get(AgentId) of
        {ok, Grant} ->
            case usable(Grant) andalso secret_ok(Grant, Secret) of
                true -> {ok, #{agent_id => AgentId, grant => Grant}};
                false -> {error, denied}
            end;
        {error, _} ->
            {error, denied}
    end.

%% @doc Open without a secret (for grants created without one).
-spec open(binary()) -> {ok, session()} | {error, denied}.
open(AgentId) -> open(AgentId, <<>>).

usable(#{<<"revoked">> := true}) ->
    false;
usable(Grant) ->
    case maps:get(<<"expiresAt">>, Grant, null) of
        null -> true;
        Exp -> erlang:system_time(second) < Exp
    end.

secret_ok(#{<<"secretHash">> := null}, _Secret) ->
    true;
secret_ok(#{<<"secretHash">> := Hash}, Secret) ->
    binary:encode_hex(crypto:hash(sha256, Secret), lowercase) =:= Hash.

%%====================================================================
%% Read
%%====================================================================

%% @doc Search visible mail. Agent-friendly `Filters': `text', `from',
%% `to', `mailbox' (id), `unread' (bool), `has_attachment' (bool), `tag',
%% `after', `before', `limit'. Returns email summaries.
-spec search(session(), binary(), map()) -> {ok, [map()]} | {error, denied}.
search(Session, Account, Filters) ->
    with_access(
        Session,
        Account,
        search,
        fun(Perm) ->
            Filter = to_jmap_filter(Filters),
            Limit = maps:get(limit, Filters, 50),
            {ok, #{<<"ids">> := Ids}} =
                mailio_email:query(Account, #{filter => Filter, limit => Limit}),
            Db = mailio_account:db_name(Account),
            Summaries = lists:filtermap(
                fun(Id) -> summarize_visible(Db, Perm, Id) end, Ids
            ),
            {ok, Summaries}
        end
    ).

%% @doc Render a thread as a list of plain-text messages (no raw MIME),
%% restricted to the emails the agent may see.
-spec get_thread(session(), binary(), binary()) -> {ok, map()} | {error, denied | not_found}.
get_thread(Session, Account, ThreadId) ->
    with_access(
        Session,
        Account,
        read,
        fun(Perm) ->
            Db = mailio_account:db_name(Account),
            case mailio_db:get(Db, <<?ID_THREAD, ThreadId/binary>>) of
                {ok, Thread} ->
                    EmailIds = maps:get(<<"emailIds">>, Thread, []),
                    Messages = [
                        render_message(Db, Id)
                     || Id <- EmailIds, visible(Db, Perm, Id)
                    ],
                    {ok, #{
                        <<"id">> => ThreadId,
                        <<"messages">> => Messages,
                        <<"participants">> => participants(Messages)
                    }};
                {error, not_found} ->
                    {error, not_found}
            end
        end
    ).

%% @doc Build a token-budgeted context window for a thread or a single
%% email: newest messages in full, older ones degraded to one-line
%% summaries, until `max_tokens' is reached (~4 bytes/token estimate).
-spec context_window(session(), binary(), {thread, binary()} | {email, binary()}, map()) ->
    {ok, map()} | {error, denied | not_found}.
context_window(Session, Account, Target, Opts) ->
    MaxTokens = maps:get(max_tokens, Opts, 4000),
    case messages_for(Session, Account, Target) of
        {ok, Messages} ->
            {Text, Included, Truncated} = fill(lists:reverse(Messages), MaxTokens, [], [], false),
            Body = iolist_to_binary(lists:join(<<"\n\n">>, Text)),
            {ok, #{
                <<"text">> => Body,
                <<"included">> => Included,
                <<"truncated">> => Truncated,
                <<"token_estimate">> => byte_size(Body) div 4
            }};
        {error, _} = Err ->
            Err
    end.

messages_for(Session, Account, {thread, ThreadId}) ->
    case get_thread(Session, Account, ThreadId) of
        {ok, #{<<"messages">> := Ms}} -> {ok, Ms};
        Err -> Err
    end;
messages_for(Session, Account, {email, EmailId}) ->
    with_access(
        Session,
        Account,
        read,
        fun(Perm) ->
            Db = mailio_account:db_name(Account),
            case visible(Db, Perm, EmailId) of
                true -> {ok, [render_message(Db, EmailId)]};
                false -> {error, not_found}
            end
        end
    ).

%% Greedy newest-first fill within the token budget.
fill([], _Budget, Acc, Included, Trunc) ->
    {lists:reverse(Acc), lists:reverse(Included), Trunc};
fill([M | Rest], Budget, Acc, Included, Trunc) ->
    Full = message_block(M),
    Cost = byte_size(Full) div 4,
    case Cost =< Budget of
        true ->
            fill(
                Rest,
                Budget - Cost,
                [Full | Acc],
                [maps:get(<<"id">>, M) | Included],
                Trunc
            );
        false ->
            %% No room for the full message: append a one-line summary and
            %% mark truncated, but keep scanning older messages (cheap).
            Line = one_line(M),
            LCost = byte_size(Line) div 4,
            case LCost =< Budget of
                true ->
                    fill(
                        Rest,
                        Budget - LCost,
                        [Line | Acc],
                        [maps:get(<<"id">>, M) | Included],
                        true
                    );
                false ->
                    fill(Rest, Budget, Acc, Included, true)
            end
    end.

%%====================================================================
%% Write
%%====================================================================

%% @doc Add/remove custom keywords (tags) on visible emails. System
%% keywords (`$'-prefixed) are not settable here — use {@link mark/4}.
-spec tag(session(), binary(), [binary()], map()) -> {ok, map()} | {error, denied}.
tag(Session, Account, EmailIds, Change) ->
    with_access(
        Session,
        Account,
        tag,
        fun(Perm) ->
            Add = [K || K <- maps:get(add, Change, []), not system_kw(K)],
            Remove = [K || K <- maps:get(remove, Change, []), not system_kw(K)],
            Updated = apply_to_visible(
                Account,
                Perm,
                EmailIds,
                #{add_keywords => Add, remove_keywords => Remove}
            ),
            audit(Account, Session, tag, Updated),
            {ok, #{<<"updated">> => Updated}}
        end
    ).

%% @doc Set a read/flagged state on visible emails.
-spec mark(session(), binary(), [binary()], read | unread | flagged | unflagged) ->
    {ok, map()} | {error, denied}.
mark(Session, Account, EmailIds, Flag) ->
    with_access(
        Session,
        Account,
        mark,
        fun(Perm) ->
            Patch = mark_patch(Flag),
            Updated = apply_to_visible(Account, Perm, EmailIds, Patch),
            audit(Account, Session, {mark, Flag}, Updated),
            {ok, #{<<"updated">> => Updated}}
        end
    ).

mark_patch(read) -> #{add_keywords => [?KW_SEEN]};
mark_patch(unread) -> #{remove_keywords => [?KW_SEEN]};
mark_patch(flagged) -> #{add_keywords => [?KW_FLAGGED]};
mark_patch(unflagged) -> #{remove_keywords => [?KW_FLAGGED]}.

apply_to_visible(Account, Perm, EmailIds, Patch) ->
    Db = mailio_account:db_name(Account),
    lists:filtermap(
        fun(Id) ->
            case visible(Db, Perm, Id) of
                true ->
                    case mailio_account_writer:patch(Account, Id, Patch) of
                        ok -> {true, Id};
                        _ -> false
                    end;
                false ->
                    false
            end
        end,
        EmailIds
    ).

%%====================================================================
%% Enforcement
%%====================================================================

with_access(#{grant := Grant}, Account, Scope, Fun) ->
    case account_perm(Grant, Account) of
        {ok, Perm} ->
            case scope_allowed(Perm, Scope) of
                true -> Fun(Perm);
                false -> {error, denied}
            end;
        error ->
            {error, denied}
    end.

account_perm(#{<<"accounts">> := Accounts}, Account) ->
    case maps:find(Account, Accounts) of
        {ok, Perm} -> {ok, Perm};
        error -> error
    end;
account_perm(_, _) ->
    error.

scope_allowed(#{<<"scopes">> := Scopes}, Scope) ->
    lists:member(atom_to_binary(Scope, utf8), Scopes);
scope_allowed(_, _) ->
    false.

visible(Db, Perm, EmailId) ->
    case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
        {ok, Email} -> mailbox_visible(Perm, mailio_email:mailbox_ids(Email));
        {error, not_found} -> false
    end.

mailbox_visible(Perm, Mailboxes) ->
    Allow = maps:get(<<"mailboxAllow">>, Perm, <<"all">>),
    Deny = maps:get(<<"mailboxDeny">>, Perm, []),
    AllowOK =
        (Allow =:= <<"all">>) orelse
            lists:any(fun(M) -> lists:member(M, Allow) end, Mailboxes),
    DenyOK = not lists:any(fun(M) -> lists:member(M, Deny) end, Mailboxes),
    AllowOK andalso DenyOK.

%%====================================================================
%% Rendering / summaries
%%====================================================================

summarize_visible(Db, Perm, EmailId) ->
    case mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>) of
        {ok, Email} ->
            case mailbox_visible(Perm, mailio_email:mailbox_ids(Email)) of
                true -> {true, summary(Email)};
                false -> false
            end;
        {error, not_found} ->
            false
    end.

summary(Email) ->
    #{
        <<"id">> => mailio_email:id_of(Email),
        <<"threadId">> => mailio_email:thread_id(Email),
        <<"from">> => maps:get(<<"from">>, Email, null),
        <<"subject">> => maps:get(<<"subject">>, Email, null),
        <<"receivedAt">> => maps:get(<<"receivedAt">>, Email, null),
        <<"preview">> => maps:get(<<"preview">>, Email, <<>>),
        <<"keywords">> => maps:keys(maps:get(<<"keywords">>, Email, #{})),
        <<"hasAttachment">> => maps:get(<<"hasAttachment">>, Email, false)
    }.

render_message(Db, EmailId) ->
    {ok, Email} = mailio_db:get(Db, <<?ID_EMAIL, EmailId/binary>>),
    #{
        <<"id">> => EmailId,
        <<"from">> => maps:get(<<"from">>, Email, null),
        <<"to">> => maps:get(<<"to">>, Email, null),
        <<"sentAt">> => maps:get(<<"sentAt">>, Email, null),
        <<"subject">> => maps:get(<<"subject">>, Email, null),
        <<"text">> => body_text(Db, EmailId)
    }.

body_text(Db, EmailId) ->
    case mailio_db:get(Db, <<?ID_TEXT, EmailId/binary>>) of
        {ok, #{<<"body_text">> := T}} -> T;
        _ -> <<>>
    end.

message_block(M) ->
    From = addr_str(maps:get(<<"from">>, M, null)),
    Date = null_str(maps:get(<<"sentAt">>, M, null)),
    Text = maps:get(<<"text">>, M, <<>>),
    iolist_to_binary([<<"From: ">>, From, <<"  Date: ">>, Date, <<"\n">>, Text]).

one_line(M) ->
    From = addr_str(maps:get(<<"from">>, M, null)),
    Date = null_str(maps:get(<<"sentAt">>, M, null)),
    Subject = null_str(maps:get(<<"subject">>, M, null)),
    iolist_to_binary([<<"(earlier) ">>, From, <<" ">>, Date, <<": ">>, Subject]).

participants(Messages) ->
    lists:usort(
        lists:flatmap(
            fun(M) -> addr_emails(maps:get(<<"from">>, M, null)) end, Messages
        )
    ).

addr_emails(null) -> [];
addr_emails(List) -> [E || #{<<"email">> := E} <- List].

addr_str(null) -> <<"?">>;
addr_str([#{<<"email">> := E} | _]) -> E;
addr_str(_) -> <<"?">>.

null_str(null) -> <<>>;
null_str(V) when is_binary(V) -> V;
null_str(_) -> <<>>.

system_kw(<<"$", _/binary>>) -> true;
system_kw(_) -> false.

%%====================================================================
%% Audit
%%====================================================================

audit(Account, #{agent_id := AgentId}, Action, EmailIds) ->
    Db = mailio_account:db_name(Account),
    Doc = #{
        <<"id">> => <<"audit/", (mailio_id:ulid())/binary>>,
        <<"agentId">> => AgentId,
        <<"action">> => action_bin(Action),
        <<"emailIds">> => EmailIds,
        <<"at">> => erlang:system_time(second)
    },
    _ = mailio_db:put(Db, Doc),
    ok.

action_bin({mark, Flag}) -> <<"mark:", (atom_to_binary(Flag, utf8))/binary>>;
action_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

%%====================================================================
%% Agent filter -> JMAP filter
%%====================================================================

to_jmap_filter(Filters) ->
    Conds = lists:flatmap(fun filter_cond/1, maps:to_list(Filters)),
    case Conds of
        [] -> #{};
        [One] -> One;
        _ -> #{operator => 'AND', conditions => Conds}
    end.

filter_cond({text, V}) -> [#{text => V}];
filter_cond({from, V}) -> [#{from => V}];
filter_cond({to, V}) -> [#{to => V}];
filter_cond({subject, V}) -> [#{subject => V}];
filter_cond({mailbox, V}) -> [#{inMailbox => V}];
filter_cond({tag, V}) -> [#{hasKeyword => V}];
filter_cond({unread, true}) -> [#{notKeyword => ?KW_SEEN}];
filter_cond({unread, false}) -> [#{hasKeyword => ?KW_SEEN}];
filter_cond({has_attachment, V}) -> [#{hasAttachment => V}];
filter_cond({after_, V}) -> [#{after_ => V}];
filter_cond({before, V}) -> [#{before => V}];
filter_cond(_) -> [].
