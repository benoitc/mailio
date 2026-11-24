%%% @doc Consistency check and repair for an account database.
%%%
%%% Mailbox `totalEmails'/`unreadEmails' counters are maintained
%%% incrementally by the writer, so a crash between a counter update and the
%%% email write (barrel batches are not atomic) can leave them drifted. This
%%% module recomputes the ground truth by scanning the email documents and
%%% reports — or repairs — any divergence. Repairs run through the writer so
%%% they cannot race live ingestion.
-module(mailio_fsck).

-include("mailio_store.hrl").

-export([check_counters/1, repair_counters/1, recompute/1]).

-export_type([drift/0]).

-type drift() :: #{mailbox_id := binary(),
                   total := {Stored :: integer(), Actual :: integer()},
                   unread := {Stored :: integer(), Actual :: integer()}}.

%%====================================================================
%% API
%%====================================================================

%% @doc Return the per-mailbox counter drift (stored vs recomputed). An
%% empty list means the counters are consistent.
-spec check_counters(binary()) -> {ok, [drift()]}.
check_counters(AccountId) ->
    Db = mailio_account:db_name(AccountId),
    Actual = recompute(AccountId),
    Drifts = lists:filtermap(
        fun(#{<<"id">> := <<?ID_MAILBOX, MailboxId/binary>>} = Mbx) ->
            {AT, AU} = maps:get(MailboxId, Actual, {0, 0}),
            ST = maps:get(<<"totalEmails">>, Mbx, 0),
            SU = maps:get(<<"unreadEmails">>, Mbx, 0),
            case {ST, SU} =:= {AT, AU} of
                true -> false;
                false ->
                    {true, #{mailbox_id => MailboxId,
                             total => {ST, AT}, unread => {SU, AU}}}
            end
        end, all_mailboxes(Db)),
    {ok, Drifts}.

%% @doc Recompute and persist correct counters for every mailbox.
-spec repair_counters(binary()) -> {ok, Repaired :: non_neg_integer()}.
repair_counters(AccountId) ->
    {ok, Drifts} = check_counters(AccountId),
    Actual = recompute(AccountId),
    lists:foreach(
        fun(#{mailbox_id := MailboxId}) ->
            {T, U} = maps:get(MailboxId, Actual, {0, 0}),
            ok = mailio_account_writer:set_counters(AccountId, MailboxId, T, U)
        end, Drifts),
    {ok, length(Drifts)}.

%% @doc Recompute `#{MailboxId => {Total, Unread}}' from the email docs.
-spec recompute(binary()) -> #{binary() => {integer(), integer()}}.
recompute(AccountId) ->
    Db = mailio_account:db_name(AccountId),
    {ok, Emails} = mailio_db:by_id_prefix(Db, <<?ID_EMAIL>>),
    lists:foldl(fun tally_email/2, #{}, Emails).

%%====================================================================
%% Internal
%%====================================================================

tally_email(Email, Acc) ->
    Seen = mailio_email:is_seen(Email),
    Mailboxes = mailio_email:mailbox_ids(Email),
    lists:foldl(
        fun(MailboxId, A) ->
            {T, U} = maps:get(MailboxId, A, {0, 0}),
            U1 = case Seen of true -> U; false -> U + 1 end,
            A#{MailboxId => {T + 1, U1}}
        end, Acc, Mailboxes).

%% Enumerate mailbox docs by their id namespace.
all_mailboxes(Db) ->
    {ok, Docs} = mailio_db:by_id_prefix(Db, <<?ID_MAILBOX>>),
    Docs.
