%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc IMAP to JMAP mapping (pure).
%%%
%%% Translates between IMAP wire concepts and Mailio's JMAP-shaped model:
%%% system flags and keywords, folder attributes and names and mailbox roles,
%%% and the per-mailbox sync cursor `{uidvalidity, highestmodseq, uidnext}'
%%% and an opaque adapter `remote_state' binary.
-module(mailio_imap_map).

-include("mailio.hrl").

-export([
    flag_to_keyword/1,
    keyword_to_flag/1,
    flags_to_keywords/1,
    keywords_to_flags/1,
    is_representable_keyword/1
]).
-export([role_of/2, mailbox_id/1]).
-export([
    encode_state/1,
    decode_state/1,
    state_uidvalidity/1,
    state_modseq/1,
    state_uidnext/1
]).

%%====================================================================
%% Flags <-> keywords
%%====================================================================

%% @doc Map an IMAP system flag (or keyword) to a JMAP keyword. Unknown
%% server keywords are lowercased; system flags map to their `$' form.
-spec flag_to_keyword(binary()) -> binary().
flag_to_keyword(<<"\\Seen">>) -> ?KW_SEEN;
flag_to_keyword(<<"\\Answered">>) -> ?KW_ANSWERED;
flag_to_keyword(<<"\\Flagged">>) -> ?KW_FLAGGED;
flag_to_keyword(<<"\\Draft">>) -> ?KW_DRAFT;
flag_to_keyword(<<"\\Deleted">>) -> <<"$deleted">>;
flag_to_keyword(<<"\\Recent">>) -> <<"$recent">>;
flag_to_keyword(<<"$", _/binary>> = Kw) -> mailio_ascii:lower(Kw);
flag_to_keyword(<<"\\", Rest/binary>>) -> <<"$", (mailio_ascii:lower(Rest))/binary>>;
flag_to_keyword(Other) -> mailio_ascii:lower(Other).

%% @doc Map a JMAP keyword back to an IMAP flag. Returns `undefined' for
%% keywords that have no IMAP representation (kept local-only).
-spec keyword_to_flag(binary()) -> binary() | undefined.
keyword_to_flag(?KW_SEEN) ->
    <<"\\Seen">>;
keyword_to_flag(?KW_ANSWERED) ->
    <<"\\Answered">>;
keyword_to_flag(?KW_FLAGGED) ->
    <<"\\Flagged">>;
keyword_to_flag(?KW_DRAFT) ->
    <<"\\Draft">>;
keyword_to_flag(<<"$deleted">>) ->
    <<"\\Deleted">>;
keyword_to_flag(<<"$forwarded">>) ->
    <<"$Forwarded">>;
keyword_to_flag(Kw) ->
    case is_atom_safe(Kw) of
        %% custom keyword the server can store as-is
        true -> Kw;
        %% not representable as an IMAP atom
        false -> undefined
    end.

-spec flags_to_keywords([binary()]) -> #{binary() => true}.
flags_to_keywords(Flags) ->
    maps:from_list([
        {flag_to_keyword(F), true}
     || F <- Flags,
        F =/= <<"\\Recent">>
    ]).

-spec keywords_to_flags([binary()]) -> [binary()].
keywords_to_flags(Keywords) ->
    lists:usort(
        lists:filtermap(
            fun(K) ->
                case keyword_to_flag(K) of
                    undefined -> false;
                    F -> {true, F}
                end
            end,
            Keywords
        )
    ).

-spec is_representable_keyword(binary()) -> boolean().
is_representable_keyword(Kw) ->
    keyword_to_flag(Kw) =/= undefined.

%%====================================================================
%% Folders <-> mailbox roles
%%====================================================================

