%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc IMAP adapter. Mailboxes are opened read-only (EXAMINE) and content
%%% is fetched with BODY.PEEK, so reading or searching never changes the
%%% unread flag. Identity of a message is mailbox + UIDVALIDITY + UID.
-module(mailio_mcp_imap).

-export([
    capabilities/1,
    list_mailboxes/2,
    search/2,
    read_message/3,
    fetch_part/4,
    thread/3,
    changes/3,
    wait_for_change/4,
    fingerprint/3,
    excerpts/3
]).
-export([parse_bodystructure/1, is_attachment/1, body_part/1]).
-export([center_excerpt/2]).

-define(HDR_FIELDS, <<"FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES">>).
-define(FETCH_META,
    <<"(UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (",
        ?HDR_FIELDS/binary, ")])">>
).

%%====================================================================
%% Connection helper
%%====================================================================

with_conn(Account, Fun) ->
    case mailio_mcp_imap_io:open(Account) of
        {ok, C} ->
            try
                Fun(C)
            after
                mailio_mcp_imap_io:close(C)
            end;
        {error, R} ->
            {error, {unavailable, R}}
    end.

%%====================================================================
%% Capabilities
%%====================================================================

-spec capabilities(map()) -> map().
capabilities(Account) ->
    Base = #{
        protocol => imap,
        native_filters => [from, to, subject, text, unread, mailbox, received_at_day, sent_at_day],
        local_filters => [has_attachment, received_at_exact, sent_at_exact, first_seen_at],
        time_bases => [received_at, sent_at, first_seen_at],
        mailbox_ops => [list, search, read, changes],
        marks_read_on_open => false
    },
    case with_conn(Account, fun(C) -> {ok, mailio_mcp_imap_io:caps(C)} end) of
        {ok, Caps} ->
            Base#{
                extensions => [
                    E
                 || E <- [
                        <<"CONDSTORE">>,
                        <<"QRESYNC">>,
                        <<"UIDPLUS">>,
                        <<"ESEARCH">>,
                        <<"SPECIAL-USE">>,
                        <<"IDLE">>,
                        <<"UTF8=ACCEPT">>,
                        <<"LITERAL+">>,
                        <<"THREAD=REFERENCES">>,
                        <<"MOVE">>
                    ],
                    lists:member(E, Caps)
                ],
                reachable => true
            };
        {error, R} ->
            Base#{reachable => false, reason => reason(R)}
    end.

reason({unavailable, R}) -> reason(R);
reason({connect, R}) -> iolist_to_binary(io_lib:format("connect: ~p", [R]));
reason(authentication_failed) -> <<"authentication_failed">>;
reason(R) -> iolist_to_binary(io_lib:format("~p", [R])).

%%====================================================================
%% Mailboxes
%%====================================================================

-spec list_mailboxes(map(), boolean()) -> {ok, [map()]} | {error, term()}.
list_mailboxes(Account, Counts) ->
    with_conn(Account, fun(C) ->
        case mailio_mcp_imap_io:cmd(C, [<<"LIST \"\" \"*\"">>]) of
            {ok, U, _} ->
                Boxes = [mailbox_entry(Attrs, Name) || {list, Attrs, _Delim, Name} <- U],
                Sel = [B || B = #{selectable := true} <- Boxes],
                Boxes2 =
                    case Counts of
                        true -> add_counts(C, Boxes, lists:sublist(Sel, 50));
                        false -> Boxes
                    end,
                {ok, Boxes2};
            Other ->
                cmd_error(Other)
        end
    end).

mailbox_entry(Attrs, Raw) ->
    Lower = [string:lowercase(A) || A <- Attrs],
    #{
        name => mailio_mcp_imap_io:utf7_decode(Raw),
        raw_name => Raw,
        selectable => not lists:member(<<"\\noselect">>, Lower),
        role => special_use(Lower, Raw)
    }.

special_use(Attrs, Name) ->
    Map = [
        {<<"\\sent">>, sent},
        {<<"\\drafts">>, drafts},
        {<<"\\trash">>, trash},
        {<<"\\junk">>, junk},
        {<<"\\archive">>, archive},
        {<<"\\all">>, all}
    ],
    case [R || {A, R} <- Map, lists:member(A, Attrs)] of
        [R | _] ->
            R;
        [] ->
            case string:lowercase(Name) of
                <<"inbox">> -> inbox;
                _ -> none
            end
    end.

add_counts(C, Boxes, Sel) ->
    Names = [maps:get(raw_name, B) || B <- Sel],
    Counts = maps:from_list(
        lists:filtermap(
            fun(N) ->
                Q = mailio_mcp_imap_io:quote(N),
                case mailio_mcp_imap_io:cmd(C, [<<"STATUS ">>, Q, <<" (MESSAGES UNSEEN)">>]) of
                    {ok, Events, _} ->
                        case [KV || {status, _, KV} <- Events] of
                            [KV | _] ->
                                {true,
                                    {N, maps:from_list([{string:uppercase(K), V} || {K, V} <- KV])}};
                            [] ->
                                false
                        end;
                    _ ->
                        false
                end
            end,
            Names
        )
    ),
    [
        case maps:find(maps:get(raw_name, B), Counts) of
            {ok, KV} ->
                B#{
                    messages => maps:get(<<"MESSAGES">>, KV, 0),
                    unseen => maps:get(<<"UNSEEN">>, KV, 0)
                };
            error ->
                B
        end
     || B <- Boxes
    ].

%%====================================================================
%% Search
%%====================================================================

