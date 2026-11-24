%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Signed opaque tokens for message handles, part handles, cursors and
%%% checkpoints. A token binds the caller, so a handle or cursor is useless
%%% to anybody else, and is checked again on every use.
-module(mailio_mcp_handle).
-export([encode/3, decode/3]).

-spec encode(atom(), binary(), map()) -> binary().
encode(Kind, Principal, Data) ->
    B = b64(iolist_to_binary(json:encode(Data))),
    <<B/binary, ".", (mac(Kind, Principal, B))/binary>>.

-spec decode(atom(), binary(), term()) -> {ok, map()} | {error, invalid_handle}.
decode(Kind, Principal, Token) when is_binary(Token) ->
    try
        [B, M] = binary:split(Token, <<".">>),
        true = crypto:hash_equals(mac(Kind, Principal, B), M),
        {ok, json:decode(unb64(B))}
    catch
        _:_ -> {error, invalid_handle}
    end;
decode(_, _, _) ->
    {error, invalid_handle}.

mac(Kind, Principal, B) ->
    Full = crypto:mac(hmac, sha256, mailio_mcp_store:secret(), [
        atom_to_binary(Kind), 0, Principal, 0, B
    ]),
    b64(binary:part(Full, 0, 12)).

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).
unb64(Bin) -> base64:decode(Bin, #{mode => urlsafe, padding => false}).
