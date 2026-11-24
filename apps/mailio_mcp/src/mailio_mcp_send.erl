%%% @doc Idempotent send. A send is bound to (account, draft revision,
%%% payload) by an idempotency key. A repeated or concurrent call returns
%%% the recorded status; a changed payload under the same key is refused;
%%% a fresh key cannot submit a revision twice. If the connection drops
%%% after the body was sent, the record becomes outcome_unknown and is never
%%% resent automatically. Records are persisted before the connection is
%%% opened, so a crash in between also ends as outcome_unknown.
-module(mailio_mcp_send).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([submit/4, status/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Submit a draft revision.
-spec submit(binary(), binary(), integer(), binary()) -> {ok, map()} | {error, term()}.
submit(Principal, DraftId, Revision, Key) ->
    gen_server:call(?MODULE, {submit, Principal, DraftId, Revision, Key}, 120000).

-spec status(binary(), binary()) -> {ok, map()} | {error, term()}.
status(Principal, DraftId) ->
    case mailio_mcp_draft:get(Principal, DraftId) of
        {ok, D} ->
            Recs = mailio_mcp_store:fold(
                send,
                fun
                    ({rev, I, R}, V, A) when I =:= DraftId -> [{R, V} | A];
                    (_, _, A) -> A
                end,
                []
            ),
            {ok, #{draft => D, records => lists:sort(Recs)}};
        E ->
            E
    end.

init([]) ->
    %% Anything still "sending" belonged to a process that is gone.
    Fix = mailio_mcp_store:fold(
        send,
        fun
            ({rev, _, _} = K, #{status := sending} = V, A) -> [{K, V} | A];
            (_, _, A) -> A
        end,
        []
    ),
    lists:foreach(
        fun({K, V}) ->
            mailio_mcp_store:put(send, K, V#{
                status => outcome_unknown,
                note => <<"The service stopped while this message was being submitted.">>
            })
        end,
        Fix
    ),
    {ok, #{waiters => #{}}}.

handle_call({submit, Principal, DraftId, Revision, Key}, From, #{waiters := W} = S) ->
    maybe
        {ok, D} ?= mailio_mcp_draft:get(Principal, DraftId),
        AccId = maps:get(account, D),
        ok ?= mailio_mcp_authz:check(Principal, AccId, send),
        {ok, _} ?=
            mailio_mcp_authz:check_identity(
                Principal, AccId, maps:get(address, maps:get(from, D))
            ),
        ok ?= current_revision(D, Revision),
        Hash = mailio_mcp_draft:payload_hash(D),
        RevKey = {rev, DraftId, Revision},
        IdemKey = {idem, AccId, Key},
        case mailio_mcp_store:get(send, IdemKey) of
            {ok, #{rev := RevKey, hash := Hash}} ->
                {ok, Rec} = mailio_mcp_store:get(send, RevKey),
                existing(Rec, RevKey, From, W, S, D, Key, Principal);
            {ok, _Other} ->
                {reply, {error, idempotency_key_reused}, S};
            error ->
                case mailio_mcp_store:get(send, RevKey) of
                    {ok, #{status := St} = Rec} when St =/= failed_temporary ->
                        {reply, {error, {already_submitted, out(Rec, D)}}, S};
                    _ ->
                        start(D, RevKey, IdemKey, Hash, Key, Principal, From, W, S)
                end
        end
    else
        {error, _} = E -> {reply, E, S}
    end.

current_revision(D, Rev) ->
    case maps:get(revision, D) of
        Rev -> ok;
        Cur -> {error, {stale_revision, Cur}}
    end.

existing(#{status := sending}, RevKey, From, W, S, _D, _Key, _P) ->
    {noreply, S#{waiters := maps:update_with(RevKey, fun(L) -> [From | L] end, [From], W)}};
existing(#{status := failed_temporary}, RevKey, From, W, S, D, Key, P) ->
    %% Nothing was submitted last time: the same key may try again.
    {ok, Old} = mailio_mcp_store:get(send, RevKey),
    start(D, RevKey, {idem, maps:get(account, D), Key}, maps:get(hash, Old), Key, P, From, W, S);
existing(Rec, _RevKey, _From, _W, S, D, _, _) ->
    {reply, {ok, out(Rec, D)}, S}.

start(D, RevKey, IdemKey, Hash, Key, Principal, From, W, S) ->
    AccId = maps:get(account, D),
    Rec = #{
        status => sending,
        key => Key,
        hash => Hash,
        account => AccId,
        draft => maps:get(id, D),
        revision => maps:get(revision, D),
        message_id => maps:get(message_id, D),
        started_at => erlang:system_time(second),
        principal => Principal
    },
    mailio_mcp_store:put(send, RevKey, Rec),
    mailio_mcp_store:put(send, IdemKey, #{rev => RevKey, hash => Hash}),
    Self = self(),
    {ok, Account} = mailio_mcp_config:account(AccId),
    {Raw, Rcpts, EnvFrom} = mailio_mcp_draft:build(D),
    spawn(fun() ->
        Result = mailio_mcp_smtp:submit(Account, EnvFrom, Rcpts, Raw),
        Self ! {done, RevKey, Result}
    end),
    {noreply, S#{waiters := maps:update_with(RevKey, fun(L) -> [From | L] end, [From], W)}}.

handle_info({done, RevKey, Result}, #{waiters := W} = S) ->
    {ok, Rec} = mailio_mcp_store:get(send, RevKey),
    Rec2 = finish(Rec, Result),
    mailio_mcp_store:put(send, RevKey, Rec2),
    mailio_mcp_cache:invalidate_account(maps:get(account, Rec2)),
    {rev, DraftId, _} = RevKey,
    D =
        case mailio_mcp_store:get(draft, DraftId) of
            {ok, X} -> X;
            error -> #{}
        end,
    Out = out(Rec2, D),
    [gen_server:reply(F, {ok, Out}) || F <- maps:get(RevKey, W, [])],
    {noreply, S#{waiters := maps:remove(RevKey, W)}};
handle_info(_, S) ->
    {noreply, S}.

handle_cast(_, S) -> {noreply, S}.

finish(Rec, {ok, #{accepted := Acc, rejected := Rej, reply := Reply}}) ->
    Rec#{
        status =>
            case Rej of
                [] -> accepted;
                _ -> accepted_partial
            end,
        accepted_recipients => Acc,
        rejected_recipients => Rej,
        server_reply => Reply,
        finished_at => erlang:system_time(second)
    };
finish(Rec, {error, {rejected, Code, Text, Info}}) ->
    Rec#{
        status => rejected,
        server_code => Code,
        server_reply => Text,
        rejected_recipients => maps:get(rejected, Info, []),
        stage => maps:get(stage, Info, unknown),
        finished_at => erlang:system_time(second)
    };
finish(Rec, {error, {unknown, Reason}}) ->
    Rec#{
        status => outcome_unknown, reason => fmt(Reason), finished_at => erlang:system_time(second)
    };
finish(Rec, {error, {before_data, Reason}}) ->
    Rec#{
        status => failed_temporary, reason => fmt(Reason), finished_at => erlang:system_time(second)
    }.

fmt(R) -> iolist_to_binary(io_lib:format("~p", [R])).

%% Public view of a record.
out(Rec, D) ->
    St = maps:get(status, Rec),
    Base = #{
        <<"status">> => atom_to_binary(St),
        <<"draft_id">> => maps:get(draft, Rec),
        <<"revision">> => maps:get(revision, Rec),
        <<"account">> => maps:get(account, Rec),
        <<"message_id">> => maps:get(message_id, Rec),
        <<"delivered">> => <<"unknown">>
    },
    _ = D,
    Extra = lists:foldl(
        fun({K, Key, F}, A) ->
            case maps:find(K, Rec) of
                {ok, V} -> A#{Key => F(V)};
                error -> A
            end
        end,
        Base,
        [
            {accepted_recipients, <<"accepted_recipients">>, fun(X) -> X end},
            {rejected_recipients, <<"rejected_recipients">>, fun rej/1},
            {server_reply, <<"server_reply">>, fun(X) -> mailio_mcp_budget:shorten(X, 200) end},
            {reason, <<"reason">>, fun(X) -> mailio_mcp_budget:shorten(X, 200) end}
        ]
    ),
    Extra#{<<"note">> => note(St)}.

rej(L) ->
    [
        #{
            <<"recipient">> => maps:get(recipient, R, <<>>),
            <<"code">> => maps:get(code, R, 0),
            <<"reply">> => mailio_mcp_budget:shorten(maps:get(reply, R, <<>>), 120)
        }
     || R <- L
    ].

note(accepted) ->
    <<"Accepted for submission by the mail server. This is not a delivery confirmation.">>;
note(accepted_partial) ->
    <<"Accepted for submission for some recipients only; see rejected_recipients. Not a delivery confirmation.">>;
note(rejected) ->
    <<"The mail server refused the message. Nothing was sent.">>;
note(failed_temporary) ->
    <<
        "The submission failed before the message body was sent. Nothing was sent; repeat the call with "
        "the same idempotency_key to try again."
    >>;
note(outcome_unknown) ->
    <<
        "The connection ended after the message body was sent and no final reply was received. The "
        "message may or may not have been sent. It will not be resent automatically. Check the Sent "
        "folder or ask the recipient before sending again."
    >>;
note(sending) ->
    <<"Submission in progress.">>.