%% @doc Determine a mailbox role from SPECIAL-USE attributes, falling back
%% to well-known name heuristics. Returns `undefined' for ordinary folders.
-spec role_of([binary()], binary()) -> atom() | undefined.
role_of(Attrs, Name) ->
    case role_from_attrs(Attrs) of
        undefined -> role_from_name(Name);
        Role -> Role
    end.

role_from_attrs(Attrs) ->
    Lower = [mailio_ascii:lower(A) || A <- Attrs],
    Mapping = [
        {<<"\\inbox">>, inbox},
        {<<"\\sent">>, sent},
        {<<"\\drafts">>, drafts},
        {<<"\\trash">>, trash},
        {<<"\\junk">>, junk},
        {<<"\\archive">>, archive},
        {<<"\\all">>, all},
        {<<"\\flagged">>, flagged}
    ],
    case [Role || {Attr, Role} <- Mapping, lists:member(Attr, Lower)] of
        [Role | _] -> Role;
        [] -> undefined
    end.

role_from_name(Name) ->
    case mailio_ascii:lower(Name) of
        <<"inbox">> -> inbox;
        <<"sent">> -> sent;
        <<"sent items">> -> sent;
        <<"sent messages">> -> sent;
        <<"drafts">> -> drafts;
        <<"draft">> -> drafts;
        <<"trash">> -> trash;
        <<"deleted">> -> trash;
        <<"deleted items">> -> trash;
        <<"junk">> -> junk;
        <<"spam">> -> junk;
        <<"junk e-mail">> -> junk;
        <<"archive">> -> archive;
        _ -> undefined
    end.

%% @doc Stable mailbox id for an IMAP folder. The folder name is the
%% adapter-native id; the sync engine maps it to a local mailbox id.
-spec mailbox_id(binary()) -> binary().
mailbox_id(ImapName) -> ImapName.

%%====================================================================
%% Sync cursor (remote_state)
%%====================================================================

%% @doc Encode a per-mailbox cursor into an opaque adapter state binary.
-spec encode_state(#{
    uidvalidity := non_neg_integer(),
    highestmodseq => non_neg_integer() | undefined,
    uidnext := non_neg_integer(),
    page => undefined | {added | updated, pos_integer(), non_neg_integer() | undefined}
}) -> binary().
encode_state(#{uidvalidity := UidValidity, uidnext := UidNext} = S) ->
    ModSeq = maps:get(highestmodseq, S, undefined),
    case maps:get(page, S, undefined) of
        undefined ->
            term_to_binary({imap_state, 1, UidValidity, ModSeq, UidNext});
        Page ->
            term_to_binary({imap_state, 2, UidValidity, ModSeq, UidNext, Page})
    end.

%% @doc Decode an adapter state binary (or `initial').
-spec decode_state(binary() | initial) ->
    #{
        uidvalidity := non_neg_integer() | undefined,
        highestmodseq := non_neg_integer() | undefined,
        uidnext := non_neg_integer() | undefined
    }.
decode_state(initial) ->
    #{uidvalidity => undefined, highestmodseq => undefined, uidnext => undefined};
decode_state(Bin) when is_binary(Bin) ->
    try binary_to_term(Bin, [safe]) of
        {imap_state, 1, UidValidity, ModSeq, UidNext} ->
            #{uidvalidity => UidValidity, highestmodseq => ModSeq, uidnext => UidNext};
        {imap_state, 2, UidValidity, ModSeq, UidNext, Page} ->
            #{
                uidvalidity => UidValidity,
                highestmodseq => ModSeq,
                uidnext => UidNext,
                page => Page
            };
        _ ->
            decode_state(initial)
    catch
        _:_ ->
            decode_state(initial)
    end.

-spec state_uidvalidity(binary() | initial) -> non_neg_integer() | undefined.
state_uidvalidity(State) -> maps:get(uidvalidity, decode_state(State)).

-spec state_modseq(binary() | initial) -> non_neg_integer() | undefined.
state_modseq(State) -> maps:get(highestmodseq, decode_state(State)).

-spec state_uidnext(binary() | initial) -> non_neg_integer() | undefined.
state_uidnext(State) -> maps:get(uidnext, decode_state(State)).

%%====================================================================
%% Internal
%%====================================================================

%% An IMAP atom (usable as a flag) excludes specials and control chars.
is_atom_safe(<<>>) -> false;
is_atom_safe(Bin) -> lists:all(fun atom_char/1, binary_to_list(Bin)).

atom_char(C) ->
    C > 32 andalso C < 127 andalso
        not lists:member(C, [$(, $), ${, $%, $*, $", $\\, $], $\s]).
