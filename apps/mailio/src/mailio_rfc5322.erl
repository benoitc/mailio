%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc RFC 5322 / 2045 header parsing (pure, total).
%%%
%%% Splits a message into headers and body, unfolds header field bodies,
%%% and parses the structured headers Mailio needs: addresses, dates,
%%% Message-ID and reference lists, and MIME content headers (with RFC 2231
%%% parameter handling). Unstructured values (Subject, display names) are
%%% RFC 2047 decoded via {@link mailio_mime_decode}.
%%%
%%% Every function is total: malformed input yields a best-effort result,
%%% never an exception.
-module(mailio_rfc5322).

-export([split/1, headers/1, header/2, header/3, all_headers/2]).
-export([decode_unstructured/1]).
-export([parse_addresses/1, parse_date/1]).
-export([parse_message_id/1, parse_message_ids/1]).
-export([parse_content_type/1, parse_content_disposition/1, parse_params/1]).

-export_type([header_list/0, address/0]).

%% {lowercased name, unfolded raw value}
-type header_list() :: [{binary(), binary()}].
-type address() :: #{name := binary() | undefined, email := binary()}.

%%====================================================================
%% Header / body split
%%====================================================================

%% @doc Split raw message bytes into `{Headers, Body}'. Headers are
%% returned as an ordered list of `{LowercaseName, UnfoldedValue}'; the
%% body is the bytes after the first empty line (separator removed).
-spec split(binary()) -> {header_list(), binary()}.
split(Raw) when is_binary(Raw) ->
    {HeaderBlock, Body} = split_block(Raw),
    {parse_header_block(HeaderBlock), Body}.

%% @doc Parse just the header list from raw bytes (body discarded).
-spec headers(binary()) -> header_list().
headers(Raw) ->
    {H, _} = split(Raw),
    H.

%% Find the end of the header block: the first blank line.
split_block(Raw) ->
    case first_blank_line(Raw, 0) of
        {Pos, SepLen} ->
            {
                binary:part(Raw, 0, Pos),
                binary:part(Raw, Pos + SepLen, byte_size(Raw) - Pos - SepLen)
            };
        none ->
            {Raw, <<>>}
    end.

%% Locate the byte offset of the blank-line separator and its length.
first_blank_line(Raw, Off) when Off =< byte_size(Raw) ->
    case Raw of
        <<_:Off/binary, "\r\n\r\n", _/binary>> -> {Off, 4};
        <<_:Off/binary, "\n\n", _/binary>> -> {Off, 2};
        <<_:Off/binary, "\r\r", _/binary>> -> {Off, 2};
        _ when Off < byte_size(Raw) -> first_blank_line(Raw, Off + 1);
        _ -> none
    end;
first_blank_line(_Raw, _Off) ->
    none.

%% Split a header block into unfolded fields.
parse_header_block(<<>>) ->
    [];
parse_header_block(Block) ->
    Lines = split_lines(Block),
    Fields = unfold(Lines, undefined, []),
    [parse_field(F) || F <- Fields, F =/= <<>>].

%% Split on LF, dropping a trailing CR (handles CRLF and bare LF).
split_lines(Block) ->
    Parts = binary:split(Block, <<"\n">>, [global]),
    [strip_cr(P) || P <- Parts].

strip_cr(B) ->
    S = byte_size(B),
    case S > 0 andalso binary:at(B, S - 1) =:= $\r of
        true -> binary:part(B, 0, S - 1);
        false -> B
    end.

%% Continuation lines (starting with SP/HT) belong to the previous field.
unfold([], undefined, Acc) ->
    lists:reverse(Acc);
unfold([], Cur, Acc) ->
    lists:reverse([Cur | Acc]);
unfold([<<C, _/binary>> = Line | Rest], Cur, Acc) when
    (C =:= $\s orelse C =:= $\t) andalso Cur =/= undefined
->
    unfold(Rest, <<Cur/binary, Line/binary>>, Acc);
unfold([Line | Rest], undefined, Acc) ->
    unfold(Rest, Line, Acc);
