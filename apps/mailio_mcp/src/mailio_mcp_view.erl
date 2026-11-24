%%% @doc Shapes internal message maps into compact tool output and builds
%%% the signed handles that name a message occurrence.
-module(mailio_mcp_view).

-export([
    handle/2,
    part_handle/3,
    loc_from_handle/3,
    loc/1,
    hit_out/4,
    addr_line/1,
    addr_list/1,
    instant/1,
    basis_value/2,
    error_text/1
]).

%% @doc Location of a hit inside its account: what an adapter needs.
loc(#{uidl := L, mailbox := M}) -> #{mailbox => M, uidl => L};
loc(#{mailbox := M, uv := V, uid := U}) -> #{mailbox => M, uv => V, uid => U}.

handle(Principal, Hit) ->
    mailio_mcp_handle:encode(msg, Principal, loc_payload(Hit)).

part_handle(Principal, Hit, PartId) ->
    mailio_mcp_handle:encode(part, Principal, (loc_payload(Hit))#{<<"p">> => PartId}).

loc_payload(#{account := A, uidl := L, mailbox := M}) ->
    #{<<"a">> => A, <<"m">> => M, <<"l">> => L};
loc_payload(#{account := A, mailbox := M, uv := V, uid := U}) ->
    #{<<"a">> => A, <<"m">> => M, <<"v">> => V, <<"u">> => U}.

%% @doc Resolve a message or part handle for the principal.
-spec loc_from_handle(msg | part, binary(), binary()) ->
    {ok, binary(), map(), binary() | undefined} | {error, term()}.
loc_from_handle(Kind, Principal, Token) ->
    case mailio_mcp_handle:decode(Kind, Principal, Token) of
        {ok, #{<<"a">> := A, <<"m">> := M} = P} ->
            Loc =
                case P of
                    #{<<"l">> := L} -> #{mailbox => M, uidl => L};
                    #{<<"v">> := V, <<"u">> := U} -> #{mailbox => M, uv => V, uid => U}
                end,
            {ok, A, Loc, maps:get(<<"p">>, P, undefined)};
        {error, _} = E ->
            E
    end.

addr_line([]) -> <<>>;
addr_line([A | _]) -> mailio_mcp_mime:format_addr(A).

addr_list(L) -> [mailio_mcp_mime:format_addr(A) || A <- L].

instant(undefined) -> null;
instant(T) -> mailio_mcp_time:to_rfc3339(T).

basis_value(received_at, H) -> maps:get(received_at, H, undefined);
basis_value(sent_at, H) -> maps:get(sent_at, H, undefined);
basis_value(first_seen_at, H) -> maps:get(first_seen_at, H, undefined).

%% @doc Output map for one hit with the selected fields.
hit_out(Principal, Hit, Fields, Basis) ->
    Base = #{
        <<"handle">> => handle(Principal, Hit),
        <<"account">> => maps:get(account, Hit),
        <<"mailbox">> => maps:get(mailbox, Hit)
    },
    lists:foldl(
        fun(F, Acc) -> field(F, Hit, Basis, Acc) end,
        Base,
        lists:usort(Fields ++ [copies])
    ).

field(from, H, _, A) ->
    A#{<<"from">> => addr_line(maps:get(from, H, []))};
field(to, H, _, A) ->
    A#{<<"to">> => addr_list(maps:get(to, H, []))};
field(subject, H, _, A) ->
    A#{<<"subject">> => maps:get(subject, H, <<>>)};
field(date, H, Basis, A) ->
    A#{<<"date">> => instant(basis_value(Basis, H))};
field(flags, H, _, A) ->
    A#{
        <<"unread">> =>
            case maps:get(unread, H, false) of
                undefined -> null;
                U -> U
            end
    };
field(attachments, H, _, A) ->
    A#{<<"attachments">> => maps:get(attachment_count, H, 0)};
field(size, H, _, A) ->
    A#{<<"size">> => maps:get(size, H, 0)};
field(excerpt, H, _, A) ->
    case maps:get(excerpt, H, undefined) of
        undefined -> A;
        E -> A#{<<"excerpt">> => E}
    end;
field(copies, H, _, A) ->
    case maps:get(copies, H, []) of
        [] -> A;
        C -> A#{<<"copies">> => C}
    end;
field(_, _, _, A) ->
    A.

error_text(unknown_account) ->
    <<"Unknown account. Call accounts_list to see the account ids you can use.">>;
error_text(account_ids_required) ->
    <<"Several accounts are visible. Pass account_ids as a list of ids, or \"all\" for every authorized account.">>;
error_text(no_accounts) ->
    <<"No account is available to this caller.">>;
error_text(bad_account_ids) ->
    <<"account_ids must be a non-empty list of ids or the string \"all\".">>;
error_text({forbidden, Need}) ->
    iolist_to_binary([
        "This caller may not do that on this account (needs the ", atom_to_binary(Need), " role)."
    ]);
error_text(invalid_handle) ->
    <<"Invalid or expired handle. Run mail_search again to get a fresh one.">>;
error_text(invalid_cursor) ->
    <<"Invalid cursor. Repeat the search without a cursor.">>;
error_text(cursor_query_mismatch) ->
    <<"The cursor belongs to a different search. Repeat the search without a cursor.">>;
error_text(stale_handle) ->
    <<"The mailbox was reset by the server, so this handle is no longer valid. Run mail_search again.">>;
error_text(message_gone) ->
    <<"The message no longer exists. Run mail_changes to see removals.">>;
error_text(mailbox_not_found) ->
    <<"Mailbox not found. Call mailboxes_list for the names.">>;
error_text(part_not_found) ->
    <<"Part not found in this message. Call mail_read on the message handle to list parts.">>;
error_text(time_zone_required) ->
    <<"Date-only values need time_zone, for example Europe/Paris.">>;
error_text({bad_time, V}) ->
    iolist_to_binary([
        "Bad time value: ",
        V,
        ". Use RFC 3339 (2026-03-29T00:00:00+01:00) or YYYY-MM-DD with time_zone."
    ]);
error_text(bad_date) ->
    <<"Bad date. Use YYYY-MM-DD.">>;
error_text({unknown_time_zone, Z}) ->
    iolist_to_binary(["Unknown IANA time zone: ", Z]);
error_text(checkpoint_expired) ->
    <<
        "The checkpoint is no longer usable (the mailbox was reset or the checkpoint is too old). Call "
        "mail_changes again without a checkpoint to take a new baseline, then search for anything you "
        "need from the gap."
    >>;
error_text(checkpoint_invalid) ->
    <<"Invalid checkpoint. Call mail_changes without a checkpoint to take a new one.">>;
error_text({unavailable, R}) ->
    iolist_to_binary(["Mail server unavailable: ", format(R)]);
error_text({basis_unavailable, B, Alt}) ->
    iolist_to_binary([
        "This account cannot filter by ",
        atom_to_binary(B),
        ". Use time_basis ",
        lists:join(" or ", [atom_to_binary(A) || A <- Alt]),
        "."
    ]);
error_text({unsupported_filter, F, Why}) ->
    iolist_to_binary(["This account cannot filter by ", atom_to_binary(F), ". ", Why]);
error_text({missing, K}) ->
    iolist_to_binary(["Missing argument: ", K]);
error_text({bad_argument, K}) ->
    iolist_to_binary(["Bad argument: ", K]);
error_text(R) when is_binary(R) -> R;
error_text(R) ->
    iolist_to_binary(io_lib:format("~p", [R])).

format(R) when is_binary(R) -> R;
format(authentication_failed) -> <<"authentication failed">>;
format({connect, R}) -> iolist_to_binary(io_lib:format("cannot connect (~p)", [R]));
format(R) -> iolist_to_binary(io_lib:format("~p", [R])).