%% Query keys: mailboxes, from, to, subject, text, unread, has_attachment,
%% basis, since, before, max_candidates. since/before are unix seconds.
-spec search(map(), map()) -> {ok, [map()], map()} | {error, term()}.
search(Account, Q) ->
    with_conn(Account, fun(C) ->
        Boxes = maps:get(mailboxes, Q, [<<"INBOX">>]),
        Results = [search_box(C, Account, Box, Q) || Box <- Boxes],
        Oks = [ok || {ok, _, _} <- Results],
        case [R || {error, _} = R <- Results] of
            [{error, _} = E | _] when Oks =:= [] -> E;
            Errors ->
                Hits = lists:append([H || {ok, H, _} <- Results]),
                Info = [I || {ok, _, I} <- Results],
                Cov = #{
                    capped => lists:any(fun(I) -> maps:get(capped, I, false) end, Info),
                    candidates => lists:sum([maps:get(candidates, I, 0) || I <- Info]),
                    failed_mailboxes => length(Errors)
                },
                {ok, Hits, Cov}
        end
    end).

search_box(C, Account, Box, Q) ->
    case examine(C, Box) of
        {ok, Sel} ->
            Criteria = criteria(Q),
            case mailio_mcp_imap_io:cmd(C, [<<"UID SEARCH ">> | Criteria]) of
                {ok, U, _} ->
                    Uids = search_uids(U),
                    Max = maps:get(max_candidates, Q, 200),
                    Capped = length(Uids) > Max,
                    Take = lists:nthtail(max(0, length(Uids) - Max), Uids),
                    case fetch_meta(C, Take) of
                        {ok, Metas} ->
                            Hits = [to_hit(Account, Box, Sel, M) || M <- Metas],
                            Filtered = [H || H <- Hits, local_match(H, Q)],
                            {ok, Filtered, #{capped => Capped, candidates => length(Take)}};
                        {error, _} = E ->
                            E
                    end;
                Other ->
                    cmd_error(Other)
            end;
        {error, _} = E ->
            E
    end.

criteria(Q) ->
    Parts =
        [
            text_crit(<<"FROM">>, maps:get(from, Q, undefined)),
            or_crit(maps:get(to, Q, undefined)),
            text_crit(<<"SUBJECT">>, maps:get(subject, Q, undefined)),
            text_crit(<<"TEXT">>, maps:get(text, Q, undefined)),
            case maps:get(unread, Q, undefined) of
                true -> [<<"UNSEEN">>];
                false -> [<<"SEEN">>];
                _ -> []
            end
        ] ++ date_crit(Q),
    case [P || P <- Parts, P =/= []] of
        [] -> [<<"ALL">>];
        L -> lists:append(lists:join([<<" ">>], L))
    end.

text_crit(_, undefined) -> [];
text_crit(Key, Val) -> [Key, <<" ">>, mailio_mcp_imap_io:quote(Val)].

or_crit(undefined) ->
    [];
or_crit(Val) ->
    Q = mailio_mcp_imap_io:quote(Val),
    [<<"OR OR TO ">>, Q, <<" CC ">>, Q, <<" BCC ">>, Q].

date_crit(Q) ->
    Basis = maps:get(basis, Q, received_at),
    {S, B} =
        case Basis of
            sent_at -> {<<"SENTSINCE">>, <<"SENTBEFORE">>};
            _ -> {<<"SINCE">>, <<"BEFORE">>}
        end,
    case Basis of
        first_seen_at ->
            [];
        _ ->
            Since =
                case maps:get(since, Q, undefined) of
                    undefined -> [];
                    T -> [[S, <<" ">>, imap_date(T - 86400)]]
                end,
            Before =
                case maps:get(before, Q, undefined) of
                    undefined -> [];
                    T2 -> [[B, <<" ">>, imap_date(T2 + 2 * 86400)]]
                end,
            Since ++ Before
    end.

imap_date(T) ->
    {{Y, M, D}, _} = calendar:system_time_to_universal_time(T, second),
    Mon = lists:nth(M, [
        <<"Jan">>,
        <<"Feb">>,
        <<"Mar">>,
        <<"Apr">>,
        <<"May">>,
        <<"Jun">>,
        <<"Jul">>,
        <<"Aug">>,
        <<"Sep">>,
        <<"Oct">>,
        <<"Nov">>,
        <<"Dec">>
    ]),
    iolist_to_binary([integer_to_list(D), "-", Mon, "-", integer_to_list(Y)]).

search_uids(Events) ->
    lists:sort(lists:append([Uids || {search, Uids} <- Events])).

%% Exact filtering that IMAP cannot do natively.
local_match(Hit, Q) ->
    time_ok(Hit, Q) andalso att_ok(Hit, Q).

time_ok(Hit, Q) ->
    Basis = maps:get(basis, Q, received_at),
    case {maps:get(since, Q, undefined), maps:get(before, Q, undefined)} of
        {undefined, undefined} ->
            true;
        {S, B} ->
            case maps:get(Basis, Hit, undefined) of
                undefined -> Basis =:= first_seen_at;
                T -> (S =:= undefined orelse T >= S) andalso (B =:= undefined orelse T < B)
            end
    end.

att_ok(Hit, Q) ->
    case maps:get(has_attachment, Q, undefined) of
        undefined -> true;
        Want -> (maps:get(attachment_count, Hit, 0) > 0) =:= Want
    end.

examine(C, Box) ->
    Raw = mailio_mcp_imap_io:utf7_encode(Box),
    case mailio_mcp_imap_io:cmd(C, [<<"EXAMINE ">>, mailio_mcp_imap_io:quote(Raw)]) of
        {ok, U, _} -> {ok, parse_select(U)};
        {no, _} -> {error, mailbox_not_found};
        Other -> cmd_error(Other)
    end.

parse_select(Events) ->
    lists:foldl(
        fun
            ({status_resp, ok, {<<"UIDVALIDITY">>, [{number, N}]}, _}, Acc) -> Acc#{uv => N};
            ({status_resp, ok, {<<"UIDNEXT">>, [{number, N}]}, _}, Acc) -> Acc#{uidnext => N};
            ({status_resp, ok, {<<"HIGHESTMODSEQ">>, [{number, N}]}, _}, Acc) -> Acc#{modseq => N};
            ({exists, N}, Acc) -> Acc#{exists => N};
            (_, Acc) -> Acc
        end,
        #{uv => 0, uidnext => 0, exists => 0},
        Events
    ).

%%====================================================================
%% Fetch and parse
%%====================================================================

fetch_meta(_C, []) ->
    {ok, []};
fetch_meta(C, Uids) ->
    Res = [fetch_chunk(C, Ch) || Ch <- chunk(Uids, 50)],
    case [E || {error, E} <- Res] of
        [E | _] -> {error, E};
        [] -> {ok, lists:append([M || {ok, M} <- Res])}
    end.

fetch_chunk(C, Uids) ->
    Set = iolist_to_binary(lists:join(<<",">>, [integer_to_binary(U) || U <- Uids])),
    case mailio_mcp_imap_io:cmd(C, [<<"UID FETCH ">>, Set, <<" ">>, ?FETCH_META]) of
        {ok, U, _} ->
            {ok, [fetch_map(Items) || {fetch, _Seq, Items} <- U]};
        {error, _} = E ->
            E;
        Other ->
            cmd_error(Other)
    end.

chunk([], _) ->
    [];
chunk(L, N) when length(L) =< N -> [L];
chunk(L, N) ->
    {A, B} = lists:split(N, L),
    [A | chunk(B, N)].

%% One FETCH response as a map. The items come from the mailio parser:
%% {uid, N}, {flags, [...]}, {internaldate, Bin}, {size, N}, {modseq, N},
%% and {Key, Value} for BODYSTRUCTURE and the body sections.
fetch_map(Items) ->
    lists:foldl(fun item/2, #{}, Items).

item({uid, N}, A) ->
    A#{uid => N};
item({flags, Fs}, A) ->
    A#{flags => [string:lowercase(F) || F <- Fs]};
item({internaldate, V}, A) ->
    case mailio_mcp_time:parse_imap_date(V) of
        {ok, T} -> A#{received_at => T};
        error -> A
    end;
item({size, N}, A) ->
    A#{size => N};
item({modseq, N}, A) ->
    A#{modseq => N};
item({Key, V}, A) when is_binary(Key) ->
    item_key(string:uppercase(Key), V, A);
item(_, A) ->
    A.

item_key(<<"BODYSTRUCTURE">>, V, A) ->
    A#{parts => parse_bodystructure(mailio_mcp_imap_io:tokens_to_term(V))};
item_key(<<"BODY[HEADER", _/binary>>, V, A) when is_binary(V) ->
    A#{headers => mailio_mcp_mime:parse_headers(V)};
item_key(<<"BODY[", _/binary>> = K, V, A) ->
    A#{{section, K} => section_data(V)};
item_key(_, _, A) ->
    A.

section_data(V) when is_binary(V) -> V;
section_data(_) -> <<>>.

to_hit(Account, Box, Sel, M) ->
    H = maps:get(headers, M, []),
    Hdr = fun(N) -> mailio_mcp_mime:header(N, H) end,
    Parts = maps:get(parts, M, []),
    Atts = [P || P <- Parts, is_attachment(P)],
    Sent =
        case Hdr(<<"date">>) of
            undefined ->
                undefined;
            D ->
                case mailio_mcp_time:parse_header_date(D) of
                    {ok, T} -> T;
                    error -> undefined
                end
        end,
    Flags = maps:get(flags, M, []),
    #{
        account => maps:get(id, Account),
        mailbox => Box,
        uv => maps:get(uv, Sel),
        uid => maps:get(uid, M),
        flags => Flags,
        unread => not lists:member(<<"\\seen">>, Flags),
        received_at => maps:get(received_at, M, undefined),
        sent_at => Sent,
        size => maps:get(size, M, 0),
        from => mailio_mcp_mime:addresses(Hdr(<<"from">>)),
        to => mailio_mcp_mime:addresses(Hdr(<<"to">>)),
        cc => mailio_mcp_mime:addresses(Hdr(<<"cc">>)),
        reply_to => mailio_mcp_mime:addresses(Hdr(<<"reply-to">>)),
        subject => decode(Hdr(<<"subject">>)),
        msgid => first(mailio_mcp_mime:message_ids(Hdr(<<"message-id">>))),
        in_reply_to => first(mailio_mcp_mime:message_ids(Hdr(<<"in-reply-to">>))),
        references => mailio_mcp_mime:message_ids(Hdr(<<"references">>)),
        parts => Parts,
        attachments => Atts,
        attachment_count => length(Atts)
    }.

decode(undefined) -> <<>>;
decode(V) -> mailio_mcp_mime:decode_words(V).

first([X | _]) -> X;
first([]) -> undefined.

%%====================================================================
%% BODYSTRUCTURE
%%====================================================================

-spec parse_bodystructure(list()) -> [map()].
parse_bodystructure(Tokens) ->
    case Tokens of
        [First | _] when is_list(First) -> mp(Tokens, <<>>);
        _ -> [leaf(Tokens, <<"1">>)]
    end.

mp(Tokens, Prefix) ->
    Children = lists:takewhile(fun is_list/1, Tokens),
    lists:append(
        lists:zipwith(
            fun(I, Child) ->
                Id =
                    case Prefix of
                        <<>> -> integer_to_binary(I);
                        _ -> <<Prefix/binary, ".", (integer_to_binary(I))/binary>>
                    end,
                case Child of
                    [F | _] when is_list(F) -> mp(Child, Id);
                    _ -> [leaf(Child, Id)]
                end
            end,
            lists:seq(1, length(Children)),
            Children
        )
    ).

leaf([Type, Sub, Params, _Id, _Desc, Enc, Size | Rest], Id) ->
    T = string:lowercase(tok_str(Type)),
    S = string:lowercase(tok_str(Sub)),
    P = params(Params),
    Ext =
        case {T, S} of
            {<<"text">>, _} -> drop(1, Rest);
            {<<"message">>, <<"rfc822">>} -> drop(3, Rest);
            _ -> Rest
        end,
    Disp =
        case Ext of
            [_Md5, D | _] -> D;
            _ -> nil
        end,
    {DispType, DParams} = disposition(Disp),
    #{
        id => Id,
        type => <<T/binary, "/", S/binary>>,
        charset => maps:get(<<"charset">>, P, undefined),
        encoding => string:lowercase(tok_str(Enc)),
        size => int(Size),
        name =>
            case maps:get(<<"filename">>, DParams, maps:get(<<"name">>, P, undefined)) of
                undefined -> undefined;
                N -> mailio_mcp_mime:decode_words(N)
            end,
        disposition => DispType
    };