unfold([Line | Rest], Cur, Acc) ->
    unfold(Rest, Line, [Cur | Acc]).

parse_field(Field) ->
    case binary:split(Field, <<":">>) of
        [Name, Value] ->
            {mailio_ascii:lower(mailio_ascii:trim(Name)), mailio_ascii:trim_leading(Value)};
        [_NoColon] ->
            %% Malformed field without a colon: keep under empty name so it
            %% is not silently dropped, but it won't match real lookups.
            {<<>>, Field}
    end.

%%====================================================================
%% Header lookup
%%====================================================================

-spec header(binary(), header_list()) -> binary() | undefined.
header(Name, Headers) ->
    header(Name, Headers, undefined).

-spec header(binary(), header_list(), Default) -> binary() | Default.
header(Name, Headers, Default) ->
    LName = mailio_ascii:lower(Name),
    case lists:keyfind(LName, 1, Headers) of
        {_, Value} -> Value;
        false -> Default
    end.

-spec all_headers(binary(), header_list()) -> [binary()].
all_headers(Name, Headers) ->
    LName = mailio_ascii:lower(Name),
    [V || {N, V} <- Headers, N =:= LName].

%%====================================================================
%% Unstructured values
%%====================================================================

%% @doc Decode an unstructured header value (RFC 2047 + collapse folding WSP).
-spec decode_unstructured(binary() | undefined) -> binary() | undefined.
decode_unstructured(undefined) -> undefined;
decode_unstructured(Value) -> mailio_mime_decode:decode_words(Value).

%%====================================================================
%% Address parsing
%%====================================================================

%% @doc Parse an address-list header (From/To/Cc/...). Group syntax is
%% flattened to its member addresses.
-spec parse_addresses(binary() | undefined) -> [address()].
parse_addresses(undefined) ->
    [];
parse_addresses(Value) ->
    Specs = split_address_list(Value),
    lists:filtermap(
        fun(S) ->
            case parse_address(S) of
                skip -> false;
                Addr -> {true, Addr}
            end
        end,
        Specs
    ).

%% Split on top-level commas, group ':' and ';' markers, ignoring those
%% inside quoted strings, comments (parens) and angle brackets.
split_address_list(Bin) ->
    split_addr(Bin, <<>>, [], 0, false, 0).

%% State: Acc current spec, Out specs, Paren depth, InQuote, Angle depth.
split_addr(<<>>, Acc, Out, _P, _Q, _A) ->
    lists:reverse(add_spec(Acc, Out));
split_addr(<<$\\, C, Rest/binary>>, Acc, Out, P, Q, A) ->
    split_addr(Rest, <<Acc/binary, $\\, C>>, Out, P, Q, A);
