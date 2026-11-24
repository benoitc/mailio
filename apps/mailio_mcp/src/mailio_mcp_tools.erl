%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc MCP tool definitions and handlers. Seven tools, short schemas,
%%% accurate read/write annotations. Handlers are thin: they identify the
%%% caller and delegate.
-module(mailio_mcp_tools).

-export([register/0, catalog/0]).
-export([
    accounts_list/2,
    mailboxes_list/2,
    mail_search/2,
    mail_read/2,
    mail_changes/2,
    draft_save/2,
    draft_send/2
]).

-define(STR, #{<<"type">> => <<"string">>}).

register() ->
    lists:foreach(
        fun({Name, Fun, Opts}) -> ok = barrel_mcp:reg_tool(Name, ?MODULE, Fun, Opts) end,
        catalog()
    ),
    ok = barrel_mcp:reg_resource_template(<<"mail_part">>, mailio_mcp_read, read_resource, #{
        name => <<"Mail attachment">>,
        uri_template => <<"mail://part/{handle}">>,
        description => <<"One MIME part of a message. Use the resource_uri from mail_read.">>
    }),
    ok.

obj(Props) -> obj(Props, []).
obj(Props, Req) ->
    S = #{<<"type">> => <<"object">>, <<"properties">> => maps:from_list(Props)},
    case Req of
        [] -> S;
        _ -> S#{<<"required">> => Req}
    end.

str(D) -> #{<<"type">> => <<"string">>, <<"description">> => D}.
bool(D) -> #{<<"type">> => <<"boolean">>, <<"description">> => D}.
int(D) -> #{<<"type">> => <<"integer">>, <<"description">> => D}.
strs(D) -> #{<<"type">> => <<"array">>, <<"items">> => ?STR, <<"description">> => D}.

accounts_prop() ->
    {<<"account_ids">>, #{
        <<"description">> =>
            <<"Account ids from accounts_list, or the string \"all\". Optional only when one account is visible.">>,
        <<"oneOf">> => [
            #{<<"type">> => <<"array">>, <<"items">> => ?STR}, #{<<"type">> => <<"string">>}
        ]
    }}.

