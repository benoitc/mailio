%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Drafts. A draft belongs to one account and one permitted From
%%% identity. Each save creates a new revision; sending binds to a
%%% revision. Drafts are kept locally in the durable store.
-module(mailio_mcp_draft).

-export([save/2, get/2, put_back/1, payload_hash/1, build/1, summary/1]).

-define(MAX_RCPT, 50).

-spec save(binary(), map()) -> {ok, map()} | {error, term()}.
save(Principal, Args) ->
    case maps:get(<<"draft_id">>, Args, undefined) of
        undefined -> create(Principal, Args);
        Id -> update(Principal, Id, Args)
    end.

get(Principal, Id) ->
    case mailio_mcp_store:get(draft, Id) of
        {ok, #{principal := Principal} = D} ->
            case mailio_mcp_authz:check(Principal, maps:get(account, D), draft) of
                ok -> {ok, D};
                {error, _} -> {error, unknown_draft}
            end;
        _ ->
            {error, unknown_draft}
    end.

put_back(D) -> mailio_mcp_store:put(draft, maps:get(id, D), D).

%%--------------------------------------------------------------------

create(Principal, Args) ->
    maybe
        {ok, Reply} ?= reply_context(Principal, Args),
        {ok, AccId} ?= account_for(Principal, Args, Reply),
        ok ?= mailio_mcp_authz:check(Principal, AccId, draft),
        {ok, From} ?= pick_from(Principal, AccId, Args, Reply),
        {ok, To} ?= recipients(<<"to">>, Args, default_to(Reply, Args, AccId, Principal)),
        {ok, Cc} ?= recipients(<<"cc">>, Args, default_cc(Reply, Args, AccId, Principal, To)),
        {ok, Bcc} ?= recipients(<<"bcc">>, Args, []),
        ok ?= check_count(To ++ Cc ++ Bcc),
        Id = <<"d_", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
        Now = erlang:system_time(second),
        D0 = #{
            id => Id,
            principal => Principal,
            account => AccId,
            revision => 1,
            from => From,
            from_explicit => maps:is_key(<<"from">>, Args),
            to => To,
            cc => Cc,
            bcc => Bcc,
            subject => subject(Args, Reply),
            body => maps:get(<<"body">>, Args, <<>>),
            in_reply_to => reply_field(Reply, msgid),
            references => reply_refs(Reply),
            message_id => new_message_id(From),
            created_at => Now,
            updated_at => Now
        },
        ok ?= validate(D0),
        put_back(D0),
        {ok, summary(D0)}
    end.

update(Principal, Id, Args) ->
    maybe
        {ok, D} ?= get(Principal, Id),
        ok ?= not_sent(Id),
        AccId = maps:get(account, D),
        {ok, From} ?=
            case maps:get(<<"from">>, Args, undefined) of
                undefined -> {ok, maps:get(from, D)};
                _ -> pick_from(Principal, AccId, Args, none)
            end,
        {ok, To} ?= recipients(<<"to">>, Args, maps:get(to, D)),
        {ok, Cc} ?= recipients(<<"cc">>, Args, maps:get(cc, D)),
        {ok, Bcc} ?= recipients(<<"bcc">>, Args, maps:get(bcc, D)),
        ok ?= check_count(To ++ Cc ++ Bcc),
        D1 = D#{
            from => From,
            from_explicit => maps:get(from_explicit, D) orelse maps:is_key(<<"from">>, Args),
            to => To,
            cc => Cc,
            bcc => Bcc,
            subject => maps:get(<<"subject">>, Args, maps:get(subject, D)),
            body => maps:get(<<"body">>, Args, maps:get(body, D)),
            revision => maps:get(revision, D) + 1,
            updated_at => erlang:system_time(second)
        },
        ok ?= validate(D1),
        put_back(D1),
        {ok, summary(D1)}
    end.

