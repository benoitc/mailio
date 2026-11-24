%%% @doc Identifier generation.
%%%
%%% Two families of ids:
%%% <ul>
%%%   <li>Allocated ids (account, mailbox, thread, identity, ...) are ULIDs:
%%%       lexicographically sortable, 128-bit, time-ordered.</li>
%%%   <li>Content-addressed ids (email, blob, msgid lookup) are derived from
%%%       a SHA-256 of the content so the same bytes always map to the same
%%%       id, making ingestion idempotent.</li>
%%% </ul>
-module(mailio_id).

-export([ulid/0]).
-export([email_id/1, blob_id/1, blob_hex/1, msgid_hash/1]).
-export([account_id/0, mailbox_id/0, thread_id/0, identity_id/0,
         submission_id/0, rule_id/0, job_id/0, grant_id/0]).
-export([b32_lower/1]).

%% Crockford base32, uppercase (ULID canonical).
-define(CROCKFORD_UPPER, <<"0123456789ABCDEFGHJKMNPQRSTVWXYZ">>).
%% Lowercase variant for content-addressed ids.
-define(CROCKFORD_LOWER, <<"0123456789abcdefghjkmnpqrstvwxyz">>).

%%====================================================================
%% Allocated ids
%%====================================================================

-spec account_id() -> binary().
account_id() -> ulid().

-spec mailbox_id() -> binary().
mailbox_id() -> ulid().

-spec thread_id() -> binary().
thread_id() -> ulid().

-spec identity_id() -> binary().
identity_id() -> ulid().

-spec submission_id() -> binary().
submission_id() -> ulid().

-spec rule_id() -> binary().
rule_id() -> ulid().

-spec job_id() -> binary().
job_id() -> ulid().

-spec grant_id() -> binary().
grant_id() -> ulid().

%% @doc Generate a ULID: 48-bit millisecond timestamp + 80 bits of
%% randomness, Crockford base32, 26 chars, sortable by creation time.
-spec ulid() -> binary().
ulid() ->
    Ms = erlang:system_time(millisecond),
    Rand = crypto:strong_rand_bytes(10),
    <<Int:128>> = <<Ms:48, Rand/binary>>,
    encode_base32_fixed(Int, 26, ?CROCKFORD_UPPER).

%%====================================================================
%% Content-addressed ids
%%====================================================================

%% @doc Email id: lowercase base32 of SHA-256(raw message), truncated to
%% 26 chars (130 bits). Same raw bytes -> same email id.
-spec email_id(binary()) -> binary().
email_id(Raw) when is_binary(Raw) ->
    <<Int:256>> = crypto:hash(sha256, Raw),
    Full = encode_base32_fixed(Int, 52, ?CROCKFORD_LOWER),
    binary:part(Full, 0, 26).

%% @doc Public blob id: `sha256-<hex>' of the content.
-spec blob_id(binary()) -> binary().
blob_id(Content) when is_binary(Content) ->
    <<"sha256-", (blob_hex(Content))/binary>>.

%% @doc Lowercase hex SHA-256, used as the `blob/<hex>' doc id segment.
-spec blob_hex(binary()) -> binary().
blob_hex(Content) when is_binary(Content) ->
    bin_to_hex(crypto:hash(sha256, Content)).

%% @doc Hash of a Message-ID header value for the `msgid/<hash>' lookup doc.
-spec msgid_hash(binary()) -> binary().
msgid_hash(MessageId) when is_binary(MessageId) ->
    bin_to_hex(crypto:hash(sha256, MessageId)).

%%====================================================================
%% Encoding helpers
%%====================================================================

%% @doc Encode an unsigned integer as exactly `Len' base32 chars,
%% left-padded with the zero symbol.
-spec encode_base32_fixed(non_neg_integer(), pos_integer(), binary()) -> binary().
encode_base32_fixed(Int, Len, Alphabet) ->
    encode_base32_fixed(Int, Len, Alphabet, []).

encode_base32_fixed(_Int, 0, _Alphabet, Acc) ->
    list_to_binary(Acc);
encode_base32_fixed(Int, Len, Alphabet, Acc) ->
    Idx = Int band 16#1F,
    Char = binary:at(Alphabet, Idx),
    encode_base32_fixed(Int bsr 5, Len - 1, Alphabet, [Char | Acc]).

%% @doc Lowercase base32 (Crockford) of an arbitrary binary, no padding.
-spec b32_lower(binary()) -> binary().
b32_lower(Bin) when is_binary(Bin) ->
    Bits = bit_size(Bin),
    Pad = (5 - (Bits rem 5)) rem 5,
    <<Int:Bits>> = Bin,
    Shifted = Int bsl Pad,
    Len = (Bits + Pad) div 5,
    encode_base32_fixed(Shifted, Len, ?CROCKFORD_LOWER).

-spec bin_to_hex(binary()) -> binary().
bin_to_hex(Bin) ->
    binary:encode_hex(Bin, lowercase).