catalog() ->
    RO = #{
        <<"readOnlyHint">> => true,
        <<"destructiveHint">> => false,
        <<"idempotentHint">> => true,
        <<"openWorldHint">> => true
    },
    [
        {<<"accounts_list">>, accounts_list, #{
            description =>
                <<"List the mail accounts you can use, with ids, roles, sender addresses and capabilities.">>,
            input_schema => obj([
                {<<"discover">>,
                    bool(<<"Connect to each server to report reachability and extensions.">>)}
            ]),
            annotations => RO
        }},
        {<<"mailboxes_list">>, mailboxes_list, #{
            description => <<"List mailboxes (folders) of an account.">>,
            input_schema => obj([
                accounts_prop(), {<<"counts">>, bool(<<"Include message and unread counts.">>)}
            ]),
            annotations => RO
        }},
        {<<"mail_search">>, mail_search, #{
            description => <<
                "Search mail. Returns metadata only, at most 20 hits and 8 KiB. Open a hit with mail_read. "
                "Dates: use on=YYYY-MM-DD with time_zone, or since/before (RFC 3339, or dates with "
                "time_zone; start inclusive, end exclusive)."
            >>,
            input_schema => obj([
                accounts_prop(),
                {<<"mailbox">>, str(<<"Mailbox name. Default INBOX.">>)},
                {<<"from">>, str(<<"Sender contains.">>)},
                {<<"to">>, str(<<"Recipient (to, cc or bcc) contains.">>)},
                {<<"subject">>, str(<<"Subject contains.">>)},
                {<<"text">>, str(<<"Text contains (headers and body).">>)},
                {<<"unread">>, bool(<<"Only unread (true) or only read (false).">>)},
                {<<"has_attachment">>,
                    bool(<<"Only messages with (true) or without (false) attachments.">>)},
                {<<"on">>, str(<<"One local day, YYYY-MM-DD. Needs time_zone.">>)},
                {<<"since">>, str(<<"Start, inclusive.">>)},
                {<<"before">>, str(<<"End, exclusive.">>)},
                {<<"time_zone">>, str(<<"IANA zone such as Europe/Paris, for date-only values.">>)},
                {<<"time_basis">>, #{
                    <<"type">> => <<"string">>,
                    <<"enum">> => [<<"received_at">>, <<"sent_at">>, <<"first_seen_at">>]
                }},
                {<<"limit">>, int(<<"Hits per page, at most 20.">>)},
                {<<"fields">>,
                    strs(<<"Any of from,to,subject,date,flags,attachments,size,excerpt,copies.">>)},
                {<<"count_only">>, bool(<<"Return only the count.">>)},
                {<<"cursor">>, str(<<"next_cursor from the previous page.">>)},
                {<<"refresh">>, bool(<<"Bypass the cache and ask the server.">>)}
            ]),
            annotations => RO
        }},
        {<<"mail_read">>, mail_read, #{
            description => <<
                "Open a message, a thread timeline (mode=thread) or one attachment from a handle. "
                "Text is paged: use offset and limit. Opening does not mark mail as read."
            >>,
            input_schema => obj(
                [
                    {<<"handle">>,
                        str(
                            <<"A message handle from mail_search, or a part_handle from mail_read.">>
                        )},
                    {<<"mode">>, #{
                        <<"type">> => <<"string">>, <<"enum">> => [<<"message">>, <<"thread">>]
                    }},
                    {<<"expand">>, #{
                        <<"type">> => <<"string">>,
                        <<"enum">> => [<<"latest">>],
                        <<"description">> =>
                            <<"With mode=thread, also include the latest message text.">>
                    }},
                    {<<"offset">>, int(<<"Text byte offset (next_offset).">>)},
                    {<<"limit">>, int(<<"Text bytes to return, default 3000, at most 6000.">>)},
                    {<<"quoted">>, bool(<<"Include quoted reply history.">>)},
                    {<<"include_content">>, bool(<<"For a small binary part, return base64.">>)}
                ],
                [<<"handle">>]
            ),
            annotations => RO
        }},
        {<<"mail_changes">>, mail_changes, #{
            description => <<
                "What changed in a mailbox since a checkpoint. Call without checkpoint to take a baseline. "
                "Returns additions, flag updates and removals, plus a new checkpoint."
            >>,
            input_schema => obj([
                accounts_prop(),
                {<<"mailbox">>, str(<<"Default INBOX.">>)},
                {<<"checkpoint">>, str(<<"The checkpoint from the previous call.">>)},
                {<<"wait_seconds">>,
                    int(
                        <<
                            "With a checkpoint and nothing new yet, wait up to this many seconds "
                            "(at most 25) for the server to report a change."
                        >>
                    )}
            ]),
            annotations => RO,
            %% it may wait up to wait_seconds for a change
            timeout => 60000
        }},
        {<<"draft_save">>, draft_save, #{
            description => <<
                "Create or update a draft. Reply with reply_to=<message handle>: recipients, subject, "
                "threading headers and the sender identity are filled in. Nothing is sent."
            >>,
            input_schema => obj([
                accounts_prop(),
                {<<"draft_id">>, str(<<"Update this draft (creates a new revision).">>)},
                {<<"reply_to">>, str(<<"Message handle to reply to.">>)},
                {<<"reply_all">>, bool(<<"Also address the other recipients.">>)},
                {<<"from">>,
                    str(
                        <<
                            "Sender address; must be one of your identities. Defaults to the address the "
                            "original was sent to."
                        >>
                    )},
                {<<"to">>, strs(<<"Recipients.">>)},
                {<<"cc">>, strs(<<"Cc.">>)},
                {<<"bcc">>, strs(<<"Bcc.">>)},
                {<<"subject">>, str(<<"Subject.">>)},
                {<<"body">>, str(<<"Plain text body.">>)}
            ]),
            annotations => #{
                <<"readOnlyHint">> => false,
                <<"destructiveHint">> => false,
                <<"idempotentHint">> => false,
                <<"openWorldHint">> => false
            }
        }},
        {<<"draft_send">>, draft_send, #{
            description => <<
                "Send a draft revision. Needs the send role. A repeated idempotency_key returns the recorded "
                "result and never sends twice. Success means accepted for submission, not delivered."
            >>,
            input_schema => obj(
                [
                    {<<"draft_id">>, str(<<"Draft id.">>)},
                    {<<"revision">>, int(<<"Revision from draft_save.">>)},
                    {<<"idempotency_key">>, str(<<"Any unique string for this send.">>)}
                ],
                [<<"draft_id">>, <<"revision">>, <<"idempotency_key">>]
            ),
            annotations => #{
                <<"readOnlyHint">> => false,
                <<"destructiveHint">> => false,
                <<"idempotentHint">> => true,
                <<"openWorldHint">> => true
            },
            timeout => 120000
        }}
    ].

%%--------------------------------------------------------------------

accounts_list(Args, Ctx) ->
    P = mailio_mcp_authz:principal_from_ctx(Ctx),
    Discover = maps:get(<<"discover">>, Args, false) =:= true,
    Out = [
        begin
            {ok, A} = mailio_mcp_config:account(Id),
            Role = mailio_mcp_authz:role(P, Id),
            Caps0 = mailio_mcp_caps:effective(A, Role),
            Caps =
                case Discover of
                    true -> Caps0#{<<"server">> => discover(A)};
                    false -> Caps0
                end,
            #{
                <<"id">> => Id,
                <<"name">> => maps:get(name, A),
                <<"identities">> => [
                    mailio_mcp_mime:format_addr(I)
                 || I <- mailio_mcp_authz:identities(P, Id)
                ],
                <<"capabilities">> => Caps
            }
        end
     || Id <- mailio_mcp_authz:visible_accounts(P)
    ],
    reply(
        {ok, #{
            <<"accounts">> => Out,
            <<"now">> => mailio_mcp_time:to_rfc3339(erlang:system_time(second))
        }}
    ).

