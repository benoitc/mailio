%%% @doc Low-level MIME decoders (pure, total).
%%%
%%% Transfer decodings (quoted-printable, base64), RFC 2047 encoded-words,
%%% and charset conversion to UTF-8. Every function is total: malformed
%%% input is decoded best-effort rather than raising, matching the parser's
%%% "never throw on bad mail" policy.
-module(mailio_mime_decode).

-export([decode_quoted_printable/1, decode_base64/1]).
-export([decode_transfer/2]).
-export([decode_words/1]).
-export([to_utf8/2, normalize_charset/1]).

%%====================================================================
%% Content-Transfer-Encoding
%%====================================================================

%% @doc Decode a leaf body according to its Content-Transfer-Encoding.
-spec decode_transfer(binary(), binary() | undefined) -> binary().
decode_transfer(Body, Encoding) ->
    case normalize_token(Encoding) of
        <<"base64">> -> decode_base64(Body);
        <<"quoted-printable">> -> decode_quoted_printable(Body);
        <<"7bit">> -> Body;
        <<"8bit">> -> Body;
        <<"binary">> -> Body;
        _ -> Body   %% unknown encoding: pass through
    end.

%%====================================================================
%% Quoted-printable (RFC 2045 s6.7)
%%====================================================================

%% @doc Body-mode quoted-printable decode. Underscores are literal here
%% (only RFC 2047 Q-encoding maps `_' to space).
-spec decode_quoted_printable(binary()) -> binary().
decode_quoted_printable(Bin) ->
    qp(Bin, <<>>).

qp(<<>>, Acc) -> Acc;
%% Soft line break: "=" CRLF or "=" LF is removed.
qp(<<$=, $\r, $\n, Rest/binary>>, Acc) -> qp(Rest, Acc);
qp(<<$=, $\n, Rest/binary>>, Acc) -> qp(Rest, Acc);
%% "=" followed by trailing whitespace then EOL is also a soft break (lenient).
qp(<<$=, H1, H2, Rest/binary>>, Acc) ->
    case {hex(H1), hex(H2)} of
        {V1, V2} when V1 =/= error, V2 =/= error ->
            qp(Rest, <<Acc/binary, (V1 bsl 4 + V2)>>);
        _ ->
            %% Not a valid hex pair: keep the "=" literally (defect-tolerant).
            qp(<<H1, H2, Rest/binary>>, <<Acc/binary, $=>>)
    end;
qp(<<$=>>, Acc) ->
    %% Trailing lone "=": keep it.
    <<Acc/binary, $=>>;
qp(<<C, Rest/binary>>, Acc) ->
    qp(Rest, <<Acc/binary, C>>).

%%====================================================================
%% Base64 (RFC 2045 s6.8) - lenient
%%====================================================================

%% @doc Lenient base64 decode: ignores whitespace/newlines and tolerates
%% missing padding. Never raises.
-spec decode_base64(binary()) -> binary().
decode_base64(Bin) ->
    Clean = << <<C>> || <<C>> <= Bin, is_base64_char(C) >>,
    Padded = pad_base64(Clean),
    try base64:decode(Padded)
    catch _:_ ->
        %% As a last resort, drop trailing partial quantum and retry.
        salvage_base64(Padded)
    end.

is_base64_char(C) ->
    (C >= $A andalso C =< $Z) orelse
    (C >= $a andalso C =< $z) orelse
    (C >= $0 andalso C =< $9) orelse
    C =:= $+ orelse C =:= $/ orelse C =:= $=.

pad_base64(Bin) ->
    %% Strip any existing '=' then re-pad to a multiple of 4.
    Core = << <<C>> || <<C>> <= Bin, C =/= $= >>,
    case byte_size(Core) rem 4 of
        0 -> Core;
        2 -> <<Core/binary, "==">>;
        3 -> <<Core/binary, "=">>;
        1 -> binary:part(Core, 0, byte_size(Core) - 1)  %% drop the orphan char
    end.

salvage_base64(Bin) ->
    case byte_size(Bin) of
        N when N >= 4 ->
            try base64:decode(binary:part(Bin, 0, N - (N rem 4)))
            catch _:_ -> <<>> end;
        _ -> <<>>
    end.

%%====================================================================
%% RFC 2047 encoded-words
%%====================================================================

%% @doc Decode all RFC 2047 encoded-words in a header value to a UTF-8
%% binary, leaving non-encoded runs intact. Adjacent encoded-words
%% separated only by whitespace have that whitespace removed (RFC 2047 s6.2).
-spec decode_words(binary()) -> binary().
decode_words(Bin) ->
    Tokens = scan_words(Bin, <<>>, []),
    assemble(lists:reverse(Tokens), <<>>, false).

%% Tokenize into {encoded, Bin} | {text, Bin} | {ws, Bin}.
scan_words(<<>>, Cur, Acc) ->
    push_text(Cur, Acc);
scan_words(<<"=?", Rest/binary>> = Bin, Cur, Acc) ->
    case take_encoded_word(Rest) of
        {ok, Charset, Enc, Text, Rest2} ->
            Acc1 = push_text(Cur, Acc),
            scan_words(Rest2, <<>>, [{encoded, Charset, Enc, Text} | Acc1]);
        error ->
            <<C, T/binary>> = Bin,
            scan_words(T, <<Cur/binary, C>>, Acc)
    end;
scan_words(<<C, Rest/binary>>, Cur, Acc)
  when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    %% Flush current text, emit a whitespace token.
    Acc1 = push_text(Cur, Acc),
    {Ws, Rest2} = take_ws(<<C, Rest/binary>>, <<>>),
    scan_words(Rest2, <<>>, [{ws, Ws} | Acc1]);
scan_words(<<C, Rest/binary>>, Cur, Acc) ->
    scan_words(Rest, <<Cur/binary, C>>, Acc).

push_text(<<>>, Acc) -> Acc;
push_text(Text, Acc) -> [{text, Text} | Acc].

take_ws(<<C, Rest/binary>>, Acc)
  when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    take_ws(Rest, <<Acc/binary, C>>);
take_ws(Rest, Acc) -> {Acc, Rest}.

%% Parse "charset?enc?text?=" after the leading "=?".
take_encoded_word(Bin) ->
    case binary:split(Bin, <<"?">>) of
        [Charset, R1] when Charset =/= <<>> ->
            case binary:split(R1, <<"?">>) of
                [Enc, R2] when byte_size(Enc) =:= 1 ->
                    case binary:split(R2, <<"?=">>) of
                        [Text, Rest] ->
                            case has_no_ws(Charset) andalso has_no_ws(Text) of
                                true -> {ok, Charset, Enc, Text, Rest};
                                false -> error
                            end;
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

has_no_ws(Bin) ->
    case binary:match(Bin, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>]) of
        nomatch -> true;
        _ -> false
    end.

%% Reassemble tokens; drop whitespace that sits between two encoded-words.
assemble([], Acc, _PrevEnc) -> Acc;
assemble([{ws, Ws} | Rest], Acc, PrevEnc) ->
    case {PrevEnc, next_is_encoded(Rest)} of
        {true, true} -> assemble(Rest, Acc, false);  %% inter-word ws removed
        _ -> assemble(Rest, <<Acc/binary, Ws/binary>>, false)
    end;
assemble([{text, T} | Rest], Acc, _PrevEnc) ->
    assemble(Rest, <<Acc/binary, T/binary>>, false);
assemble([{encoded, Charset, Enc, Text} | Rest], Acc, _PrevEnc) ->
    Decoded = decode_one_word(Charset, Enc, Text),
    assemble(Rest, <<Acc/binary, Decoded/binary>>, true).

next_is_encoded([{encoded, _, _, _} | _]) -> true;
next_is_encoded(_) -> false.

decode_one_word(Charset, Enc, Text) ->
    Bytes = case uppercase(Enc) of
                <<"B">> -> decode_base64(Text);
                <<"Q">> -> decode_q(Text);
                _ -> Text
            end,
    to_utf8(Bytes, Charset).

%% RFC 2047 Q-encoding: like QP but '_' is space and only =XX is special.
decode_q(Bin) -> decode_q(Bin, <<>>).
decode_q(<<>>, Acc) -> Acc;
decode_q(<<$_, Rest/binary>>, Acc) -> decode_q(Rest, <<Acc/binary, $\s>>);
decode_q(<<$=, H1, H2, Rest/binary>>, Acc) ->
    case {hex(H1), hex(H2)} of
        {V1, V2} when V1 =/= error, V2 =/= error ->
            decode_q(Rest, <<Acc/binary, (V1 bsl 4 + V2)>>);
        _ -> decode_q(<<H1, H2, Rest/binary>>, <<Acc/binary, $=>>)
    end;
decode_q(<<C, Rest/binary>>, Acc) -> decode_q(Rest, <<Acc/binary, C>>).

%%====================================================================
%% Charset conversion
%%====================================================================

%% @doc Convert bytes in the named charset to a UTF-8 binary. Unknown or
%% unconvertible charsets fall back to latin1 so text is never lost.
-spec to_utf8(binary(), binary() | undefined) -> binary().
to_utf8(Bin, Charset) ->
    case normalize_charset(Charset) of
        utf8 -> ensure_utf8(Bin);
        latin1 -> conv(Bin, latin1);
        ascii -> conv(Bin, latin1);
        windows1252 -> cp1252_to_utf8(Bin);
        utf16 -> conv(Bin, utf16);
        utf16le -> conv(Bin, {utf16, little});
        utf16be -> conv(Bin, {utf16, big});
        _ -> conv(Bin, latin1)   %% unknown: latin1 is lossless for bytes
    end.

ensure_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Out when is_binary(Out) -> Out;
        _ -> conv(Bin, latin1)   %% invalid utf8: reinterpret as latin1
    end.

conv(Bin, In) ->
    case unicode:characters_to_binary(Bin, In, utf8) of
        Out when is_binary(Out) -> Out;
        _ -> Bin
    end.

%% @doc Map a charset label to a canonical atom understood by {@link to_utf8/2}.
-spec normalize_charset(binary() | undefined) -> atom().
normalize_charset(undefined) -> ascii;
normalize_charset(Bin) when is_binary(Bin) ->
    case mailio_ascii:lower(mailio_ascii:trim(Bin)) of
        <<"utf-8">> -> utf8;
        <<"utf8">> -> utf8;
        <<"us-ascii">> -> ascii;
        <<"ascii">> -> ascii;
        <<"iso-8859-1">> -> latin1;
        <<"iso8859-1">> -> latin1;
        <<"latin1">> -> latin1;
        <<"l1">> -> latin1;
        <<"windows-1252">> -> windows1252;
        <<"cp1252">> -> windows1252;
        <<"utf-16">> -> utf16;
        <<"utf-16le">> -> utf16le;
        <<"utf-16be">> -> utf16be;
        _ -> unknown
    end.

%% windows-1252 differs from latin1 only in 0x80-0x9F. Map those code points,
%% pass everything else through latin1.
cp1252_to_utf8(Bin) ->
    cp1252(Bin, <<>>).

cp1252(<<>>, Acc) -> Acc;
cp1252(<<B, Rest/binary>>, Acc) when B >= 16#80, B =< 16#9F ->
    CP = cp1252_high(B),
    cp1252(Rest, <<Acc/binary, CP/utf8>>);
cp1252(<<B, Rest/binary>>, Acc) ->
    cp1252(Rest, <<Acc/binary, B/utf8>>).

cp1252_high(16#80) -> 16#20AC; cp1252_high(16#82) -> 16#201A;
cp1252_high(16#83) -> 16#0192; cp1252_high(16#84) -> 16#201E;
cp1252_high(16#85) -> 16#2026; cp1252_high(16#86) -> 16#2020;
cp1252_high(16#87) -> 16#2021; cp1252_high(16#88) -> 16#02C6;
cp1252_high(16#89) -> 16#2030; cp1252_high(16#8A) -> 16#0160;
cp1252_high(16#8B) -> 16#2039; cp1252_high(16#8C) -> 16#0152;
cp1252_high(16#8E) -> 16#017D; cp1252_high(16#91) -> 16#2018;
cp1252_high(16#92) -> 16#2019; cp1252_high(16#93) -> 16#201C;
cp1252_high(16#94) -> 16#201D; cp1252_high(16#95) -> 16#2022;
cp1252_high(16#96) -> 16#2013; cp1252_high(16#97) -> 16#2014;
cp1252_high(16#98) -> 16#02DC; cp1252_high(16#99) -> 16#2122;
cp1252_high(16#9A) -> 16#0161; cp1252_high(16#9B) -> 16#203A;
cp1252_high(16#9C) -> 16#0153; cp1252_high(16#9E) -> 16#017E;
cp1252_high(16#9F) -> 16#0178;
%% Undefined in cp1252 (81,8D,8F,90,9D): map to the byte value.
cp1252_high(B) -> B.

%%====================================================================
%% Small helpers
%%====================================================================

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(_) -> error.

normalize_token(undefined) -> <<"7bit">>;
normalize_token(Bin) when is_binary(Bin) ->
    mailio_ascii:lower(mailio_ascii:trim(Bin)).

uppercase(Bin) -> mailio_ascii:upper(Bin).