split_addr(<<$", Rest/binary>>, Acc, Out, P, Q, A) ->
    split_addr(Rest, <<Acc/binary, $">>, Out, P, not Q, A);
split_addr(<<C, Rest/binary>>, Acc, Out, P, true, A) ->
    split_addr(Rest, <<Acc/binary, C>>, Out, P, true, A);
split_addr(<<$(, Rest/binary>>, Acc, Out, P, Q, A) ->
    split_addr(Rest, <<Acc/binary, $(>>, Out, P + 1, Q, A);
split_addr(<<$), Rest/binary>>, Acc, Out, P, Q, A) when P > 0 ->
    split_addr(Rest, <<Acc/binary, $)>>, Out, P - 1, Q, A);
split_addr(<<C, Rest/binary>>, Acc, Out, P, Q, A) when P > 0 ->
    split_addr(Rest, <<Acc/binary, C>>, Out, P, Q, A);
split_addr(<<$<, Rest/binary>>, Acc, Out, P, Q, A) ->
    split_addr(Rest, <<Acc/binary, $<>>, Out, P, Q, A + 1);
split_addr(<<$>, Rest/binary>>, Acc, Out, P, Q, A) when A > 0 ->
    split_addr(Rest, <<Acc/binary, $>>>, Out, P, Q, A - 1);
split_addr(<<$,, Rest/binary>>, Acc, Out, P, Q, 0) ->
    split_addr(Rest, <<>>, add_spec(Acc, Out), P, Q, 0);
split_addr(<<$;, Rest/binary>>, Acc, Out, P, Q, 0) ->
    %% End of a group: flush current member.
    split_addr(Rest, <<>>, add_spec(Acc, Out), P, Q, 0);
split_addr(<<$:, Rest/binary>>, _Acc, Out, P, Q, 0) ->
    %% Group label start: discard the label (current Acc).
    split_addr(Rest, <<>>, Out, P, Q, 0);
split_addr(<<C, Rest/binary>>, Acc, Out, P, Q, A) ->
    split_addr(Rest, <<Acc/binary, C>>, Out, P, Q, A).

add_spec(Acc, Out) ->
    case mailio_ascii:trim(Acc) of
        <<>> -> Out;
        Spec -> [Spec | Out]
    end.

%% Parse a single address spec into #{name, email}.
parse_address(Spec) ->
    Stripped = strip_comments(Spec),
    case extract_angle(Stripped) of
        {Display, Email} ->
            #{name => display_name(Display), email => mailio_ascii:trim(Email)};
        none ->
            case mailio_ascii:trim(Stripped) of
                <<>> -> skip;
                Addr -> #{name => undefined, email => Addr}
            end
    end.

%% Pull "<addr>" out, returning {DisplayBefore, Addr}.
extract_angle(Bin) ->
    case binary:split(Bin, <<"<">>) of
        [Before, Rest] ->
            case binary:split(Rest, <<">">>) of
                [Addr, _After] -> {Before, Addr};
                [Addr] -> {Before, Addr}
            end;
        [_] ->
            none
    end.

display_name(Bin) ->
    case mailio_ascii:trim(Bin) of
        <<>> ->
            undefined;
        Trimmed ->
            Unquoted = unquote(Trimmed),
            case mailio_mime_decode:decode_words(Unquoted) of
                <<>> -> undefined;
                Name -> Name
            end
    end.

unquote(Bin) ->
    T = mailio_ascii:trim(Bin),
    case T of
        <<$", _/binary>> ->
            case binary:last(T) of
                $" when byte_size(T) >= 2 ->
                    Inner = binary:part(T, 1, byte_size(T) - 2),
                    unescape(Inner);
                _ ->
                    T
            end;
        _ ->
            T
    end.

unescape(Bin) -> unescape(Bin, <<>>).
unescape(<<>>, Acc) -> Acc;
unescape(<<$\\, C, Rest/binary>>, Acc) -> unescape(Rest, <<Acc/binary, C>>);
unescape(<<C, Rest/binary>>, Acc) -> unescape(Rest, <<Acc/binary, C>>).

%% Remove RFC 5322 comments (parenthesised, nestable), outside quotes.
strip_comments(Bin) -> strip_comments(Bin, <<>>, 0, false).
strip_comments(<<>>, Acc, _Depth, _Q) ->
    Acc;
strip_comments(<<$\\, C, Rest/binary>>, Acc, 0, Q) ->
    strip_comments(Rest, <<Acc/binary, $\\, C>>, 0, Q);
strip_comments(<<$", Rest/binary>>, Acc, 0, Q) ->
    strip_comments(Rest, <<Acc/binary, $">>, 0, not Q);
strip_comments(<<C, Rest/binary>>, Acc, 0, true) ->
    strip_comments(Rest, <<Acc/binary, C>>, 0, true);
strip_comments(<<$(, Rest/binary>>, Acc, Depth, false) ->
    strip_comments(Rest, Acc, Depth + 1, false);
strip_comments(<<$), Rest/binary>>, Acc, Depth, false) when Depth > 0 ->
    strip_comments(Rest, Acc, Depth - 1, false);
strip_comments(<<_C, Rest/binary>>, Acc, Depth, false) when Depth > 0 ->
    strip_comments(Rest, Acc, Depth, false);
strip_comments(<<C, Rest/binary>>, Acc, 0, false) ->
    strip_comments(Rest, <<Acc/binary, C>>, 0, false).

%%====================================================================
%% Message-ID / References
%%====================================================================

%% @doc First msg-id token (e.g. of a Message-ID header), without angles.
-spec parse_message_id(binary() | undefined) -> binary() | undefined.
parse_message_id(undefined) ->
    undefined;
parse_message_id(Value) ->
    case parse_message_ids(Value) of
        [Id | _] -> Id;
        [] -> undefined
    end.

%% @doc All msg-id tokens (References / In-Reply-To), angles stripped.
-spec parse_message_ids(binary() | undefined) -> [binary()].
parse_message_ids(undefined) -> [];
parse_message_ids(Value) -> collect_ids(strip_comments(Value), []).

collect_ids(Bin, Acc) ->
    case binary:split(Bin, <<"<">>) of
        [_Before, Rest] ->
            case binary:split(Rest, <<">">>) of
                [Id, Tail] ->
                    case mailio_ascii:trim(Id) of
                        <<>> -> collect_ids(Tail, Acc);
                        Clean -> collect_ids(Tail, [Clean | Acc])
                    end;
                [_Unterminated] ->
                    lists:reverse(Acc)
            end;
        [_NoAngle] ->
            %% Fall back: bare addr-spec tokens separated by whitespace.
            case Acc of
                [] ->
                    [
                        T
                     || T <- binary:split(mailio_ascii:trim(Bin), <<" ">>, [global]),
                        T =/= <<>>
                    ];
                _ ->
                    lists:reverse(Acc)
            end
    end.

%%====================================================================
%% Content-Type / Content-Disposition / parameters
%%====================================================================

%% @doc Parse Content-Type into `{Type, SubType, Params}', lowercased
%% type/subtype. Defaults to text/plain when absent or unparseable.
-spec parse_content_type(binary() | undefined) -> {binary(), binary(), map()}.
parse_content_type(undefined) ->
    {<<"text">>, <<"plain">>, #{}};
parse_content_type(Value) ->
    {Main, Params} = split_value_params(Value),
    case binary:split(mailio_ascii:lower(mailio_ascii:trim(Main)), <<"/">>) of
        [Type, Sub] when Type =/= <<>>, Sub =/= <<>> -> {Type, Sub, Params};
        [Type] when Type =/= <<>> -> {Type, <<"">>, Params};
        _ -> {<<"text">>, <<"plain">>, Params}
    end.

%% @doc Parse Content-Disposition into `{Disposition, Params}'.
-spec parse_content_disposition(binary() | undefined) ->
    {binary() | undefined, map()}.
parse_content_disposition(undefined) ->
    {undefined, #{}};
parse_content_disposition(Value) ->
    {Main, Params} = split_value_params(Value),
    {mailio_ascii:lower(mailio_ascii:trim(Main)), Params}.

%% @doc Parse a bare parameter list (no leading value).
-spec parse_params(binary()) -> map().
parse_params(Bin) ->
    {_, Params} = split_value_params(<<";", Bin/binary>>),
    Params.

%% Split "value; p1=v1; p2*=..." into {Value, ParamsMap}, applying RFC 2231
%% continuation reassembly and charset decoding.
split_value_params(Value) ->
    %% there is always a first segment, even for an empty value
    [Main | ParamSegs] = split_semicolons(Value),
    Raw = lists:foldl(fun parse_one_param/2, [], ParamSegs),
    {Main, reassemble_2231(Raw)}.

split_semicolons(Bin) ->
    split_semi(Bin, <<>>, [], false).
split_semi(<<>>, Acc, Out, _Q) ->
    lists:reverse([Acc | Out]);
split_semi(<<$\\, C, Rest/binary>>, Acc, Out, Q) ->
    split_semi(Rest, <<Acc/binary, $\\, C>>, Out, Q);
split_semi(<<$", Rest/binary>>, Acc, Out, Q) ->
    split_semi(Rest, <<Acc/binary, $">>, Out, not Q);
split_semi(<<$;, Rest/binary>>, Acc, Out, false) ->
    split_semi(Rest, <<>>, [Acc | Out], false);
split_semi(<<C, Rest/binary>>, Acc, Out, Q) ->
    split_semi(Rest, <<Acc/binary, C>>, Out, Q).

%% Parse "name=value" (or name*N*=value) into {Key, raw} accumulator.
parse_one_param(Seg, Acc) ->
    case binary:split(mailio_ascii:trim(Seg), <<"=">>) of
        [NameRaw, ValRaw] ->
            Name = mailio_ascii:lower(mailio_ascii:trim(NameRaw)),
            Val = strip_quotes(mailio_ascii:trim(ValRaw)),
            [{Name, Val} | Acc];
        _ ->
            Acc
    end.

strip_quotes(Bin) ->
    case Bin of
        <<$", _/binary>> when byte_size(Bin) >= 2 ->
            case binary:last(Bin) of
                $" -> unescape(binary:part(Bin, 1, byte_size(Bin) - 2));
                _ -> Bin
            end;
        _ ->
            Bin
    end.

%% Reassemble RFC 2231 parameters: name*0, name*1*, and charset'lang'value.
reassemble_2231(RawParams) ->
    %% RawParams is reversed; restore order for continuation indexing.
    Ordered = lists:reverse(RawParams),
    Grouped = group_2231(Ordered, #{}),
    maps:map(fun(_K, Parts) -> finalize_2231(Parts) end, Grouped).

group_2231([], Acc) ->
    Acc;
group_2231([{Name, Val} | Rest], Acc) ->
    {Base, Index, Extended} = split_param_name(Name),
    Entry = maps:get(Base, Acc, []),
    group_2231(Rest, Acc#{Base => [{Index, Extended, Val} | Entry]}).

%% name -> {name, 0, false}; name* -> {name, 0, true};
%% name*3 -> {name, 3, false}; name*3* -> {name, 3, true}
split_param_name(Name) ->
    case binary:split(Name, <<"*">>) of
        [Base] ->
            {Base, 0, false};
        [Base, <<>>] ->
            {Base, 0, true};
        [Base, Rest] ->
            case binary:split(Rest, <<"*">>) of
                [IdxBin, <<>>] -> {Base, to_int(IdxBin, 0), true};
                [IdxBin] -> {Base, to_int(IdxBin, 0), false}
            end
    end.

finalize_2231(Parts) ->
    Sorted = lists:sort(fun({A, _, _}, {B, _, _}) -> A =< B end, Parts),
    AnyExtended = lists:any(fun({_, Ext, _}) -> Ext end, Parts),
    Joined = iolist_to_binary([V || {_, _, V} <- Sorted]),
    case AnyExtended of
        false -> Joined;
        true -> decode_2231_value(Joined)
    end.

%% charset'language'percent-encoded-value
decode_2231_value(Bin) ->
    case binary:split(Bin, <<"'">>, [global]) of
        [Charset, _Lang, ValueRest | _] ->
            Decoded = percent_decode(ValueRest),
            mailio_mime_decode:to_utf8(Decoded, nz(Charset));
        _ ->
            percent_decode(Bin)
    end.

nz(<<>>) -> undefined;
nz(B) -> B.

percent_decode(Bin) -> percent_decode(Bin, <<>>).
percent_decode(<<>>, Acc) ->
    Acc;
percent_decode(<<$%, H1, H2, Rest/binary>>, Acc) ->
    case {hexv(H1), hexv(H2)} of
        {V1, V2} when V1 =/= error, V2 =/= error ->
            percent_decode(Rest, <<Acc/binary, (V1 bsl 4 + V2)>>);
        _ ->
            percent_decode(Rest, <<Acc/binary, $%, H1, H2>>)
    end;
percent_decode(<<C, Rest/binary>>, Acc) ->
    percent_decode(Rest, <<Acc/binary, C>>).

%%====================================================================
%% Date parsing (RFC 5322 s3.3, lenient)
%%====================================================================

%% @doc Parse a Date header to Unix epoch seconds (UTC). Returns `error'
%% if no date can be recovered.
-spec parse_date(binary() | undefined) -> {ok, integer()} | error.
parse_date(undefined) ->
    error;
parse_date(Value) ->
    Clean = strip_comments(Value),
    %% Drop an optional leading "DoW,".
    NoDow =
        case binary:split(Clean, <<",">>) of
            [_Dow, Rest] -> Rest;
            [Only] -> Only
        end,
    Tokens = [
        T
     || T <- binary:split(mailio_ascii:trim(NoDow), [<<" ">>, <<"\t">>], [global]),
        T =/= <<>>
    ],
    parse_date_tokens(Tokens).

parse_date_tokens([DayB, MonB, YearB, TimeB | ZoneRest]) ->
    case {to_int(DayB, error), month(MonB), to_int(YearB, error), parse_time(TimeB)} of
        {Day, Mon, Year0, {H, Mi, S}} when
            is_integer(Day), is_integer(Mon), is_integer(Year0)
        ->
            Year = normalize_year(Year0),
            Zone =
                case ZoneRest of
                    [Z | _] -> zone_offset(Z);
                    [] -> 0
                end,
            to_epoch(Year, Mon, Day, H, Mi, S, Zone);
        _ ->
            error
    end;
parse_date_tokens(_) ->
    error.

parse_time(Bin) ->
    case binary:split(Bin, <<":">>, [global]) of
        [HB, MB, SB] -> {to_int(HB, 0), to_int(MB, 0), to_int(SB, 0)};
        [HB, MB] -> {to_int(HB, 0), to_int(MB, 0), 0};
        _ -> {0, 0, 0}
    end.

to_epoch(Year, Mon, Day, H, Mi, S, ZoneSecs) ->
    try
        Secs = calendar:datetime_to_gregorian_seconds(
            {{Year, Mon, Day}, {H, Mi, S}}
        ),
        Epoch = Secs - 62167219200 - ZoneSecs,
        {ok, Epoch}
    catch
        _:_ -> error
    end.

normalize_year(Y) when Y >= 1000 -> Y;
normalize_year(Y) when Y >= 50 -> 1900 + Y;
normalize_year(Y) when Y >= 0 -> 2000 + Y.

zone_offset(<<Sign, H1, H2, M1, M2>>) when Sign =:= $+; Sign =:= $- ->
    H = to_int(<<H1, H2>>, 0),
    M = to_int(<<M1, M2>>, 0),
    Off = (H * 3600) + (M * 60),
    case Sign of
        $- -> -Off;
        _ -> Off
    end;
zone_offset(Name) ->
    case mailio_ascii:upper(Name) of
        <<"UT">> -> 0;
        <<"GMT">> -> 0;
        <<"UTC">> -> 0;
        <<"Z">> -> 0;
        <<"EST">> -> -5 * 3600;
        <<"EDT">> -> -4 * 3600;
        <<"CST">> -> -6 * 3600;
        <<"CDT">> -> -5 * 3600;
        <<"MST">> -> -7 * 3600;
        <<"MDT">> -> -6 * 3600;
        <<"PST">> -> -8 * 3600;
        <<"PDT">> -> -7 * 3600;
        _ -> 0
    end.

month(Bin) ->
    case mailio_ascii:lower(Bin) of
        <<"jan", _/binary>> -> 1;
        <<"feb", _/binary>> -> 2;
        <<"mar", _/binary>> -> 3;
        <<"apr", _/binary>> -> 4;
        <<"may", _/binary>> -> 5;
        <<"jun", _/binary>> -> 6;
        <<"jul", _/binary>> -> 7;
        <<"aug", _/binary>> -> 8;
        <<"sep", _/binary>> -> 9;
        <<"oct", _/binary>> -> 10;
        <<"nov", _/binary>> -> 11;
        <<"dec", _/binary>> -> 12;
        _ -> error
    end.

%%====================================================================
%% Numeric helpers
%%====================================================================

to_int(Bin, Default) ->
    mailio_ascii:to_integer(Bin, Default).

hexv(C) when C >= $0, C =< $9 -> C - $0;
hexv(C) when C >= $A, C =< $F -> C - $A + 10;
hexv(C) when C >= $a, C =< $f -> C - $a + 10;
hexv(_) -> error.