discover(A) ->
    C = mailio_mcp_adapter:call(A, capabilities, []),
    maps:from_list([
        {atom_to_binary(K), V}
     || {K, V} <- maps:to_list(
            maps:with([reachable, reason, extensions], C)
        )
    ]).

mailboxes_list(Args, Ctx) ->
    P = mailio_mcp_authz:principal_from_ctx(Ctx),
    reply(
        maybe
            {ok, Ids} ?= mailio_mcp_authz:select_accounts(P, Args),
            Counts = maps:get(<<"counts">>, Args, false) =:= true,
            Out = [
                begin
                    ok = mailio_mcp_authz:check(P, Id, read),
                    {ok, A} = mailio_mcp_config:account(Id),
                    case mailio_mcp_adapter:call(A, list_mailboxes, [Counts]) of
                        {ok, Boxes} ->
                            #{
                                <<"account">> => Id,
                                <<"mailboxes">> => [mbox(B) || B <- lists:sublist(Boxes, 100)]
                            };
                        {error, E} ->
                            #{
                                <<"account">> => Id,
                                <<"status">> => <<"offline">>,
                                <<"note">> => mailio_mcp_view:error_text(E)
                            }
                    end
                end
             || Id <- Ids
            ],
            {ok, #{<<"accounts">> => Out}}
        end
    ).

mbox(#{name := N, role := R} = B) ->
    M = #{<<"name">> => N, <<"role">> => atom_to_binary(R)},
    M2 =
        case maps:find(messages, B) of
            {ok, V} -> M#{<<"messages">> => V, <<"unseen">> => maps:get(unseen, B, 0)};
            error -> M
        end,
    case maps:get(selectable, B) of
        true -> M2;
        false -> M2#{<<"selectable">> => false}
    end.

mail_search(Args, Ctx) ->
    reply(mailio_mcp_search:run(mailio_mcp_authz:principal_from_ctx(Ctx), Args)).

mail_read(Args, Ctx) ->
    reply(mailio_mcp_read:run(mailio_mcp_authz:principal_from_ctx(Ctx), Args)).

mail_changes(Args, Ctx) ->
    reply(mailio_mcp_changes:run(mailio_mcp_authz:principal_from_ctx(Ctx), Args)).

draft_save(Args, Ctx) ->
    reply(mailio_mcp_draft:save(mailio_mcp_authz:principal_from_ctx(Ctx), Args)).

draft_send(Args, Ctx) ->
    P = mailio_mcp_authz:principal_from_ctx(Ctx),
    case
        {
            maps:get(<<"draft_id">>, Args, undefined),
            maps:get(<<"revision">>, Args, undefined),
            maps:get(<<"idempotency_key">>, Args, undefined)
        }
    of
        {D, R, K} when is_binary(D), is_integer(R), is_binary(K), K =/= <<>> ->
            reply(mailio_mcp_send:submit(P, D, R, K));
        _ ->
            reply(
                {error, {bad_argument, <<"draft_id, revision and idempotency_key are required">>}}
            )
    end.

reply({ok, Map}) -> Map;
reply({error, Reason}) -> {tool_error, mailio_mcp_view:error_text(norm(Reason))}.

norm({already_submitted, Rec}) ->
    iolist_to_binary([
        "This draft revision was already submitted under another idempotency_key: ",
        json:encode(Rec),
        ". Do not send again."
    ]);
norm({stale_revision, Cur}) ->
    iolist_to_binary([
        "Revision is out of date; the current revision is ",
        integer_to_binary(Cur),
        ". Review it with draft_save, then send that revision."
    ]);
norm(idempotency_key_reused) ->
    <<"This idempotency_key was already used for a different draft or content. Use a new key for a new send.">>;
norm(unknown_draft) ->
    <<"Unknown draft. Use the draft_id returned by draft_save.">>;
norm(draft_already_sent) ->
    <<"This draft was already submitted. Create a new draft to send another message.">>;
norm(no_recipients) ->
    <<"The draft has no recipients.">>;
norm(no_identity) ->
    <<"No sender identity is configured for this account.">>;
norm({identity_not_permitted, A}) ->
    iolist_to_binary(["You may not send as ", A, ". See identities in accounts_list."]);
norm(reply_account_mismatch) ->
    <<"A reply is sent from the account that received the message. Omit account_ids, or start a new draft.">>;
norm(too_many_recipients) ->
    <<"Too many recipients (limit 50).">>;
norm({bad_recipient, K}) ->
    iolist_to_binary(["Invalid address in ", K, "."]);
norm(R) ->
    R.
