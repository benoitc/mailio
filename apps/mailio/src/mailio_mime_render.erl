%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc MIME / RFC 5322 rendering (pure, total).
%%%
%%% Serializes a structured part into RFC 5322 bytes. Used for outbound
%%% submission (building messages from drafts) and as the inverse side of
%%% the parser for round-trip property tests. Produces CRLF line endings.
-module(mailio_mime_render).

-export([render/1, build/1]).
-export([encode_unstructured/1, format_address/1, format_addresses/1]).

%%====================================================================
%% Rendering a structured part
%%====================================================================

%% @doc Render a part map to bytes. The part may be a leaf (`body' key) or
%% a container (`parts' key). Recognized fields: type, subtype, params,
%% encoding, charset, headers (extra non-content headers), disposition,
%% filename.
-define(WORD_BYTES, 36).

-spec render(map()) -> binary().
render(Part0) ->
    %% Fix the boundary once so the header and body delimiters agree.
    Part = ensure_boundary(Part0),
    HeaderLines = content_headers(Part) ++ extra_headers(Part),
    Block = [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- HeaderLines],
    Body = render_body(Part),
    iolist_to_binary([Block, <<"\r\n">>, Body]).

ensure_boundary(#{parts := _} = Part) ->
    Params = maps:get(params, Part, #{}),
    case maps:is_key(<<"boundary">>, Params) of
        true -> Part;
        false -> Part#{params => Params#{<<"boundary">> => default_boundary()}}
    end;
ensure_boundary(Part) ->
    Part.

render_body(#{parts := Children} = Part) ->
    Boundary = boundary_of(Part),
    Rendered = [
        [<<"--">>, Boundary, <<"\r\n">>, render(C), <<"\r\n">>]
     || C <- Children
    ],
    iolist_to_binary([Rendered, <<"--">>, Boundary, <<"--\r\n">>]);
render_body(#{body := Body} = Part) ->
    encode_body(Body, maps:get(encoding, Part, <<"7bit">>));
render_body(_) ->
    <<>>.

%% Build the Content-Type / CTE / Content-Disposition header lines.
content_headers(Part) ->
    Type = maps:get(type, Part, <<"text">>),
    Sub = maps:get(subtype, Part, <<"plain">>),
    Params0 = maps:get(params, Part, #{}),
    Params =
        case maps:is_key(parts, Part) of
            true -> Params0#{<<"boundary">> => boundary_of(Part)};
            false -> maybe_charset(Params0, Part)
        end,
    Ct = {<<"Content-Type">>, iolist_to_binary([Type, <<"/">>, Sub, render_params(Params)])},
    CteLines =
        case maps:is_key(parts, Part) of
            true -> [];
            false -> [{<<"Content-Transfer-Encoding">>, maps:get(encoding, Part, <<"7bit">>)}]
        end,
    DispLines = disposition_header(Part),
    [Ct | CteLines] ++ DispLines.

maybe_charset(Params, #{charset := C}) when is_binary(C) ->
    Params#{<<"charset">> => C};
maybe_charset(Params, _) ->
    Params.

disposition_header(#{disposition := D} = Part) when is_binary(D) ->
    Params =
        case maps:get(filename, Part, undefined) of
            undefined -> #{};
            F -> #{<<"filename">> => F}
        end,
    [{<<"Content-Disposition">>, iolist_to_binary([D, render_params(Params)])}];
disposition_header(_) ->
    [].

%% Pass through caller-supplied headers, excluding the content-* headers we
%% regenerate, so a parsed part can be re-rendered without duplication.
extra_headers(Part) ->
    Headers = maps:get(headers, Part, []),
    [{header_case(N), V} || {N, V} <- Headers, not is_content_header(N)].

is_content_header(N) ->
    L = string:lowercase(N),
    lists:member(L, [
        <<"content-type">>,
        <<"content-transfer-encoding">>,
        <<"content-disposition">>
    ]).

render_params(Params) ->
    maps:fold(
        fun(K, V, Acc) ->
            [Acc, <<"; ">>, K, <<"=">>, quote_param(V)]
        end,
        [],
        Params
    ).

quote_param(V) ->
    case needs_quoting(V) of
        true -> [<<"\"">>, escape_quotes(V), <<"\"">>];
        false -> V
    end.

needs_quoting(V) ->
    case
        binary:match(V, [
            <<" ">>,
            <<"\t">>,
            <<";">>,
            <<"\"">>,
            <<"/">>,
            <<"(">>,
            <<")">>,
            <<"<">>,
            <<">">>,
            <<"@">>,
            <<",">>,
            <<":">>,
            <<"=">>
        ])
    of
        nomatch -> V =:= <<>>;
        _ -> true
    end.

escape_quotes(V) ->
    binary:replace(V, <<"\"">>, <<"\\\"">>, [global]).

boundary_of(Part) ->
    case maps:get(params, Part, #{}) of
        #{<<"boundary">> := B} -> B;
        _ -> maps:get(boundary, Part, default_boundary())
    end.

default_boundary() ->
    <<"=_mailio_", (mailio_id:ulid())/binary>>.

%%====================================================================
%% Body transfer encoding
%%====================================================================

encode_body(Body, Encoding) ->
    case string:lowercase(Encoding) of
        <<"base64">> -> chunk64(base64:encode(Body));
        <<"quoted-printable">> -> encode_qp(Body);
        _ -> Body
    end.

%% Wrap base64 to 76-char lines.
chunk64(B64) -> chunk64(B64, <<>>).
chunk64(B64, Acc) when byte_size(B64) =< 76 ->
    <<Acc/binary, B64/binary>>;
chunk64(B64, Acc) ->
    <<Line:76/binary, Rest/binary>> = B64,
    chunk64(Rest, <<Acc/binary, Line/binary, "\r\n">>).

%% Quoted-printable (RFC 2045, section 6.7): lines of at most 76 characters, with a
%% soft line break (`=' at the end of a line) where a line would be longer, and
%% the space or tab that ends a line written as an escape. Line breaks of the
%% text (CRLF) are kept as they are. Runs of text that needs no escape are copied
%% as slices of the input, so a very long line costs no more than its own size.
encode_qp(Body) ->
    Lines = binary:split(Body, <<"\r\n">>, [global]),
    iolist_to_binary(lists:join(<<"\r\n">>, [qp(L, 0) || L <- Lines])).

qp(<<>>, _Len) ->
    [];
qp(Bin, Len) ->
    Size = byte_size(Bin),
    case qp_run(Bin, Size, 0) of
        0 ->
            %% a run of bytes that are written as escapes, as many as the line has room for
            Unsafe = qp_unsafe_run(Bin, Size, 0),
            case Unsafe =:= Size andalso Len + 3 * Unsafe =< 76 of
                true ->
                    [qp_escapes(Bin)];
                false ->
                    Take = min(Unsafe, (75 - Len) div 3),
                    case Take =< 0 of
                        true ->
                            [<<"=\r\n">> | qp(Bin, 0)];
                        false ->
                            [
                                qp_escapes(binary:part(Bin, 0, Take))
                                | qp(binary:part(Bin, Take, Size - Take), Len + 3 * Take)
                            ]
                    end
            end;
        Run when Run =:= Size, Len + Run =< 76 ->
            [Bin];
        Run ->
            Take = min(Run, 75 - Len),
            case Take =< 0 of
                true ->
                    [<<"=\r\n">> | qp(Bin, 0)];
                false ->
                    [
                        binary:part(Bin, 0, Take)
                        | qp(binary:part(Bin, Take, Size - Take), Len + Take)
                    ]
            end
    end.

%% how many bytes from here are written as they are: printable ASCII except `=',
%% and a space or tab that does not end the line
qp_run(Bin, Size, I) when I < Size ->
    C = binary:at(Bin, I),
    case qp_literal(C, I =:= Size - 1) of
        true -> qp_run(Bin, Size, I + 1);
        false -> I
    end;
qp_run(_Bin, _Size, I) ->
    I.

qp_literal(C, _AtEnd) when C =:= $=; C < 32; C > 126 -> false;
qp_literal(C, true) when C =:= $\s; C =:= $\t -> false;
qp_literal(_, _) -> true.

qp_escapes(Bin) -> <<<<$=, (hex_hi(C)), (hex_lo(C))>> || <<C>> <= Bin>>.

%% how many bytes from here are written as escapes
qp_unsafe_run(Bin, Size, I) when I < Size ->
    case qp_literal(binary:at(Bin, I), I =:= Size - 1) of
        false -> qp_unsafe_run(Bin, Size, I + 1);
        true -> I
    end;
qp_unsafe_run(_Bin, _Size, I) ->
    I.

hex_hi(C) -> hex_digit(C bsr 4).
hex_lo(C) -> hex_digit(C band 16#0F).
hex_digit(D) when D < 10 -> $0 + D;
hex_digit(D) -> $A + (D - 10).

%%====================================================================
%% Outbound message building
%%====================================================================

%% @doc Build a simple outbound message. Supports a plain-text body, an
%% optional HTML alternative, and arbitrary extra headers. Non-ASCII
%% header values are RFC 2047 encoded.
-spec build(map()) -> binary().
build(Spec) ->
    Headers = build_headers(Spec),
    Part = build_content(Spec, Headers),
    render(Part).

build_headers(Spec) ->
    Base = [
        {<<"From">>, format_addresses(maps:get(from, Spec, []))},
        {<<"To">>, format_addresses(maps:get(to, Spec, []))}
    ],
    Cc =
        case maps:get(cc, Spec, []) of
            [] -> [];
            L -> [{<<"Cc">>, format_addresses(L)}]
        end,
    Subj =
        case maps:get(subject, Spec, undefined) of
            undefined -> [];
            S -> [{<<"Subject">>, encode_unstructured(S)}]
        end,
    MsgId =
        case maps:get(message_id, Spec, undefined) of
            undefined -> [];
            M -> [{<<"Message-ID">>, <<"<", M/binary, ">">>}]
        end,
    Mime = [{<<"MIME-Version">>, <<"1.0">>}],
    Extra = maps:get(headers, Spec, []),
    Base ++ Cc ++ Subj ++ MsgId ++ date_header(Spec, Extra) ++ Mime ++ Extra.

%% A message has a Date (RFC 5322, section 3.6.1): the one the caller gave as the
%% `date' (seconds since the epoch, UTC) or among the headers, else now.
date_header(Spec, Extra) ->
    Given = [N || {N, _} <- Extra, string:lowercase(N) =:= <<"date">>],
    case Given of
        [_ | _] ->
            [];
        [] ->
            Secs = maps:get(date, Spec, erlang:system_time(second)),
            [{<<"Date">>, format_date(Secs)}]
    end.

%% "Wed, 25 Nov 2026 15:04:05 +0000"
-spec format_date(integer()) -> binary().
format_date(Secs) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:gregorian_seconds_to_datetime(
        Secs + calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    ),
    Days = {<<"Mon">>, <<"Tue">>, <<"Wed">>, <<"Thu">>, <<"Fri">>, <<"Sat">>, <<"Sun">>},
    Months = {
        <<"Jan">>,
        <<"Feb">>,
        <<"Mar">>,
        <<"Apr">>,
        <<"May">>,
        <<"Jun">>,
        <<"Jul">>,
        <<"Aug">>,
        <<"Sep">>,
        <<"Oct">>,
        <<"Nov">>,
        <<"Dec">>
    },
    Day = element(calendar:day_of_the_week(Y, Mo, D), Days),
    iolist_to_binary(
        io_lib:format("~s, ~2..0w ~s ~4..0w ~2..0w:~2..0w:~2..0w +0000", [
            Day, D, element(Mo, Months), Y, H, Mi, S
        ])
    ).

build_content(Spec, Headers) ->
    Text = maps:get(text, Spec, <<>>),
    case maps:get(html, Spec, undefined) of
        undefined ->
            #{
                type => <<"text">>,
                subtype => <<"plain">>,
                charset => <<"utf-8">>,
                encoding => encoding_for(Text),
                headers => Headers,
                body => Text
            };
        Html ->
            #{
                type => <<"multipart">>,
                subtype => <<"alternative">>,
                headers => Headers,
                parts => [
                    #{
                        type => <<"text">>,
                        subtype => <<"plain">>,
                        charset => <<"utf-8">>,
                        encoding => encoding_for(Text),
                        body => Text
                    },
                    #{
                        type => <<"text">>,
                        subtype => <<"html">>,
                        charset => <<"utf-8">>,
                        encoding => encoding_for(Html),
                        body => Html
                    }
                ]
            }
    end.

%% 7bit text has lines of at most 998 characters (RFC 5322, section 2.1.1); text
%% with longer ones, or with anything that is not ASCII, is encoded.
encoding_for(Bin) ->
    case is_ascii(Bin) of
        false ->
            <<"base64">>;
        true ->
            case
                lists:any(fun(L) -> byte_size(L) > 998 end, binary:split(Bin, <<"\n">>, [global]))
            of
                true -> <<"quoted-printable">>;
                false -> <<"7bit">>
            end
    end.

is_ascii(Bin) ->
    lists:all(fun(B) -> B < 128 end, binary_to_list(Bin)).

%%====================================================================
%% Header value encoding
%%====================================================================

%% @doc Encode an unstructured header value, RFC 2047 B-encoding it when it
%% contains non-ASCII bytes.
-spec encode_unstructured(binary()) -> binary().
encode_unstructured(Value) ->
    case is_ascii(Value) of
        true -> fold_ascii(Value);
        false -> encoded_words(Value)
    end.

%% Encoded words are at most 75 characters (RFC 2047, section 2): 45 bytes of
%% text make 60 of base64, and the words are folded onto lines of their own. A
%% word never splits a UTF-8 character.
encoded_words(Value0) ->
    Value = scrub_utf8(Value0),
    iolist_to_binary(
        lists:join(<<"\r\n ">>, [encoded_word(Chunk) || Chunk <- utf8_chunks(Value, ?WORD_BYTES)])
    ).

%% Bytes that are not UTF-8 are replaced by U+FFFD, so that what is encoded is
%% text and cutting it between characters is always possible.
scrub_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Good when is_binary(Good) ->
            Good;
        {error, Good, <<_Bad, Rest/binary>>} ->
            <<Good/binary, 16#FFFD/utf8, (scrub_utf8(Rest))/binary>>;
        {incomplete, Good, _Part} ->
            <<Good/binary, 16#FFFD/utf8>>
    end.

encoded_word(Chunk) -> <<"=?UTF-8?B?", (base64:encode(Chunk))/binary, "?=">>.

utf8_chunks(<<>>, _Max) ->
    [];
utf8_chunks(Bin, Max) when byte_size(Bin) =< Max ->
    [Bin];
utf8_chunks(Bin, Max) ->
    Cut = utf8_cut(Bin, Max),
    <<Head:Cut/binary, Rest/binary>> = Bin,
    [Head | utf8_chunks(Rest, Max)].

%% the longest prefix of at most Max bytes that ends on a character boundary
utf8_cut(Bin, Max) ->
    case Bin of
        <<_:Max/binary, Next, _/binary>> when Next band 16#C0 =:= 16#80 ->
            max(1, utf8_back(Bin, Max - 1));
        _ ->
            Max
    end.

utf8_back(Bin, N) ->
    <<_:N/binary, C, _/binary>> = Bin,
    case C band 16#C0 =:= 16#80 of
        true -> utf8_back(Bin, N - 1);
        false -> N
    end.

%% Text with only ASCII is folded at spaces onto lines that stay under the 78 of
%% RFC 5322, section 2.2.3, with the header name in front. A word with no space that is longer than a line
%% allows is sent as encoded words instead.
fold_ascii(Value) when byte_size(Value) =< 68 ->
    Value;
fold_ascii(Value) ->
    Words = binary:split(Value, <<" ">>, [global]),
    %% spaces at the ends or in a row cannot be folded without changing them, and
    %% a word that is longer than a line cannot be folded at all
    case lists:any(fun(W) -> byte_size(W) =:= 0 orelse byte_size(W) > 68 end, Words) of
        true -> encoded_words(Value);
        false -> fold_words(Words, <<>>, [])
    end.

fold_words([], Line, Acc) ->
    iolist_to_binary(lists:join(<<"\r\n ">>, lists:reverse([Line | Acc])));
fold_words([W | Rest], <<>>, Acc) ->
    fold_words(Rest, W, Acc);
fold_words([W | Rest], Line, Acc) ->
    case byte_size(Line) + 1 + byte_size(W) =< 68 of
        true -> fold_words(Rest, <<Line/binary, " ", W/binary>>, Acc);
        false -> fold_words(Rest, W, [Line | Acc])
    end.

-spec format_address(mailio_rfc5322:address()) -> binary().
format_address(#{email := Email} = Addr) ->
    case maps:get(name, Addr, undefined) of
        undefined ->
            Email;
        Name ->
            EncName = encode_display_name(Name),
            %% a name in encoded words leaves the address on a line of its own
            Sep =
                case binary:match(EncName, <<"\r\n">>) of
                    nomatch -> <<" ">>;
                    _ -> <<"\r\n ">>
                end,
            <<EncName/binary, Sep/binary, "<", Email/binary, ">">>
    end.

-spec format_addresses([mailio_rfc5322:address()]) -> binary().
format_addresses(Addrs) ->
    Formatted = [format_address(A) || A <- Addrs],
    iolist_to_binary(lists:join(<<",\r\n ">>, Formatted)).

encode_display_name(Name) ->
    case is_ascii(Name) andalso byte_size(Name) =< 60 of
        true ->
            case needs_quoting(Name) of
                true -> <<"\"", (escape_quotes(Name))/binary, "\"">>;
                false -> Name
            end;
        false ->
            encoded_words(Name)
    end.

%% Title-case a lowercased header name for nicer output (best effort).
header_case(Name) ->
    Parts = binary:split(Name, <<"-">>, [global]),
    Cased = [capitalize(P) || P <- Parts],
    iolist_to_binary(lists:join(<<"-">>, Cased)).

capitalize(<<>>) -> <<>>;
capitalize(<<C, Rest/binary>>) -> <<(string:uppercase(<<C>>))/binary, Rest/binary>>.
