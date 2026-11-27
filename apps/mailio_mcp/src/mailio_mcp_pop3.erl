%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc POP3 adapter. Mail stays on the server (no DELE is ever sent).
%%% POP3 has no flags, folders or search, so the adapter keeps a local
%%% metadata index built from UIDL and TOP and searches that index. Filters
%%% it cannot honestly perform are refused, and the time basis that POP3
%%% lacks (received_at) is reported as unavailable.
%%%
%%% Fallbacks: without UIDL the identity is a hash of the message headers
%%% and size. Without TOP the headers come from RETR when the message is
%%% small enough. Servers that reuse one UIDL for identical copies get an
%%% ordinal suffix so each copy keeps its own identity.
-module(mailio_mcp_pop3).

-export([
    capabilities/1,
    list_mailboxes/2,
    search/2,
    read_message/3,
    fetch_part/4,
    thread/3,
    changes/3,
    fingerprint/3,
    excerpts/3
]).

-define(INBOX, <<"INBOX">>).

%%====================================================================
%% Connection
%%====================================================================

%%====================================================================
%% Capabilities, mailboxes
%%====================================================================

capabilities(Account) ->
    Base = #{
        protocol => pop3,
        native_filters => [],
        local_filters => [
            from,
            to,
            subject,
            text_headers_only,
            has_attachment_when_known,
            sent_at_exact,
            first_seen_at
        ],
        time_bases => [sent_at, first_seen_at],
        mailbox_ops => [list, search, read, changes],
        marks_read_on_open => false,
        unread_filter => unsupported,
        refused_filters => [unread, received_at]
    },
    case with_conn(Account, fun(C) -> {ok, mailio_pop3:capabilities(C)} end) of
        {ok, Caps} ->
            Base#{
                extensions => [
                    E
                 || E <- [<<"UIDL">>, <<"TOP">>, <<"STLS">>, <<"PIPELINING">>],
                    lists:member(E, Caps)
                ],
                reachable => true
            };
        {error, R} ->
            Base#{reachable => false, reason => iolist_to_binary(io_lib:format("~p", [R]))}
    end.

list_mailboxes(Account, Counts) ->
    case Counts of
        false ->
            {ok, [box(undefined)]};
        true ->
            with_conn(Account, fun(C) ->
                case mailio_pop3:stat(C) of
                    {ok, Count, _Octets} -> {ok, [box(Count)]};
                    _ -> {ok, [box(undefined)]}
                end
            end)
    end.

box(N) ->
    B = #{name => ?INBOX, raw_name => ?INBOX, selectable => true, role => inbox},
    case N of
        undefined -> B;
        _ -> B#{messages => N, unseen => N}
    end.

%%====================================================================
%% Index
%%====================================================================

idx_get(AccId, Id) -> mailio_mcp_store:get(pop3idx, {AccId, Id}).
idx_put(AccId, Id, V) -> mailio_mcp_store:put(pop3idx, {AccId, Id}, V).