%% A draft whose revision was accepted for submission, or whose outcome is
%% unknown, cannot be edited: start a new draft instead.
not_sent(Id) ->
    Blocked = mailio_mcp_store:fold(
        send,
        fun
            ({rev, I, _}, #{status := S}, A) when I =:= Id ->
                A orelse lists:member(S, [accepted, accepted_partial, outcome_unknown, sending]);
            (_, _, A) ->
                A
        end,
        false
    ),
    case Blocked of
        true -> {error, draft_already_sent};
        false -> ok
    end.

validate(#{to := To, cc := Cc, bcc := Bcc, subject := S, body := B}) ->
    case To ++ Cc ++ Bcc of
        [] -> {error, no_recipients};
        _ when byte_size(S) > 998 -> {error, subject_too_long};
        _ when byte_size(B) > 1048576 -> {error, body_too_large};
        _ -> ok
    end.

check_count(L) when length(L) > ?MAX_RCPT -> {error, too_many_recipients};
check_count(_) -> ok.

%%--------------------------------------------------------------------
%% Reply context

reply_context(Principal, Args) ->
    case maps:get(<<"reply_to">>, Args, undefined) of
        undefined ->
            {ok, none};
        Handle ->
            maybe
                {ok, AccId, Loc, _} ?= mailio_mcp_view:loc_from_handle(msg, Principal, Handle),
                ok ?= mailio_mcp_authz:check(Principal, AccId, read),
                {ok, Account} = mailio_mcp_config:account(AccId),
                {ok, Hit} ?=
                    mailio_mcp_adapter:call(Account, read_message, [Loc, #{text => false}]),
                {ok, #{account => AccId, hit => Hit}}
            end
    end.

account_for(Principal, Args, none) ->
    case mailio_mcp_authz:select_accounts(Principal, Args) of
        {ok, [One]} -> {ok, One};
        {ok, _} -> {error, account_ids_required};
        {error, _} = E -> E
    end;
account_for(Principal, Args, #{account := A}) ->
    %% A reply goes through the account that received the message. Using
    %% another one is only possible by naming it, which is refused here.
    case maps:get(<<"account_ids">>, Args, undefined) of
        undefined ->
            {ok, A};
        [A] ->
            {ok, A};
        _ ->
            _ = Principal,
            {error, reply_account_mismatch}
    end.

pick_from(Principal, AccId, Args, Reply) ->
    case maps:get(<<"from">>, Args, undefined) of
        undefined ->
            Ids = mailio_mcp_authz:identities(Principal, AccId),
            case Ids of
                [] ->
                    {error, no_identity};
                _ ->
                    Matched =
                        case Reply of
                            #{hit := Hit} -> match_identity(Ids, Hit);
                            _ -> undefined
                        end,
                    {ok,
                        case Matched of
                            undefined -> hd(Ids);
                            I -> I
                        end}
            end;
        Addr ->
            case mailio_mcp_authz:check_identity(Principal, AccId, Addr) of
                {ok, I} -> {ok, I};
                {error, _} = E -> E
            end
    end.

%% The identity a message was addressed to, so a reply to the support alias
%% is sent from the support alias.
match_identity(Ids, Hit) ->
    Rcpts = [
        string:lowercase(maps:get(address, A))
     || A <- maps:get(to, Hit, []) ++ maps:get(cc, Hit, [])
    ],
    case [I || I = #{address := A} <- Ids, lists:member(string:lowercase(A), Rcpts)] of
        [I | _] -> I;
        [] -> undefined
    end.

default_to(none, _, _, _) ->
    [];
default_to(#{hit := Hit}, _Args, _, _) ->
    Target =
        case maps:get(reply_to, Hit, []) of
            [] -> maps:get(from, Hit, []);
            R -> R
        end,
    [maps:get(address, A) || A <- Target].

default_cc(none, _, _, _, _) ->
    [];
default_cc(#{hit := Hit}, Args, AccId, Principal, To) ->
    case maps:get(<<"reply_all">>, Args, false) of
        true ->
            _ = Principal,
            {ok, #{identities := Ids}} = mailio_mcp_config:account(AccId),
            Own = [string:lowercase(A) || #{address := A} <- Ids],
            Others = [maps:get(address, A) || A <- maps:get(to, Hit, []) ++ maps:get(cc, Hit, [])],
            lists:usort([
                A
             || A <- Others, not lists:member(string:lowercase(A), Own), not lists:member(A, To)
            ]);
        _ ->
            []
    end.

recipients(Key, Args, Default) ->
    case maps:get(Key, Args, undefined) of
        undefined ->
            {ok, Default};
        V ->
            Items =
                case V of
                    L when is_list(L) -> L;
                    B when is_binary(B) -> [B]
                end,
            Parsed = lists:append([mailio_mcp_mime:addresses(I) || I <- Items, is_binary(I)]),
            Addrs = [maps:get(address, A) || A <- Parsed],
            case lists:all(fun valid_addr/1, Addrs) of
                true -> {ok, Addrs};
                false -> {error, {bad_recipient, Key}}
            end
    end.

valid_addr(A) ->
    re:run(A, <<"^[^\\s@<>,;\"]+@[^\\s@<>,;\"]+$">>) =/= nomatch.

subject(Args, Reply) ->
    case maps:get(<<"subject">>, Args, undefined) of
        undefined ->
            case Reply of
                #{hit := Hit} ->
                    S = maps:get(subject, Hit, <<>>),
                    case re:run(S, <<"^\\s*(re|aw)\\s*:">>, [caseless]) of
                        {match, _} -> S;
                        nomatch -> <<"Re: ", S/binary>>
                    end;
                none ->
                    <<>>
            end;
        S ->
            S
    end.

reply_field(none, _) -> undefined;
reply_field(#{hit := Hit}, K) -> maps:get(K, Hit, undefined).

reply_refs(none) ->
    [];
reply_refs(#{hit := Hit}) ->
    Old = maps:get(references, Hit, []),
    case maps:get(msgid, Hit, undefined) of
        undefined -> Old;
        Id -> Old ++ [Id]
    end.

new_message_id(#{address := A}) ->
    [_, Domain] = binary:split(A, <<"@">>),
    <<"<", (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary, "@", Domain/binary,
        ">">>.

%%--------------------------------------------------------------------
%% Output, hashing, message building

summary(D) ->
    #{
        <<"draft_id">> => maps:get(id, D),
        <<"revision">> => maps:get(revision, D),
        <<"account">> => maps:get(account, D),
        <<"from">> => mailio_mcp_mime:format_addr(maps:get(from, D)),
        <<"to">> => maps:get(to, D),
        <<"cc">> => maps:get(cc, D),
        <<"bcc_count">> => length(maps:get(bcc, D)),
        <<"subject">> => mailio_mcp_budget:shorten(maps:get(subject, D), 120),
        <<"in_reply_to">> =>
            case maps:get(in_reply_to, D) of
                undefined -> null;
                V -> V
            end,
        <<"body_bytes">> => byte_size(maps:get(body, D)),
        <<"sent">> => false,
        <<"next">> =>
            <<"Review, then call draft_send with draft_id, revision and a new idempotency_key.">>
    }.

payload_hash(D) ->
    Canon = [
        maps:get(account, D),
        maps:get(from, D),
        maps:get(to, D),
        maps:get(cc, D),
        maps:get(bcc, D),
        maps:get(subject, D),
        maps:get(body, D),
        maps:get(in_reply_to, D),
        maps:get(references, D),
        maps:get(message_id, D)
    ],
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Canon)), lowercase).

%% @doc Envelope sender, recipients and the encoded message.
-spec build(map()) -> {binary(), [binary()], binary()}.
build(D) ->
    From = maps:get(from, D),
    Extra =
        [{<<"Date">>, mailio_mcp_time:rfc5322_now()}] ++
            opt(<<"In-Reply-To">>, ref(maps:get(in_reply_to, D))) ++
            opt(<<"References">>, join_sp(maps:get(references, D))),
    Raw = mailio_mime_render:build(#{
        from => [addr(From)],
        to => [#{email => A} || A <- maps:get(to, D)],
        cc => [#{email => A} || A <- maps:get(cc, D)],
        subject => maps:get(subject, D),
        message_id => bare_id(maps:get(message_id, D)),
        headers => Extra,
        text => maps:get(body, D)
    }),
    Rcpts = lists:usort(maps:get(to, D) ++ maps:get(cc, D) ++ maps:get(bcc, D)),
    {Raw, Rcpts, maps:get(address, From)}.

addr(#{address := A} = Identity) ->
    #{email => A, name => maps:get(name, Identity, undefined)}.

ref(undefined) -> <<>>;
ref(V) -> V.

%% The renderer adds the angle brackets of a Message-ID itself.
bare_id(<<$<, Rest/binary>>) -> binary:part(Rest, 0, byte_size(Rest) - 1);
bare_id(Id) -> Id.

opt(_, <<>>) -> [];
opt(K, V) -> [{K, V}].
join_sp(L) -> iolist_to_binary(lists:join(<<" ">>, L)).
