%%% @doc Conversation threading (pure logic + reads).
%%%
%%% Assigns an email to a thread using its Message-ID references first
%%% (References / In-Reply-To resolved through `msgid/<hash>' lookup docs),
%%% falling back to a normalized-subject match against existing threads.
%%% Returns the chosen thread id plus the thread and msgid documents to
%%% persist; the account writer commits them so the operation is serialized
%%% and race-free.
%%%
%%% Full thread merge/split (rewriting siblings when a missing ancestor
%%% arrives) is deferred to later hardening; here, when references point at
%%% multiple existing threads, the lexicographically smallest id wins.
-module(mailio_threading).

-include("mailio_store.hrl").

-export([assign/2, normalize_subject/1]).

-type input() :: #{
    email_id := binary(),
    message_id := binary() | undefined,
    in_reply_to := [binary()],
    references := [binary()],
    subject_norm := binary(),
    received_ts := integer(),
    participants => [binary()]
}.

%% @doc Decide the thread for an email. Returns
%% `{ThreadId, ThreadDoc, MsgidDocs}' where ThreadDoc and MsgidDocs are
%% documents the caller must write.
-spec assign(binary(), input()) -> {binary(), map(), [map()]}.
assign(Db, Input) ->
    #{email_id := EmailId, subject_norm := SubjectNorm,
      received_ts := ReceivedTs} = Input,
    RefIds = lists:usort(maps:get(references, Input, [])
                         ++ maps:get(in_reply_to, Input, [])),
    ThreadId =
        case resolve_by_refs(Db, RefIds) of
            {ok, Tid} -> Tid;
            none -> resolve_by_subject(Db, SubjectNorm)
        end,
    ThreadDoc = upsert_thread(Db, ThreadId, EmailId, SubjectNorm, ReceivedTs, Input),
    MsgidDocs = msgid_docs(Input, ThreadId),
    {ThreadId, ThreadDoc, MsgidDocs}.

%%====================================================================
%% Reference-based resolution
%%====================================================================

resolve_by_refs(_Db, []) -> none;
resolve_by_refs(Db, RefIds) ->
    DocIds = [msgid_doc_id(R) || R <- RefIds],
    Results = mailio_db:get_many(Db, DocIds),
    ThreadIds = lists:usort(
        [Tid || {ok, #{<<"threadId">> := Tid}} <- Results]),
    case ThreadIds of
        [] -> none;
        _ -> {ok, lists:min(ThreadIds)}
    end.

%%====================================================================
%% Subject fallback
%%====================================================================

resolve_by_subject(_Db, <<>>) ->
    mailio_id:thread_id();
resolve_by_subject(Db, SubjectNorm) ->
    Query = #{where => [{path, [?MAILIO_NS, <<"subject">>], SubjectNorm}],
              limit => 1},
    case mailio_db:find(Db, Query, #{include_docs => true}) of
        {ok, [#{<<"id">> := <<?ID_THREAD, Tid/binary>>} | _], _} -> Tid;
        _ -> mailio_id:thread_id()
    end.

%%====================================================================
%% Thread document upsert
%%====================================================================

upsert_thread(Db, ThreadId, EmailId, SubjectNorm, ReceivedTs, Input) ->
    DocId = <<?ID_THREAD, ThreadId/binary>>,
    Participants = maps:get(participants, Input, []),
    case mailio_db:get(Db, DocId) of
        {ok, Existing} ->
            EmailIds = add_unique(maps:get(<<"emailIds">>, Existing, []), EmailId),
            Ns0 = maps:get(?MAILIO_NS, Existing, #{}),
            LastTs = max(ReceivedTs, maps:get(<<"lastReceivedAt">>, Ns0, 0)),
            Parts = lists:usort(maps:get(<<"participants">>, Ns0, []) ++ Participants),
            Ns = Ns0#{<<"lastReceivedAt">> => LastTs,
                      <<"participants">> => Parts},
            Existing#{<<"emailIds">> => EmailIds, ?MAILIO_NS => Ns};
        {error, not_found} ->
            #{<<"id">> => DocId,
              <<"emailIds">> => [EmailId],
              ?MAILIO_NS => #{<<"subject">> => SubjectNorm,
                              <<"participants">> => lists:usort(Participants),
                              <<"lastReceivedAt">> => ReceivedTs}}
    end.

add_unique(List, Item) ->
    case lists:member(Item, List) of
        true -> List;
        false -> List ++ [Item]
    end.

%%====================================================================
%% Message-ID lookup docs
%%====================================================================

msgid_docs(#{message_id := undefined}, _ThreadId) ->
    [];
msgid_docs(#{message_id := MsgId, email_id := EmailId}, ThreadId) ->
    [#{<<"id">> => msgid_doc_id(MsgId),
       <<"emailId">> => EmailId,
       <<"threadId">> => ThreadId}].

msgid_doc_id(MsgId) ->
    <<?ID_MSGID, (mailio_id:msgid_hash(MsgId))/binary>>.

%%====================================================================
%% Subject normalization
%%====================================================================

%% @doc Normalize a subject for thread matching: strip reply/forward
%% prefixes, lowercase, collapse whitespace.
-spec normalize_subject(binary() | null | undefined) -> binary().
normalize_subject(null) -> <<>>;
normalize_subject(undefined) -> <<>>;
normalize_subject(Subject) ->
    Lower = mailio_ascii:lower(mailio_ascii:trim(Subject)),
    Stripped = strip_prefixes(Lower),
    collapse_ws(Stripped).

%% Repeatedly remove leading re:/fwd:/fw: (with optional "[n]") prefixes.
strip_prefixes(Bin) ->
    Trimmed = mailio_ascii:trim_leading(Bin),
    case take_prefix(Trimmed) of
        {ok, Rest} -> strip_prefixes(Rest);
        none -> Trimmed
    end.

take_prefix(<<"re:", Rest/binary>>) -> {ok, Rest};
take_prefix(<<"fwd:", Rest/binary>>) -> {ok, Rest};
take_prefix(<<"fw:", Rest/binary>>) -> {ok, Rest};
take_prefix(<<"re[", Rest/binary>>) -> skip_count(Rest);
take_prefix(<<"fwd[", Rest/binary>>) -> skip_count(Rest);
take_prefix(_) -> none.

%% Consume "<digits>]:" after a "re[" / "fwd[" prefix.
skip_count(<<C, Rest/binary>>) when C >= $0, C =< $9 -> skip_count(Rest);
skip_count(<<"]:", Rest/binary>>) -> {ok, Rest};
skip_count(_) -> none.

collapse_ws(Bin) ->
    Parts = [P || P <- binary:split(Bin, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
                                    [global]), P =/= <<>>],
    iolist_to_binary(lists:join(<<" ">>, Parts)).