leaf(_, Id) ->
    #{
        id => Id,
        type => <<"application/octet-stream">>,
        encoding => <<"7bit">>,
        size => 0,
        name => undefined,
        disposition => none,
        charset => undefined
    }.

drop(N, L) when length(L) >= N -> lists:nthtail(N, L);
drop(_, _) -> [].

params(nil) -> #{};
params(L) when is_list(L) -> params(L, #{});
params(_) -> #{}.
params([K, V | R], A) -> params(R, A#{string:lowercase(tok_str(K)) => tok_str(V)});
params(_, A) -> A.

disposition([T, P | _]) when is_binary(T); is_tuple(T) ->
    {
        case string:lowercase(tok_str(T)) of
            <<"attachment">> -> attachment;
            <<"inline">> -> inline;
            _ -> none
        end,
        params(P)
    };
disposition(_) ->
    {none, #{}}.

-spec is_attachment(map()) -> boolean().
is_attachment(#{type := <<"multipart/", _/binary>>}) ->
    false;
is_attachment(#{disposition := attachment}) ->
    true;
is_attachment(#{disposition := inline}) ->
    false;
is_attachment(#{name := N, type := T}) when N =/= undefined ->
    not lists:member(T, [<<"text/plain">>, <<"text/html">>]);
is_attachment(#{type := <<"message/rfc822">>}) ->
    true;
is_attachment(_) ->
    false.

%% @doc The part to show as the message body: first text/plain, else text/html.
-spec body_part([map()]) -> map() | undefined.
body_part(Parts) ->
    Texts = [
        P
     || P = #{type := T} <- Parts,
        not is_attachment(P),
        lists:member(T, [<<"text/plain">>, <<"text/html">>])
    ],
    case [P || P = #{type := <<"text/plain">>} <- Texts] of
        [P | _] ->
            P;
        [] ->
            case Texts of
                [P | _] -> P;
                [] -> undefined
            end
    end.

%%====================================================================
%% Reading one message
%%====================================================================

%% Loc: #{mailbox, uv, uid}. Opts: part (id), offset, limit, quoted.
-spec read_message(map(), map(), map()) -> {ok, map()} | {error, term()}.
read_message(Account, #{mailbox := Box, uv := UV, uid := Uid}, Opts) ->
    with_conn(Account, fun(C) ->
        case examine(C, Box) of
            {ok, #{uv := UV} = Sel} ->
                case fetch_meta(C, [Uid]) of
                    {ok, [M]} when is_map_key(uid, M) ->
                        Hit = to_hit(Account, Box, Sel, M),
                        case maps:get(text, Opts, true) of
                            false -> {ok, Hit};
                            true -> add_text(C, Hit, Opts)
                        end;
                    _ ->
                        {error, message_gone}
                end;
            {ok, _} ->
                {error, stale_handle};
            {error, _} = E ->
                E
        end
    end).

add_text(C, #{uid := Uid, parts := Parts} = Hit, Opts) ->
    Part =
        case maps:get(part, Opts, undefined) of
            undefined ->
                body_part(Parts);
            Id ->
                case [X || X = #{id := I} <- Parts, I =:= Id] of
                    [X | _] -> X;
                    [] -> undefined
                end
        end,
    case Part of
        undefined ->
            {ok, Hit#{text => <<>>, text_next => undefined, text_total => 0}};
        #{id := PartId, type := Type, encoding := Enc} = P ->
            Max = mailio_mcp_config:limit(max_text_fetch, 262144),
            case fetch_section(C, Uid, PartId, Max) of
                {ok, Raw} ->
                    Text0 = mailio_mcp_mime:decode_body(
                        Raw, Enc, maps:get(charset, P, undefined)
                    ),
                    Text1 =
                        case Type of
                            <<"text/html">> -> mailio_mcp_mime:html_to_text(Text0);
                            _ -> Text0
                        end,
                    Text =
                        case maps:get(quoted, Opts, false) of
                            true -> Text1;
                            false -> mailio_mcp_mime:strip_quoted(Text1)
                        end,
                    {Page, Next} = mailio_mcp_mime:page(
                        Text,
                        maps:get(offset, Opts, 0),
                        maps:get(limit, Opts, 3000)
                    ),
                    {ok, Hit#{
                        text => Page,
                        text_next => Next,
                        text_total => byte_size(Text),
                        text_part => PartId,
                        text_truncated_source => byte_size(Raw) >= Max
                    }};
                {error, _} = E ->
                    E
            end
    end.

fetch_section(C, Uid, PartId, Max) ->
    Cmd = [
        <<"UID FETCH ">>,
        integer_to_binary(Uid),
        <<" (BODY.PEEK[">>,
        PartId,
        <<"]<0.">>,
        integer_to_binary(Max),
        <<">)">>
    ],
    case mailio_mcp_imap_io:cmd(C, Cmd) of
        {ok, U, _} ->
            case [fetch_map(Items) || {fetch, _Seq, Items} <- U] of
                [M | _] ->
                    case [V || {{section, _}, V} <- maps:to_list(M)] of
                        [V | _] -> {ok, V};
                        [] -> {ok, <<>>}
                    end;
                [] ->
                    {error, message_gone}
            end;
        Other ->
            cmd_error(Other)
    end.

%% @doc Fetch one MIME part, decoded from its transfer encoding, up to
%% MaxBytes of encoded data.
-spec fetch_part(map(), map(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_part(Account, #{mailbox := Box, uv := UV, uid := Uid}, PartId, MaxBytes) ->
    with_conn(Account, fun(C) ->
        case examine(C, Box) of
            {ok, #{uv := UV} = Sel} ->
                case fetch_meta(C, [Uid]) of
                    {ok, [M]} when is_map_key(uid, M) ->
                        Hit = to_hit(Account, Box, Sel, M),
                        case [P || P = #{id := I} <- maps:get(parts, Hit), I =:= PartId] of
                            [P = #{encoding := Enc, size := Size}] ->
                                case fetch_section(C, Uid, PartId, MaxBytes) of
                                    {ok, Raw} ->
                                        Bytes = decode_transfer(Raw, Enc),
                                        {ok, P#{
                                            bytes => Bytes,
                                            complete => byte_size(Raw) < MaxBytes,
                                            encoded_size => Size
                                        }};
                                    E ->
                                        E
                                end;
                            [] ->
                                {error, part_not_found}
                        end;
                    _ ->
                        {error, message_gone}
                end;
            {ok, _} ->
                {error, stale_handle};
            {error, _} = E ->
                E
        end
    end).

decode_transfer(Raw, Enc) -> mailio_mime_decode:decode_transfer(Raw, Enc).

%%====================================================================
%% Threads
%%====================================================================

%% @doc Messages of the same mailbox that share the thread root with the
%% given message, oldest first. Uses References and In-Reply-To.
-spec thread(map(), map(), pos_integer()) -> {ok, [map()], boolean()} | {error, term()}.
thread(Account, #{mailbox := Box, uv := UV, uid := Uid}, Max) ->
    with_conn(Account, fun(C) ->
        case examine(C, Box) of
            {ok, #{uv := UV} = Sel} ->
                {ok, [M]} = fetch_meta(C, [Uid]),
                Self = to_hit(Account, Box, Sel, M),
                Root =
                    case maps:get(references, Self) of
                        [R | _] ->
                            R;
                        [] ->
                            case maps:get(in_reply_to, Self) of
                                undefined -> maps:get(msgid, Self);
                                I -> I
                            end
                    end,
                Uids =
                    case Root of
                        undefined ->
                            [Uid];
                        _ ->
                            Q = mailio_mcp_imap_io:quote(Root),
                            case
                                mailio_mcp_imap_io:cmd(C, [
                                    <<"UID SEARCH OR OR HEADER Message-ID ">>,
                                    Q,
                                    <<" HEADER References ">>,
                                    Q,
                                    <<" HEADER In-Reply-To ">>,
                                    Q
                                ])
                            of
                                {ok, U, _} -> lists:usort([Uid | search_uids(U)]);
                                _ -> [Uid]
                            end
                    end,
                Capped = length(Uids) > Max,
                Take = lists:nthtail(max(0, length(Uids) - Max), Uids),
                {ok, Ms} = fetch_meta(C, Take),
                Hits = [to_hit(Account, Box, Sel, X) || X <- Ms],
                Sorted = lists:sort(
                    fun(A, B) -> sort_key(A) =< sort_key(B) end, Hits
                ),
                {ok, Sorted, Capped};
            {ok, _} ->
                {error, stale_handle};
            {error, _} = E ->
                E
        end
    end).

sort_key(H) ->
    {
        maps:get(sent_at, H, undefined) =/= undefined,
        case maps:get(sent_at, H, undefined) of
            undefined -> maps:get(received_at, H, 0);
            T -> T
        end,
        maps:get(uid, H)
    }.

%%====================================================================
%% Excerpts and fingerprints
%%====================================================================

%% @doc Short plain-text excerpts for the given hits. When a query is given,
%% the excerpt is centered on its first matching term.
-spec excerpts(map(), [map()], binary() | undefined) -> #{term() => binary()}.
excerpts(Account, Hits, Query) ->
    case
        with_conn(Account, fun(C) ->
            {ok, lists:foldl(fun(H, Acc) -> excerpt_one(C, H, Query, Acc) end, #{}, Hits)}
        end)
    of
        {ok, M} -> M;
        _ -> #{}
    end.

excerpt_one(C, #{mailbox := Box, uv := UV, uid := Uid, parts := Parts}, Query, Acc) ->
    case {body_part(Parts), examine(C, Box)} of
        {#{id := Id, encoding := Enc, type := Type} = P, {ok, #{uv := UV}}} ->
            case fetch_section(C, Uid, Id, 1200) of
                {ok, Raw} ->
                    T0 = mailio_mcp_mime:decode_body(Raw, Enc, maps:get(charset, P, undefined)),
                    T1 =
                        case Type of
                            <<"text/html">> -> mailio_mcp_mime:html_to_text(T0);
                            _ -> T0
                        end,
                    T2 = mailio_mcp_mime:strip_quoted(T1),
                    T3 = re:replace(T2, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
                    Acc#{{Box, UV, Uid} => center_excerpt(string:trim(T3), Query)};
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

-define(EXCERPT_CHARS, 160).
-define(EXCERPT_CONTEXT_CHARS, 40).

%% @doc Excerpt centered on the first match of any query term. Without a
%% query, or when no term matches, the excerpt starts at the beginning of the
%% text. Lengths are in characters, so UTF-8 is never cut inside a code point.
-spec center_excerpt(binary(), binary() | undefined) -> binary().
center_excerpt(Text, Query) when is_binary(Text) ->
    Len = string:length(Text),
    case query_byte_pos(Text, Query) of
        undefined ->
            mailio_mcp_budget:shorten(Text, ?EXCERPT_CHARS);
        BytePos ->
            Start = max(0, char_pos(Text, BytePos) - ?EXCERPT_CONTEXT_CHARS),
            Slice = string:slice(Text, Start, ?EXCERPT_CHARS),
            Marked =
                case {Start > 0, Start + ?EXCERPT_CHARS < Len} of
                    {true, true} ->
                        [<<"…"/utf8>>, Slice, <<"…"/utf8>>];
                    {true, false} ->
                        [<<"…"/utf8>>, Slice];
                    {false, true} ->
                        [Slice, <<"…"/utf8>>];
                    {false, false} ->
                        Slice
                end,
            Final =
                case is_binary(Marked) of
                    true -> Marked;
                    false -> iolist_to_binary(Marked)
                end,
            mailio_mcp_budget:shorten(Final, ?EXCERPT_CHARS)
    end;
center_excerpt(Text, _) ->
    Text.

%% Byte position of the first query term occurrence in Text, or undefined.
query_byte_pos(_Text, undefined) ->
    undefined;
query_byte_pos(_Text, <<>>) ->
    undefined;
query_byte_pos(Text, Query) ->
    Terms =
        [
            escape_re(T)
         || T <- lists:sublist(string:split(string:trim(Query), <<" ">>, all), 8), T =/= <<>>
        ],
    case Terms of
        [] ->
            undefined;
        _ ->
            Pattern = iolist_to_binary(lists:join(<<"|">>, Terms)),
            case re:run(Text, Pattern, [caseless, {capture, first, index}]) of
                {match, [{Pos, _}]} -> Pos;
                _ -> undefined
            end
    end.

%% Escape every non-word byte so a query term is matched literally.
escape_re(<<>>) ->
    <<>>;
escape_re(<<C/utf8, Rest/binary>>) ->
    case
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9)
    of
        true -> <<C/utf8, (escape_re(Rest))/binary>>;
        false -> <<$/, C/utf8, (escape_re(Rest))/binary>>
    end.

%% Character position of a byte offset (the prefix is scanned once).
char_pos(Text, BytePos) ->
    string:length(binary:part(Text, 0, BytePos)).

%% @doc Fingerprint of a message body (the whole body up to MaxBytes), used
%% as evidence that two copies are the same message.
-spec fingerprint(map(), map(), pos_integer()) -> {ok, binary()} | {error, term()}.
fingerprint(Account, #{mailbox := Box, uv := UV, uid := Uid}, MaxBytes) ->
    with_conn(Account, fun(C) ->
        case examine(C, Box) of
            {ok, #{uv := UV}} ->
                case fetch_section(C, Uid, <<"TEXT">>, MaxBytes) of
                    {ok, Raw} when byte_size(Raw) < MaxBytes ->
                        Norm = binary:replace(Raw, <<"\r\n">>, <<"\n">>, [global]),
                        {ok, binary:encode_hex(crypto:hash(sha256, Norm), lowercase)};
                    {ok, _} ->
                        {error, too_large};
                    E ->
                        E
                end;
            _ ->
                {error, stale_handle}
        end
    end).

%%====================================================================
%% Changes
%%====================================================================

%% @doc Compare a mailbox to a previous snapshot. Prev is undefined for the
%% first baseline. Returns the observable additions, updates and removals
%% and the new snapshot.
-spec changes(map(), binary(), map() | undefined) -> {ok, map()} | {error, term()}.
changes(#{id := Id} = Account, Box, Prev) ->
    with_conn(Account, fun(C) ->
        case qresync_usable(C, Prev) of
            true ->
                case qresync_changes(C, Account, Box, Prev) of
                    fallback -> counted(Id, changes_full, plain_changes(C, Account, Box, Prev));
                    Result -> counted(Id, changes_qresync, Result)
                end;
            false ->
                counted(Id, changes_full, plain_changes(C, Account, Box, Prev))
        end
    end).

%% @doc Wait until the mailbox differs from the checkpoint `Prev', for at most
%% `Timeout' milliseconds, without polling: the server is held in IDLE and
%% tells us. The checkpoint is compared first, so a change that happened
%% before IDLE started is not missed. `unsupported' when the server has no
%% IDLE or there is no checkpoint to compare with.
-spec wait_for_change(map(), binary(), map() | undefined, non_neg_integer()) ->
    changed | timeout | unsupported | {error, term()}.
wait_for_change(_Account, _Box, undefined, _Timeout) ->
    unsupported;
wait_for_change(#{id := Id} = Account, Box, Prev, Timeout) ->
    with_conn(Account, fun(C) ->
        case mailio_mcp_imap_io:has_cap(C, <<"IDLE">>) of
            false ->
                unsupported;
            true ->
                _ = enable_modseq(C),
                case examine(C, Box) of
                    {ok, Sel} ->
                        Result =
                            case moved_on(Sel, Prev) of
                                true -> changed;
                                false -> mailio_mcp_imap_io:idle_wait(C, Timeout)
                            end,
                        case Result of
                            changed -> mailio_mcp_stats:bump(Id, idle_woken, 1, 0);
                            timeout -> mailio_mcp_stats:bump(Id, idle_timeout, 1, 0);
                            _ -> ok
                        end,
                        Result;
                    {error, _} = E ->
                        E
                end
        end
    end).

%% Has the mailbox moved past what the checkpoint recorded?
moved_on(Sel, Prev) ->
    maps:get(uv, Sel) =/= maps:get(uv, Prev, undefined) orelse
        maps:get(uidnext, Sel) =/= maps:get(uidnext, Prev, undefined) orelse
        maps:get(exists, Sel) =/= maps:get(exists, Prev, undefined) orelse
        modseq_moved(maps:get(modseq, Sel, undefined), maps:get(modseq, Prev, undefined)).

modseq_moved(undefined, _) -> false;
modseq_moved(_, undefined) -> false;
modseq_moved(New, Old) -> New =/= Old.

%% Which way a call to mail_changes was answered, for the stats counters.
counted(Id, Kind, {ok, _} = Result) ->
    mailio_mcp_stats:bump(Id, Kind, 1, 0),
    Result;
counted(_Id, _Kind, Other) ->
    Other.

%% Without QRESYNC: compare the flags of every message with the snapshot.
plain_changes(C, Account, Box, Prev) ->
    %% A server reports the mod-sequence of a mailbox only to a client that
    %% enabled CONDSTORE, so ask first: the snapshot needs it, and the next
    %% call can then use QRESYNC.
    _ = enable_modseq(C),
    (fun() ->
        case examine(C, Box) of
            {ok, #{uv := UV} = Sel} ->
                case Prev of
                    #{uv := PUV} when PUV =/= UV -> {error, checkpoint_expired};
                    #{uidnext := UN, exists := Ex} = P when
                        UN =:= map_get(uidnext, Sel),
                        Ex =:= map_get(exists, Sel)
                    ->
                        case {maps:get(modseq, P, undefined), maps:get(modseq, Sel, undefined)} of
                            {M, M} when M =/= undefined ->
                                {ok, #{
                                    unchanged => true,
                                    snapshot => Prev,
                                    added => [],
                                    updated => [],
                                    removed => []
                                }};
                            _ ->
                                full_changes(C, Account, Box, Sel, Prev)
                        end;
                    _ ->
                        full_changes(C, Account, Box, Sel, Prev)
                end;
            {error, _} = E ->
                E
        end
    end)().

enable_modseq(C) ->
    case mailio_mcp_imap_io:has_cap(C, <<"QRESYNC">>) of
        true ->
            mailio_mcp_imap_io:cmd(C, [<<"ENABLE QRESYNC">>]);
        false ->
            case mailio_mcp_imap_io:has_cap(C, <<"CONDSTORE">>) of
                true -> mailio_mcp_imap_io:cmd(C, [<<"ENABLE CONDSTORE">>]);
                false -> ok
            end
    end.

%% QRESYNC (RFC 7162): the server reports what changed since the checkpoint's
%% mod-sequence (flag changes, new messages, and the expunged UIDs), so no
%% flag listing of the whole mailbox is needed. The mailbox is still opened
%% read-only. Anything unexpected falls back to the full comparison.
qresync_usable(C, #{uv := UV, modseq := M, flags := _, partial := false}) when
    is_integer(UV), is_integer(M)
->
    mailio_mcp_imap_io:has_cap(C, <<"QRESYNC">>);
qresync_usable(_C, _Prev) ->
    false.

qresync_changes(C, Account, Box, #{uv := UV, modseq := ModSeq, flags := Old} = Prev) ->
    Raw = mailio_mcp_imap_io:utf7_encode(Box),
    case mailio_mcp_imap_io:cmd(C, [<<"ENABLE QRESYNC">>]) of
        {ok, _, _} ->
            Cmd = [
                <<"EXAMINE ">>,
                mailio_mcp_imap_io:quote(Raw),
                <<" (QRESYNC (">>,
                integer_to_binary(UV),
                <<" ">>,
                integer_to_binary(ModSeq),
                <<"))">>
            ],
            case mailio_mcp_imap_io:cmd(C, Cmd) of
                {ok, Events, _} ->
                    qresync_result(C, Account, Box, Prev, Old, parse_select(Events), Events);
                _ ->
                    fallback
            end;
        _ ->
            fallback
    end.

qresync_result(_C, _Account, _Box, #{uv := PUV}, _Old, #{uv := UV}, _Events) when PUV =/= UV ->
    {error, checkpoint_expired};
qresync_result(C, Account, Box, Prev, Old, Sel, Events) ->
    Ranges = lists:append([R || {vanished, _Earlier, R} <- Events]),
    Unreadable = [Raw || {other, <<"VANISHED", _/binary>> = Raw} <- Events],
    case {Unreadable, mailio_imap_proto:expand_uid_ranges(Ranges, 100000)} of
        {[], {ok, Vanished}} ->
            qresync_apply(C, Account, Box, Prev, Old, Sel, Events, Vanished);
        %% a report we cannot read, or one too long to list: it may hide
        %% removals, so compare the whole mailbox instead
        _ ->
            fallback
    end.

qresync_apply(C, Account, Box, Prev, Old, #{exists := Exists} = Sel, Events, Vanished) ->
    %% a snapshot never holds more than `max_snapshot' entries: a mailbox beyond it
    %% is read the capped way, not extended one delivery at a time
    case Exists > mailio_mcp_config:limit(max_snapshot, 20000) of
        true -> fallback;
        false -> qresync_apply_within(C, Account, Box, Prev, Old, Sel, Events, Vanished)
    end.

qresync_apply_within(C, Account, Box, Prev, Old, #{exists := Exists} = Sel, Events, Vanished) ->
    Gone = lists:sort([U || U <- Vanished, is_map_key(U, Old)]),
    Changed = [
        {maps:get(uid, M), flag_bits(maps:get(flags, M, []))}
     || {fetch, _Seq, Items} <- Events,
        M <- [fetch_map(Items)],
        is_map_key(uid, M),
        is_map_key(flags, M)
    ],
    Cur = maps:merge(maps:without(Gone, Old), maps:from_list(Changed)),
    case maps:size(Cur) =:= Exists of
        false ->
            %% the report and the mailbox disagree: do not trust it
            fallback;
        true ->
            Added = lists:sort([U || {U, _} <- Changed, not is_map_key(U, Old)]),
            Updated = lists:sort([
                U
             || {U, B} <- Changed, is_map_key(U, Old), maps:get(U, Old) =/= B
            ]),
            Snap = #{
                uv => maps:get(uv, Sel),
                uidnext => maps:get(uidnext, Sel),
                exists => Exists,
                modseq => maps:get(modseq, Sel, maps:get(modseq, Prev)),
                flags => Cur,
                partial => false
            },
            ShowAdd = lists:nthtail(max(0, length(Added) - 50), Added),
            {ok, Metas} = fetch_meta(C, ShowAdd),
            {ok, #{
                unchanged => lists:append([Added, Gone, Updated]) =:= [],
                snapshot => Snap,
                added => [to_hit(Account, Box, Sel, M) || M <- Metas],
                added_total => length(Added),
                updated => [
                    #{
                        uid => U,
                        flags => bits_flags(maps:get(U, Cur)),
                        unread => (maps:get(U, Cur) band 1) =:= 0
                    }
                 || U <- Updated
                ],
                removed => Gone,
                uv => maps:get(uv, Sel)
            }}
    end.

full_changes(C, Account, Box, Sel, Prev) ->
    Cap = mailio_mcp_config:limit(max_snapshot, 20000),
    Exists = maps:get(exists, Sel),
    Range =
        case Exists > Cap of
            true -> iolist_to_binary([integer_to_list(Exists - Cap + 1), ":*"]);
            false -> <<"1:*">>
        end,
    %% A fetch that fails is an error, not an empty mailbox: an empty snapshot
    %% would report every message the caller knows as removed.
    Fetched =
        case Exists of
            0 ->
                {ok, #{}};
            _ ->
                case mailio_mcp_imap_io:cmd(C, [<<"FETCH ">>, Range, <<" (UID FLAGS)">>]) of
                    {ok, U, _} ->
                        {ok,
                            maps:from_list([
                                {maps:get(uid, M), flag_bits(maps:get(flags, M, []))}
                             || {fetch, _Seq, Items} <- U,
                                M <- [fetch_map(Items)],
                                is_map_key(uid, M)
                            ])};
                    Failed ->
                        {error, {imap_fetch_failed, Failed}}
                end
        end,
    case Fetched of
        {ok, Cur} -> full_changes(C, Account, Box, Sel, Prev, Cap, Cur);
        {error, _} = Error -> Error
    end.

full_changes(C, Account, Box, Sel, Prev, Cap, Cur) ->
    Exists = maps:get(exists, Sel),
    Snap = #{
        uv => maps:get(uv, Sel),
        uidnext => maps:get(uidnext, Sel),
        exists => Exists,
        modseq => maps:get(modseq, Sel, undefined),
        flags => Cur,
        partial => Exists > Cap
    },
    case Prev of
        undefined ->
            {ok, #{
                unchanged => false,
                baseline => true,
                snapshot => Snap,
                added => [],
                updated => [],
                removed => []
            }};
        #{flags := Old} ->
            %% After a capped read a UID that was not in the snapshot may simply have
            %% been outside it. Only one at or above the previous UIDNEXT is new.
            AddFloor =
                case maps:get(partial, Prev, false) of
                    true -> maps:get(uidnext, Prev, 0);
                    false -> 0
                end,
            Added = lists:sort([
                U
             || U <- maps:keys(Cur), not maps:is_key(U, Old), U >= AddFloor
            ]),
            %% A capped read lists only the newest messages. A UID below the
            %% lowest one it lists may well still be there: only those within
            %% what was listed are known to be gone.
            Lowest =
                case Cur =:= #{} of
                    true -> 0;
                    false -> lists:min(maps:keys(Cur))
                end,
            Floor =
                case Exists > Cap of
                    true -> Lowest;
                    false -> 0
                end,
            Removed = lists:sort([
                U
             || U <- maps:keys(Old), not maps:is_key(U, Cur), U >= Floor
            ]),
            Updated = lists:sort([
                U
             || {U, F} <- maps:to_list(Cur),
                maps:find(U, Old) =/= error,
                maps:get(U, Old) =/= F
            ]),
            ShowAdd = lists:nthtail(max(0, length(Added) - 50), Added),
            {ok, Metas} = fetch_meta(C, ShowAdd),
            AddedHits = [to_hit(Account, Box, Sel, M) || M <- Metas],
            Unchanged = lists:append([Added, Removed, Updated]) =:= [],
            {ok, #{
                unchanged => Unchanged,
                snapshot => Snap,
                added => AddedHits,
                added_total => length(Added),
                updated => [
                    #{
                        uid => U,
                        flags => bits_flags(maps:get(U, Cur)),
                        unread => (maps:get(U, Cur) band 1) =:= 0
                    }
                 || U <- Updated
                ],
                removed => Removed,
                uv => maps:get(uv, Sel)
            }}
    end.

flag_bits(Flags) ->
    lists:foldl(
        fun({F, B}, A) ->
            case lists:member(F, Flags) of
                true -> A bor B;
                false -> A
            end
        end,
        0,
        [
            {<<"\\seen">>, 1},
            {<<"\\answered">>, 2},
            {<<"\\flagged">>, 4},
            {<<"\\deleted">>, 8},
            {<<"\\draft">>, 16}
        ]
    ).

bits_flags(Bits) ->
    [
        Name
     || {Name, B} <- [
            {<<"seen">>, 1},
            {<<"answered">>, 2},
            {<<"flagged">>, 4},
            {<<"deleted">>, 8},
            {<<"draft">>, 16}
        ],
        Bits band B =/= 0
    ].

%%====================================================================
%% Small helpers
%%====================================================================

tok_str({s, B}) -> B;
tok_str(B) when is_binary(B) -> B;
tok_str(nil) -> <<>>;
tok_str(_) -> <<>>.

int(B) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> 0
    end;
int(_) ->
    0.

cmd_error({no, T}) -> {error, {server_no, T}};
cmd_error({bad, T}) -> {error, {server_bad, T}};
cmd_error({error, R}) -> {error, {unavailable, R}}.