%% Make sure the newest Cap unindexed messages are in the index.
ensure_index(C, #{id := AccId}, Cap) ->
    {Pairs, Sizes, HasUidl} = listing(C),
    Entries = lists:map(
        fun({N, Id}) ->
            Size = maps:get(N, Sizes, 0),
            {N, Id, Size}
        end,
        Pairs
    ),
    New = [E || {_, Id, _} = E <- Entries, Id =/= undefined, idx_get(AccId, Id) =:= error],
    NoUidl =
        case HasUidl of
            true -> [];
            false -> Entries
        end,
    Todo = lists:sublist(lists:reverse(lists:sort(New ++ NoUidl)), Cap),
    Resolved = lists:filtermap(fun(E) -> index_one(C, AccId, E, HasUidl) end, Todo),
    Incomplete = length(New) > length(Todo),
    {Entries, Resolved, Incomplete, HasUidl, length(New) - length(Todo)}.

index_one(C, AccId, {N, Id0, Size}, HasUidl) ->
    case headers(C, N, Size) of
        {ok, Raw} ->
            Meta = meta(Raw, Size),
            Id =
                case HasUidl of
                    true ->
                        Id0;
                    false ->
                        binary:encode_hex(
                            crypto:hash(
                                sha256,
                                term_to_binary({
                                    maps:get(msgid, Meta), maps:get(sent_at, Meta), Size
                                })
                            ),
                            lowercase
                        )
                end,
            idx_put(AccId, Id, Meta),
            {true, {N, Id}};
        {error, _} ->
            false
    end.

meta(Raw, Size) ->
    H = mailio_mcp_mime:parse_headers(Raw),
    Hd = fun(K) -> mailio_mcp_mime:header(K, H) end,
    Sent =
        case Hd(<<"date">>) of
            undefined ->
                undefined;
            D ->
                case mailio_mcp_time:parse_header_date(D) of
                    {ok, T} -> T;
                    error -> undefined
                end
        end,
    #{
        from => mailio_mcp_mime:addresses(Hd(<<"from">>)),
        to => mailio_mcp_mime:addresses(Hd(<<"to">>)),
        cc => mailio_mcp_mime:addresses(Hd(<<"cc">>)),
        reply_to => mailio_mcp_mime:addresses(Hd(<<"reply-to">>)),
        subject =>
            case Hd(<<"subject">>) of
                undefined -> <<>>;
                S -> mailio_mcp_mime:decode_words(S)
            end,
        sent_at => Sent,
        size => Size,
        content_type =>
            case Hd(<<"content-type">>) of
                undefined -> <<"text/plain">>;
                CT -> string:lowercase(CT)
            end,
        msgid => first(mailio_mcp_mime:message_ids(Hd(<<"message-id">>))),
        in_reply_to => first(mailio_mcp_mime:message_ids(Hd(<<"in-reply-to">>))),
        references => mailio_mcp_mime:message_ids(Hd(<<"references">>))
    }.

first([X | _]) -> X;
first([]) -> undefined.

hit(#{id := AccId}, Id, Meta) ->
    Att = attachment_state(maps:get(content_type, Meta)),
    Meta#{
        account => AccId,
        mailbox => ?INBOX,
        uidl => Id,
        flags => [],
        unread => undefined,
        received_at => undefined,
        attachments => [],
        attachment_count =>
            case Att of
                yes -> 1;
                _ -> 0
            end,
        attachment_known => Att =/= unknown
    }.

attachment_state(<<"multipart/mixed", _/binary>>) -> yes;
attachment_state(<<"multipart/", _/binary>>) -> unknown;
attachment_state(<<"text/", _/binary>>) -> no;
attachment_state(_) -> yes.

%%====================================================================
%% Search
%%====================================================================

search(Account, Q) ->
    case refuse(Q) of
        {error, _} = E ->
            E;
        ok ->
            with_conn(Account, fun(C) ->
                Cap = mailio_mcp_config:limit(pop3_index_batch, 100),
                {Entries, Resolved, Incomplete, _HasUidl, Missing} = ensure_index(C, Account, Cap),
                #{id := AccId} = Account,
                Map = maps:from_list(
                    [{N, Id} || {N, Id} <- Resolved] ++
                        [{N, Id} || {N, Id, _} <- Entries, Id =/= undefined]
                ),
                %% A metadata index entry that cannot be read is not a
                %% non-match: count it so the result reports partial coverage.
                {Hits, Failed} =
                    lists:foldl(
                        fun({N, _Id0, _}, {Acc, F}) ->
                            case maps:find(N, Map) of
                                {ok, Id} ->
                                    case idx_get(AccId, Id) of
                                        {ok, Meta} ->
                                            H = hit(Account, Id, Meta),
                                            case match(H, Q) of
                                                true -> {[H | Acc], F};
                                                false -> {Acc, F}
                                            end;
                                        error ->
                                            {Acc, F + 1}
                                    end;
                                error ->
                                    {Acc, F}
                            end
                        end,
                        {[], 0},
                        Entries
                    ),
                Max = maps:get(max_candidates, Q, 200),
                Hits2 = lists:nthtail(max(0, length(Hits) - Max), lists:reverse(Hits)),
                {ok, Hits2, #{
                    capped => length(Hits) > Max,
                    candidates => length(Hits2),
                    index_incomplete => Incomplete orelse Failed > 0,
                    unindexed => Missing,
                    failed_mailboxes => 0
                }}
            end)
    end.

