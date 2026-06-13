%%% @doc Per-account sole writer.
%%%
%%% Every mutation to an account's database flows through this one process,
%%% which serializes the multi-document operations (threading, mailbox
%%% counters, keyword merges, blob refs) that would otherwise race. Reads
%%% go straight to the store from any process.
%%%
%%% Ingestion is idempotent by construction: the email id is the SHA-256 of
%%% the raw bytes, so re-ingesting the same message is a no-op merge and the
%%% same message delivered to a second mailbox simply gains a mailboxId.
%%% Because barrel `put_docs' is not atomic (established by the M1 spike),
%%% the email document is written last; consumers that see an email change
%%% will find its thread/text/blob already present, and a crash mid-write
%%% leaves a partial state that a re-ingest deterministically repairs.
%%%
%%% After each commit the writer pulls the changes it produced from the
%%% changes feed and emits them as live events, so the event stream is
%%% derived from the durable log rather than hand-built.
-module(mailio_account_writer).
-behaviour(gen_server).

-include("mailio.hrl").

-export([start_link/1, ingest/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {account_id :: binary(),
                db :: binary(),
                emit_cursor :: barrel_hlc:timestamp() | first}).

-define(PARSE_VERSION, 1).

%%====================================================================
%% API
%%====================================================================

-spec start_link(binary()) -> {ok, pid()} | {error, term()}.
start_link(AccountId) ->
    gen_server:start_link(via(AccountId), ?MODULE, AccountId, []).

%% @doc Ingest raw RFC 5322 bytes into a mailbox. Returns the email id.
-spec ingest(binary(), binary(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
ingest(AccountId, MailboxId, Raw, Opts) ->
    gen_server:call(via(AccountId), {ingest, MailboxId, Raw, Opts}, 30000).

via(AccountId) ->
    {via, mailio_registry, {writer, AccountId}}.

%%====================================================================
%% gen_server
%%====================================================================

init(AccountId) ->
    Db = mailio_account:db_name(AccountId),
    {ok, _} = mailio_db:ensure_db(Db),
    {ok, _Changes, Hlc} = mailio_db:changes(Db, first),
    {ok, #state{account_id = AccountId, db = Db, emit_cursor = Hlc}}.

handle_call({ingest, MailboxId, Raw, Opts}, _From, State) ->
    Result = do_ingest(State#state.db, MailboxId, Raw, Opts),
    State1 = emit_events(State),
    {reply, Result, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Ingestion
%%====================================================================

do_ingest(Db, MailboxId, Raw, Opts) ->
    EmailId = mailio_id:email_id(Raw),
    DocId = <<?ID_EMAIL, EmailId/binary>>,
    ensure_mailbox(Db, MailboxId),
    case mailio_db:get(Db, DocId) of
        {ok, Existing} ->
            merge_existing(Db, Existing, MailboxId, Opts),
            {ok, EmailId};
        {error, not_found} ->
            full_ingest(Db, EmailId, DocId, MailboxId, Raw, Opts),
            {ok, EmailId}
    end.

%% Same content already stored: add the mailbox membership and merge
%% keywords, then bump the mailbox counter if this is a new membership.
merge_existing(Db, Existing, MailboxId, Opts) ->
    AlreadyMember = mailio_email:in_mailbox(Existing, MailboxId),
    WasSeen = mailio_email:is_seen(Existing),
    E1 = mailio_email:add_mailbox(Existing, MailboxId),
    E2 = apply_keywords(E1, maps:get(keywords, Opts, [])),
    E3 = add_imap_entry(E2, MailboxId, Opts),
    {ok, _, _} = mailio_db:put(Db, E3),
    case AlreadyMember of
        true -> ok;
        false -> bump_mailbox(Db, MailboxId, +1, seen_delta(false, WasSeen))
    end.

full_ingest(Db, EmailId, DocId, MailboxId, Raw, Opts) ->
    Part = mailio_mime:parse(Raw),
    Headers = headers_of(Part),
    {ok, BlobId} = mailio_blob:put(Db, Raw, DocId),

    Subject = mailio_rfc5322:decode_unstructured(
                mailio_rfc5322:header(<<"subject">>, Headers)),
    From = addresses(<<"from">>, Headers),
    To = addresses(<<"to">>, Headers),
    Cc = addresses(<<"cc">>, Headers),
    Bcc = addresses(<<"bcc">>, Headers),
    ReplyTo = addresses(<<"reply-to">>, Headers),
    Sender = addresses(<<"sender">>, Headers),
    MessageId = mailio_rfc5322:parse_message_id(
                  mailio_rfc5322:header(<<"message-id">>, Headers)),
    References = mailio_rfc5322:parse_message_ids(
                   mailio_rfc5322:header(<<"references">>, Headers)),
    InReplyTo = mailio_rfc5322:parse_message_ids(
                  mailio_rfc5322:header(<<"in-reply-to">>, Headers)),
    ReceivedTs = received_ts(Opts, Headers),
    SentTs = sent_ts(Headers),
    SubjectNorm = mailio_threading:normalize_subject(Subject),

    {BodyText, Attachments} = extract_content(Part),
    HasAttachment = Attachments =/= [],
    Preview = preview(BodyText),
    Keywords = keywords_map(maps:get(keywords, Opts, [])),

    Participants = participant_addrs(From ++ To ++ Cc),
    {ThreadId, ThreadDoc, MsgidDocs} =
        mailio_threading:assign(Db, #{email_id => EmailId,
                                      message_id => MessageId,
                                      in_reply_to => InReplyTo,
                                      references => References,
                                      subject_norm => SubjectNorm,
                                      received_ts => ReceivedTs,
                                      participants => Participants}),

    TextDoc = #{<<"id">> => <<?ID_TEXT, EmailId/binary>>,
                <<"emailId">> => EmailId,
                <<"body_text">> => BodyText,
                <<"attachment_text">> => <<>>,
                <<"tokens_version">> => ?PARSE_VERSION},

    EmailDoc = #{<<"id">> => DocId,
                 <<"blobId">> => BlobId,
                 <<"threadId">> => ThreadId,
                 <<"mailboxIds">> => #{MailboxId => true},
                 <<"keywords">> => Keywords,
                 <<"size">> => byte_size(Raw),
                 <<"receivedAt">> => rfc3339(ReceivedTs),
                 <<"messageId">> => null_or_list(maybe_list(MessageId)),
                 <<"inReplyTo">> => null_or_list(InReplyTo),
                 <<"references">> => null_or_list(References),
                 <<"from">> => null_or_list(From),
                 <<"sender">> => null_or_list(Sender),
                 <<"to">> => null_or_list(To),
                 <<"cc">> => null_or_list(Cc),
                 <<"bcc">> => null_or_list(Bcc),
                 <<"replyTo">> => null_or_list(ReplyTo),
                 <<"subject">> => null_or(Subject),
                 <<"sentAt">> => sent_at(SentTs),
                 <<"hasAttachment">> => HasAttachment,
                 <<"preview">> => Preview,
                 <<"attachments">> => Attachments,
                 ?MAILIO_NS => #{<<"imap">> => imap_map(MailboxId, Opts),
                                 <<"parse_version">> => ?PARSE_VERSION,
                                 <<"from_norm">> => norm_addrs(From),
                                 <<"to_norm">> => norm_addrs(To ++ Cc ++ Bcc),
                                 <<"subject_norm">> => SubjectNorm,
                                 <<"received_ts">> => ReceivedTs}},

    %% Write supporting docs first, the email doc LAST (see module note).
    Supporting = [ThreadDoc | MsgidDocs] ++ [TextDoc],
    _ = mailio_db:put_batch(Db, Supporting),
    {ok, _, _} = mailio_db:put(Db, EmailDoc),
    bump_mailbox(Db, MailboxId, +1, seen_delta(is_seen_kw(Keywords), false)).

%%====================================================================
%% Content extraction
%%====================================================================

extract_content(Part) ->
    Leaves = mailio_mime:leaves(Part),
    {Texts, Atts} = lists:foldl(fun collect_leaf/2, {[], []}, Leaves),
    BodyText = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Texts))),
    {BodyText, lists:reverse(Atts)}.

collect_leaf(Leaf, {Texts, Atts}) ->
    case mailio_mime:is_attachment(Leaf) of
        true ->
            {Texts, [attachment_summary(Leaf) | Atts]};
        false ->
            case {mailio_mime:type(Leaf), mailio_mime:subtype(Leaf)} of
                {<<"text">>, <<"plain">>} ->
                    {[text_utf8(Leaf) | Texts], Atts};
                {<<"text">>, <<"html">>} ->
                    Html = text_utf8(Leaf),
                    {[mailio_html_text:to_text(Html) | Texts], Atts};
                _ ->
                    {Texts, Atts}
            end
    end.

text_utf8(Leaf) ->
    mailio_mime_decode:to_utf8(mailio_mime:body(Leaf), mailio_mime:charset(Leaf)).

attachment_summary(Leaf) ->
    Body = mailio_mime:body(Leaf),
    #{<<"type">> => mailio_mime:content_type(Leaf),
      <<"name">> => null_or(mailio_mime:filename(Leaf)),
      <<"size">> => byte_size(Body)}.

preview(BodyText) ->
    Collapsed = collapse_ws(BodyText),
    case string:length(Collapsed) =< 200 of
        true -> Collapsed;
        false -> unicode:characters_to_binary(string:slice(Collapsed, 0, 200))
    end.

collapse_ws(Bin) ->
    Parts = [P || P <- binary:split(Bin, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
                                    [global]), P =/= <<>>],
    iolist_to_binary(lists:join(<<" ">>, Parts)).

%%====================================================================
%% Mailbox docs and counters
%%====================================================================

%% Auto-create a minimal mailbox doc when first referenced. Real folder
%% metadata is filled in by the IMAP adapter in later milestones.
ensure_mailbox(Db, MailboxId) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, _} -> ok;
        {error, not_found} ->
            Doc = mailio_mailbox:new(MailboxId, #{name => MailboxId}),
            {ok, _, _} = mailio_db:put(Db, Doc),
            ok
    end.

bump_mailbox(Db, MailboxId, TotalDelta, UnreadDelta) ->
    DocId = <<?ID_MAILBOX, MailboxId/binary>>,
    case mailio_db:get(Db, DocId) of
        {ok, Doc} ->
            Total = maps:get(<<"totalEmails">>, Doc, 0) + TotalDelta,
            Unread = maps:get(<<"unreadEmails">>, Doc, 0) + UnreadDelta,
            Doc1 = Doc#{<<"totalEmails">> => max(0, Total),
                        <<"unreadEmails">> => max(0, Unread)},
            {ok, _, _} = mailio_db:put(Db, Doc1),
            ok;
        {error, not_found} ->
            ok
    end.

seen_delta(IsSeen, _Was) when IsSeen -> 0;
seen_delta(_IsSeen, _Was) -> 1.

is_seen_kw(Keywords) -> maps:is_key(?KW_SEEN, Keywords).

%%====================================================================
%% Keyword / imap helpers
%%====================================================================

keywords_map(List) ->
    maps:from_list([{K, true} || K <- List]).

apply_keywords(Email, []) -> Email;
apply_keywords(Email, [K | Rest]) ->
    apply_keywords(mailio_email:add_keyword(Email, K), Rest).

add_imap_entry(Email, MailboxId, Opts) ->
    case maps:get(uid, Opts, undefined) of
        undefined -> Email;
        Uid ->
            Entry = #{<<"uid">> => Uid,
                      <<"uidvalidity">> => maps:get(uidvalidity, Opts, 0),
                      <<"modseq">> => maps:get(modseq, Opts, 0)},
            mailio_email:add_imap_entry(Email, MailboxId, Entry)
    end.

imap_map(MailboxId, Opts) ->
    case maps:get(uid, Opts, undefined) of
        undefined -> #{};
        Uid ->
            #{MailboxId => [#{<<"uid">> => Uid,
                              <<"uidvalidity">> => maps:get(uidvalidity, Opts, 0),
                              <<"modseq">> => maps:get(modseq, Opts, 0)}]}
    end.

%%====================================================================
%% Header helpers
%%====================================================================

headers_of(Part) ->
    maps:get(headers, Part, []).

addresses(Name, Headers) ->
    Raw = mailio_rfc5322:header(Name, Headers),
    [to_jmap_addr(A) || A <- mailio_rfc5322:parse_addresses(Raw)].

to_jmap_addr(#{name := Name, email := Email}) ->
    #{<<"name">> => null_or(Name), <<"email">> => Email}.

participant_addrs(Addrs) ->
    lists:usort([E || #{<<"email">> := E} <- Addrs]).

norm_addrs(Addrs) ->
    lists:usort([mailio_ascii:lower(E) || #{<<"email">> := E} <- Addrs]).

received_ts(Opts, Headers) ->
    case maps:get(received_at, Opts, undefined) of
        Ts when is_integer(Ts) -> Ts;
        _ ->
            case mailio_rfc5322:parse_date(mailio_rfc5322:header(<<"date">>, Headers)) of
                {ok, Epoch} -> Epoch;
                error -> erlang:system_time(second)
            end
    end.

sent_ts(Headers) ->
    case mailio_rfc5322:parse_date(mailio_rfc5322:header(<<"date">>, Headers)) of
        {ok, Epoch} -> Epoch;
        error -> undefined
    end.

sent_at(undefined) -> null;
sent_at(Ts) -> rfc3339(Ts).

rfc3339(Ts) ->
    list_to_binary(calendar:system_time_to_rfc3339(Ts, [{offset, "Z"}])).

%%====================================================================
%% Small value helpers
%%====================================================================

maybe_list(undefined) -> [];
maybe_list(X) -> [X].

null_or(undefined) -> null;
null_or(null) -> null;
null_or(X) -> X.

null_or_list([]) -> null;
null_or_list(L) when is_list(L) -> L.

%%====================================================================
%% Event emission
%%====================================================================

emit_events(#state{account_id = AccountId, emit_cursor = Cursor} = State) ->
    {ok, Envelopes, NewCursor, _More} =
        mailio_changes:since(AccountId, Cursor, #{}),
    lists:foreach(fun mailio_events:dispatch/1, Envelopes),
    State#state{emit_cursor = NewCursor}.
