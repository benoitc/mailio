%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Static capability table per protocol, and the effective
%%% capabilities shown for an account (protocol facts plus the caller's role).
-module(mailio_mcp_caps).
-export([static/1, effective/2]).

static(imap) ->
    #{
        protocol => <<"imap">>,
        filters_native => [
            <<"from">>, <<"to">>, <<"subject">>, <<"text">>, <<"unread">>, <<"mailbox">>
        ],
        filters_local => [<<"has_attachment">>, <<"exact_time">>, <<"first_seen_at">>],
        time_bases => [<<"received_at">>, <<"sent_at">>, <<"first_seen_at">>],
        mailboxes => true,
        changes => <<"uid_and_flag_diff">>
    };
static(pop3) ->
    #{
        protocol => <<"pop3">>,
        filters_native => [],
        filters_local => [
            <<"from">>,
            <<"to">>,
            <<"subject">>,
            <<"text_headers_only">>,
            <<"has_attachment_when_known">>,
            <<"exact_time">>,
            <<"first_seen_at">>
        ],
        time_bases => [<<"sent_at">>, <<"first_seen_at">>],
        mailboxes => false,
        changes => <<"uidl_diff">>
    }.

effective(Account, Role) ->
    #{incoming := #{protocol := P}, outgoing := Out} = Account,
    Base = static(P),
    CanSend = maps:size(Out) > 0 andalso maps:is_key(host, Out),
    Base#{
        role => atom_to_binary(Role),
        can_read => true,
        can_draft => lists:member(Role, [draft, send]),
        can_send => Role =:= send andalso CanSend
    }.