refuse(Q) ->
    case maps:get(unread, Q, undefined) of
        undefined ->
            case maps:get(basis, Q, sent_at) of
                received_at when is_map_key(since, Q); is_map_key(before, Q) ->
                    {error, {basis_unavailable, received_at, [sent_at, first_seen_at]}};
                _ ->
                    ok
            end;
        _ ->
            {error, {unsupported_filter, unread, <<"POP3 has no read/unread flag.">>}}
    end.

match(H, Q) ->
    contains(maps:get(from, Q, undefined), [
        mailio_mcp_mime:format_addr(A)
     || A <- maps:get(from, H)
    ]) andalso
        contains(maps:get(to, Q, undefined), [
            mailio_mcp_mime:format_addr(A)
         || A <- maps:get(to, H) ++ maps:get(cc, H)
        ]) andalso
        contains(maps:get(subject, Q, undefined), [maps:get(subject, H)]) andalso
        text_ok(maps:get(text, Q, undefined), H) andalso
        time_ok(H, Q) andalso att_ok(H, Q).

contains(undefined, _) ->
    true;
contains(Needle, Hay) ->
    N = string:lowercase(Needle),
    lists:any(fun(X) -> binary:match(string:lowercase(X), N) =/= nomatch end, Hay).

text_ok(undefined, _) ->
    true;
text_ok(T, H) ->
    contains(
        T,
        [maps:get(subject, H)] ++
            [mailio_mcp_mime:format_addr(A) || A <- maps:get(from, H) ++ maps:get(to, H)]
    ).

time_ok(H, Q) ->
    Basis = maps:get(basis, Q, sent_at),
    case {maps:get(since, Q, undefined), maps:get(before, Q, undefined)} of
        {undefined, undefined} ->
            true;
        {S, B} ->
            case Basis of
                first_seen_at ->
                    true;
                _ ->
                    case maps:get(sent_at, H, undefined) of
                        undefined -> false;
                        T -> (S =:= undefined orelse T >= S) andalso (B =:= undefined orelse T < B)
                    end
            end
    end.

att_ok(H, Q) ->
    case maps:get(has_attachment, Q, undefined) of
        undefined ->
            true;
        Want ->
            case maps:get(attachment_known, H) of
                false -> false;
                true -> (maps:get(attachment_count, H) > 0) =:= Want
            end
    end.

%%====================================================================
%% Reading
%%====================================================================

