%%% @doc Opaque per-account state tokens (JMAP-style).
%%%
%%% Wraps a barrel HLC changes cursor in a versioned, base64url-encoded
%%% token. JMAP clients treat the token as opaque; internally it decodes
%%% back to the HLC timestamp (or `first') to resume the changes feed.
-module(mailio_cursor).

-export([encode/1, decode/1, initial/0]).

-export_type([token/0]).

-type token() :: binary().

%% @doc The token representing "from the beginning".
-spec initial() -> token().
initial() ->
    encode(first).

%% @doc Encode an HLC cursor (or `first') into an opaque token.
-spec encode(barrel_hlc:timestamp() | first) -> token().
encode(Cursor) ->
    Payload = term_to_binary(#{v => 1, c => Cursor}),
    base64url_encode(Payload).

%% @doc Decode a token back to a barrel cursor. Returns `{error, invalid_state}'
%% for anything that is not a token this module produced.
-spec decode(token()) -> {ok, barrel_hlc:timestamp() | first} | {error, invalid_state}.
decode(Token) when is_binary(Token) ->
    try
        Bin = base64url_decode(Token),
        #{v := 1, c := Cursor} = binary_to_term(Bin, [safe]),
        {ok, Cursor}
    catch _:_ ->
        {error, invalid_state}
    end;
decode(_) ->
    {error, invalid_state}.

%%====================================================================
%% base64url (no padding)
%%====================================================================

base64url_encode(Bin) ->
    B64 = base64:encode(Bin),
    Stripped = binary:replace(B64, <<"=">>, <<>>, [global]),
    Url = binary:replace(Stripped, <<"+">>, <<"-">>, [global]),
    binary:replace(Url, <<"/">>, <<"_">>, [global]).

base64url_decode(Bin) ->
    Std0 = binary:replace(Bin, <<"-">>, <<"+">>, [global]),
    Std = binary:replace(Std0, <<"_">>, <<"/">>, [global]),
    Padded = case byte_size(Std) rem 4 of
                 0 -> Std;
                 2 -> <<Std/binary, "==">>;
                 3 -> <<Std/binary, "=">>;
                 _ -> Std
             end,
    base64:decode(Padded).
