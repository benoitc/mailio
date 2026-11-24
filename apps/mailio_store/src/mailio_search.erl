%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Full-text search convenience over the JMAP Email/query facade.
%%%
%%% v1 is a substring search across subject, addresses, and extracted body
%%% text, ranked by recency, returning a snippet around the first match. It
%%% reuses {@link mailio_email:query/2} (indexed structural pre-filter +
%%% Erlang-side text matching), so no separate index is maintained.
%%%
%%% A ranked BM25 / semantic backend (barrel_vectordb over its HTTP gateway,
%%% out of this VM to avoid a RocksDB NIF version clash) is the planned
%%% upgrade behind this same interface.
-module(mailio_search).

-export([text/2, text/3]).

-define(SNIPPET_RADIUS, 60).

-spec text(binary(), binary()) -> {ok, [map()]}.
text(Account, QueryString) ->
    text(Account, QueryString, #{}).

%% @doc Search `Account' for `QueryString'. Options: `limit', `mailbox'
%% (restrict to a mailbox id). Returns recency-ranked results, each
%% `#{emailId, threadId, subject, receivedAt, snippet}'.
-spec text(binary(), binary(), map()) -> {ok, [map()]}.
text(Account, QueryString, Opts) ->
    Limit = maps:get(limit, Opts, 20),
    Filter0 = #{text => QueryString},
    Filter =
        case maps:get(mailbox, Opts, undefined) of
            undefined ->
                Filter0;
            MbxId ->
                #{
                    operator => 'AND',
                    conditions => [Filter0, #{inMailbox => MbxId}]
                }
        end,
    {ok, #{<<"ids">> := Ids}} =
        mailio_email:query(Account, #{
            filter => Filter,
            sort => [
                #{
                    <<"property">> => <<"receivedAt">>,
                    <<"isAscending">> => false
                }
            ],
            limit => Limit
        }),
    Db = mailio_account:db_name(Account),
    Results = [result(Db, Id, QueryString) || Id <- Ids],
    {ok, Results}.

result(Db, EmailId, Query) ->
    {ok, Email} = mailio_db:get(Db, mailio_email:doc_id(EmailId)),
    #{
        <<"emailId">> => EmailId,
        <<"threadId">> => mailio_email:thread_id(Email),
        <<"subject">> => maps:get(<<"subject">>, Email, null),
        <<"receivedAt">> => maps:get(<<"receivedAt">>, Email, null),
        <<"snippet">> => snippet(Db, EmailId, Email, Query)
    }.

%% Build a snippet around the first query match in subject + body text.
snippet(Db, EmailId, Email, Query) ->
    Subject =
        case maps:get(<<"subject">>, Email, null) of
            null -> <<>>;
            S -> S
        end,
    Body = body_text(Db, EmailId),
    Haystack = <<Subject/binary, " ", Body/binary>>,
    case binary:match(mailio_ascii:lower(Haystack), mailio_ascii:lower(Query)) of
        nomatch ->
            mailio_html_text:preview(email_preview(Email), 120);
        {Pos, Len} ->
            window(Haystack, Pos, Len)
    end.

email_preview(Email) ->
    case maps:get(<<"preview">>, Email, <<>>) of
        P when is_binary(P) -> P;
        _ -> <<>>
    end.

window(Bin, Pos, Len) ->
    Start = max(0, Pos - ?SNIPPET_RADIUS),
    End = min(byte_size(Bin), Pos + Len + ?SNIPPET_RADIUS),
    Slice = binary:part(Bin, Start, End - Start),
    Collapsed = collapse_ws(Slice),
    Prefix =
        case Start > 0 of
            true -> <<"…">>;
            false -> <<>>
        end,
    Suffix =
        case End < byte_size(Bin) of
            true -> <<"…">>;
            false -> <<>>
        end,
    <<Prefix/binary, Collapsed/binary, Suffix/binary>>.

collapse_ws(Bin) ->
    Parts = [
        P
     || P <- binary:split(
            Bin,
            [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
            [global]
        ),
        P =/= <<>>
    ],
    iolist_to_binary(lists:join(<<" ">>, Parts)).

body_text(Db, EmailId) ->
    case mailio_db:get(Db, <<"text/", EmailId/binary>>) of
        {ok, #{<<"body_text">> := T}} -> T;
        _ -> <<>>
    end.