%% Locate the message number for an identity in the current maildrop.
locate(C, #{id := AccId}, Id) ->
    {Pairs, Sizes, HasUidl} = listing(C),
    case HasUidl of
        true ->
            case [N || {N, I} <- Pairs, I =:= Id] of
                [N] -> {ok, N, maps:get(N, Sizes, 0)};
                _ -> {error, message_gone}
            end;
        false ->
            Found = [N || {N, _} <- Pairs, index_id(C, N, maps:get(N, Sizes, 0)) =:= Id],
            _ = AccId,
            case Found of
                [N | _] -> {ok, N, maps:get(N, Sizes, 0)};
                [] -> {error, message_gone}
            end
    end.

index_id(C, N, Size) ->
    case headers(C, N, Size) of
        {ok, Raw} ->
            M = meta(Raw, Size),
            binary:encode_hex(
                crypto:hash(
                    sha256, term_to_binary({maps:get(msgid, M), maps:get(sent_at, M), Size})
                ),
                lowercase
            );
        _ ->
            undefined
    end.

read_message(Account, #{uidl := Id}, Opts) ->
    with_conn(Account, fun(C) ->
        case locate(C, Account, Id) of
            {ok, N, Size} ->
                case retr(C, N, Size) of
                    {ok, Raw} -> {ok, build(Account, Id, Raw, Size, Opts)};
                    {error, _} = E -> E
                end;
            E ->
                E
        end
    end).

build(#{id := AccId} = Account, Id, Raw, Size, Opts) ->
    [HdrRaw | _] = binary:split(Raw, <<"\r\n\r\n">>),
    Meta = meta(HdrRaw, Size),
    Parts0 = parse_message(Raw),
    Parts = [maps:remove(bytes, P) || P <- Parts0],
    Atts = [P || P <- Parts, mailio_mcp_imap:is_attachment(P)],
    idx_put(AccId, Id, Meta),
    H0 = (hit(Account, Id, Meta))#{
        parts => Parts,
        attachments => Atts,
        attachment_count => length(Atts),
        attachment_known => true
    },
    case maps:get(text, Opts, true) of
        false -> H0;
        true -> add_text(H0, Parts0, Opts)
    end.

add_text(H, Parts0, Opts) ->
    Part =
        case maps:get(part, Opts, undefined) of
            undefined ->
                mailio_mcp_imap:body_part([maps:remove(bytes, P) || P <- Parts0]);
            Id ->
                case [maps:remove(bytes, P) || P = #{id := I} <- Parts0, I =:= Id] of
                    [P | _] -> P;
                    [] -> undefined
                end
        end,
    case Part of
        undefined ->
            H#{text => <<>>, text_next => undefined, text_total => 0};
        #{id := PId, type := Type} = Pt ->
            [#{bytes := Bytes}] = [X || X = #{id := I} <- Parts0, I =:= PId],
            T0 = mailio_mcp_mime:to_utf8(maps:get(charset, Pt, undefined), Bytes),
            T1 =
                case Type of
                    <<"text/html">> -> mailio_mcp_mime:html_to_text(T0);
                    _ -> T0
                end,
            T =
                case maps:get(quoted, Opts, false) of
                    true -> T1;
                    false -> mailio_mcp_mime:strip_quoted(T1)
                end,
            {Page, Next} = mailio_mcp_mime:page(
                T, maps:get(offset, Opts, 0), maps:get(limit, Opts, 3000)
            ),
            H#{text => Page, text_next => Next, text_total => byte_size(T), text_part => PId}
    end.

fetch_part(Account, #{uidl := Id}, PartId, MaxBytes) ->
    with_conn(Account, fun(C) ->
        case locate(C, Account, Id) of
            {ok, N, Size} ->
                case retr(C, N, Size) of
                    {ok, Raw} ->
                        case [P || P = #{id := I} <- parse_message(Raw), I =:= PartId] of
                            [#{bytes := B} = P] ->
                                Cut = binary:part(B, 0, min(byte_size(B), MaxBytes)),
                                {ok, (maps:remove(content_headers, P))#{
                                    bytes => Cut, complete => byte_size(B) =< MaxBytes
                                }};
                            [] ->
                                {error, part_not_found}
                        end;
                    E ->
                        E
                end;
            E ->
                E
        end
    end).

thread(Account, #{uidl := Id}, Max) ->
    #{id := AccId} = Account,
    case idx_get(AccId, Id) of
        error ->
            {error, message_gone};
        {ok, Self} ->
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
            All = [{K, M} || {{A, K}, M} <- mailio_mcp_store:all(pop3idx), A =:= AccId],
            Related = [
                hit(Account, K, M)
             || {K, M} <- All,
                K =:= Id orelse
                    (Root =/= undefined andalso
                        (maps:get(msgid, M) =:= Root orelse
                            lists:member(Root, maps:get(references, M)) orelse
                            maps:get(in_reply_to, M) =:= Root))
            ],
            Sorted = lists:sort(
                fun(A, B) -> maps:get(sent_at, A, 0) =< maps:get(sent_at, B, 0) end, Related
            ),
            Capped = length(Sorted) > Max,
            {ok, lists:nthtail(max(0, length(Sorted) - Max), Sorted), Capped}
    end.

fingerprint(Account, #{uidl := Id}, MaxBytes) ->
    with_conn(Account, fun(C) ->
        case locate(C, Account, Id) of
            {ok, N, Size} when Size =< MaxBytes ->
                case retr(C, N, Size) of
                    {ok, Raw} ->
                        Body =
                            case binary:split(Raw, <<"\r\n\r\n">>) of
                                [_, B] -> B;
                                _ -> Raw
                            end,
                        {ok,
                            binary:encode_hex(
                                crypto:hash(
                                    sha256, binary:replace(Body, <<"\r\n">>, <<"\n">>, [global])
                                ),
                                lowercase
                            )};
                    E ->
                        E
                end;
            {ok, _, _} ->
                {error, too_large};
            E ->
                E
        end
    end).

excerpts(_Account, _Hits, _Query) -> #{}.

%%====================================================================
%% Changes
%%====================================================================

changes(Account, _Box, Prev) ->
    #{id := AccId} = Account,
    with_conn(Account, fun(C) ->
        {Pairs, _Sizes, HasUidl} = listing(C),
        case HasUidl of
            false ->
                {error,
                    {unsupported,
                        <<"This server has no UIDL, so changes cannot be tracked reliably.">>}};
            true ->
                Cur = maps:from_list([{Id, true} || {_, Id} <- Pairs]),
                Snap = #{
                    uv => 0,
                    uidnext => 0,
                    exists => maps:size(Cur),
                    modseq => undefined,
                    flags => Cur,
                    partial => false
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
                        Added = [Id || {_, Id} <- Pairs, not maps:is_key(Id, Old)],
                        Removed = [Id || Id <- maps:keys(Old), not maps:is_key(Id, Cur)],
                        Unchanged = Added =:= [] andalso Removed =:= [],
                        Show = lists:sublist(lists:reverse(Added), 50),
                        {_E, _R, _I, _H, _M} = ensure_index(C, Account, 50),
                        Hits = [hit(Account, Id, M) || Id <- Show, {ok, M} <- [idx_get(AccId, Id)]],
                        {ok, #{
                            unchanged => Unchanged,
                            snapshot => Snap,
                            added => Hits,
                            added_total => length(Added),
                            updated => [],
                            removed => Removed,
                            uv => 0
                        }}
                end
        end
    end).

%%====================================================================
%% Connection (the protocol is in mailio_pop3)
%%====================================================================

with_conn(#{incoming := In, auth := Auth}, Fun) ->
    case mailio_pop3:open(mailio_mcp_net:config(In, Auth)) of
        {ok, C} ->
            try
                Fun(C)
            catch
                error:{badmatch, {error, #{code := Code}}} -> {error, {unavailable, Code}}
            after
                mailio_pop3:close(C)
            end;
        {error, #{code := Code}} ->
            {error, {unavailable, Code}}
    end.

%% Returns [{MsgNo, Id, Size}] input: {Pairs, Sizes, HasUidl}. Ids are unique
%% (repeated UIDLs get an ordinal) and `undefined' when the server has no UIDL.
listing(C) ->
    {ok, SizeList} = mailio_pop3:list(C),
    Sizes = maps:from_list(SizeList),
    case mailio_pop3:uidl(C) of
        {ok, Ids} ->
            {mailio_pop3:unique_ids(Ids), Sizes, true};
        {error, #{code := pop3_unsupported}} ->
            {[{N, undefined} || N <- lists:sort(maps:keys(Sizes))], Sizes, false}
    end.

%% TOP when available; RETR of small messages otherwise.
headers(C, N, Size) ->
    mailio_pop3:headers(C, N, Size, #{max_retr => mailio_mcp_config:limit(pop3_max_retr, 2097152)}).

retr(C, N, _Size) ->
    case mailio_pop3:retr(C, N, mailio_mcp_config:limit(max_part_bytes, 5242880)) of
        {ok, Raw} -> {ok, Raw};
        {error, #{code := pop3_too_large}} -> {error, message_too_large};
        {error, _} -> {error, message_gone}
    end.

%% Parse a full message into its parts, numbered like IMAP part ids.
parse_message(Raw) ->
    Tree = mailio_mime:parse(Raw),
    case maps:find(parts, Tree) of
        {ok, Children} -> numbered(Children, <<>>);
        error -> [leaf_part(Tree, <<"1">>)]
    end.

numbered(Children, Prefix) ->
    lists:append(
        lists:zipwith(
            fun(I, Child) ->
                Id =
                    case Prefix of
                        <<>> -> integer_to_binary(I);
                        _ -> <<Prefix/binary, ".", (integer_to_binary(I))/binary>>
                    end,
                case maps:find(parts, Child) of
                    {ok, Sub} -> numbered(Sub, Id);
                    error -> [leaf_part(Child, Id)]
                end
            end,
            lists:seq(1, length(Children)),
            Children
        )
    ).

leaf_part(#{type := T, subtype := S} = P, Id) ->
    Body = maps:get(body, P, <<>>),
    #{
        id => Id,
        type => string:lowercase(<<T/binary, "/", S/binary>>),
        charset => maps:get(charset, P, undefined),
        encoding => <<"7bit">>,
        size => byte_size(Body),
        name => maps:get(filename, P, undefined),
        disposition => disposition(maps:get(disposition, P, undefined)),
        bytes => Body
    }.

disposition(<<"attachment">>) -> attachment;
disposition(<<"inline">>) -> inline;
disposition(_) -> none.
