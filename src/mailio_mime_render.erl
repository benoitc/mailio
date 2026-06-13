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
-spec render(map()) -> binary().
render(Part0) ->
    %% Fix the boundary once so the header and body delimiters agree.
    Part = ensure_boundary(Part0),
    HeaderLines = content_headers(Part) ++ extra_headers(Part),
    Block = [ [N, <<": ">>, V, <<"\r\n">>] || {N, V} <- HeaderLines ],
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
    Rendered = [ [<<"--">>, Boundary, <<"\r\n">>, render(C), <<"\r\n">>]
                 || C <- Children ],
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
    Params = case maps:is_key(parts, Part) of
                 true -> Params0#{<<"boundary">> => boundary_of(Part)};
                 false -> maybe_charset(Params0, Part)
             end,
    Ct = {<<"Content-Type">>,
          iolist_to_binary([Type, <<"/">>, Sub, render_params(Params)])},
    CteLines = case maps:is_key(parts, Part) of
                   true -> [];
                   false -> [{<<"Content-Transfer-Encoding">>,
                              maps:get(encoding, Part, <<"7bit">>)}]
               end,
    DispLines = disposition_header(Part),
    [Ct | CteLines] ++ DispLines.

maybe_charset(Params, #{charset := C}) when is_binary(C) ->
    Params#{<<"charset">> => C};
maybe_charset(Params, _) ->
    Params.

disposition_header(#{disposition := D} = Part) when is_binary(D) ->
    Params = case maps:get(filename, Part, undefined) of
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
    lists:member(L, [<<"content-type">>, <<"content-transfer-encoding">>,
                     <<"content-disposition">>]).

render_params(Params) ->
    maps:fold(fun(K, V, Acc) ->
                  [Acc, <<"; ">>, K, <<"=">>, quote_param(V)]
              end, [], Params).

quote_param(V) ->
    case needs_quoting(V) of
        true -> [<<"\"">>, escape_quotes(V), <<"\"">>];
        false -> V
    end.

needs_quoting(V) ->
    case binary:match(V, [<<" ">>, <<"\t">>, <<";">>, <<"\"">>, <<"/">>,
                          <<"(">>, <<")">>, <<"<">>, <<">">>, <<"@">>,
                          <<",">>, <<":">>, <<"=">>]) of
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

%% Minimal quoted-printable encoder (escapes non-printable and '=').
encode_qp(Body) -> encode_qp(Body, <<>>).
encode_qp(<<>>, Acc) -> Acc;
encode_qp(<<$\r, $\n, Rest/binary>>, Acc) ->
    encode_qp(Rest, <<Acc/binary, "\r\n">>);
encode_qp(<<C, Rest/binary>>, Acc) ->
    case qp_printable(C) of
        true -> encode_qp(Rest, <<Acc/binary, C>>);
        false -> encode_qp(Rest, <<Acc/binary, $=, (hex_hi(C)), (hex_lo(C))>>)
    end.

qp_printable($=) -> false;
qp_printable(C) -> C >= 33 andalso C =< 126.

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
    Base = [{<<"From">>, format_addresses(maps:get(from, Spec, []))},
            {<<"To">>, format_addresses(maps:get(to, Spec, []))}],
    Cc = case maps:get(cc, Spec, []) of
             [] -> [];
             L -> [{<<"Cc">>, format_addresses(L)}]
         end,
    Subj = case maps:get(subject, Spec, undefined) of
               undefined -> [];
               S -> [{<<"Subject">>, encode_unstructured(S)}]
           end,
    MsgId = case maps:get(message_id, Spec, undefined) of
                undefined -> [];
                M -> [{<<"Message-ID">>, <<"<", M/binary, ">">>}]
            end,
    Mime = [{<<"MIME-Version">>, <<"1.0">>}],
    Extra = maps:get(headers, Spec, []),
    Base ++ Cc ++ Subj ++ MsgId ++ Mime ++ Extra.

build_content(Spec, Headers) ->
    Text = maps:get(text, Spec, <<>>),
    case maps:get(html, Spec, undefined) of
        undefined ->
            #{type => <<"text">>, subtype => <<"plain">>,
              charset => <<"utf-8">>, encoding => encoding_for(Text),
              headers => Headers, body => Text};
        Html ->
            #{type => <<"multipart">>, subtype => <<"alternative">>,
              headers => Headers,
              parts => [#{type => <<"text">>, subtype => <<"plain">>,
                          charset => <<"utf-8">>, encoding => encoding_for(Text),
                          body => Text},
                        #{type => <<"text">>, subtype => <<"html">>,
                          charset => <<"utf-8">>, encoding => encoding_for(Html),
                          body => Html}]}
    end.

encoding_for(Bin) ->
    case is_ascii(Bin) of
        true -> <<"7bit">>;
        false -> <<"base64">>
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
        true -> Value;
        false -> <<"=?UTF-8?B?", (base64:encode(Value))/binary, "?=">>
    end.

-spec format_address(mailio_rfc5322:address()) -> binary().
format_address(#{email := Email} = Addr) ->
    case maps:get(name, Addr, undefined) of
        undefined -> Email;
        Name ->
            EncName = encode_display_name(Name),
            <<EncName/binary, " <", Email/binary, ">">>
    end.

-spec format_addresses([mailio_rfc5322:address()]) -> binary().
format_addresses(Addrs) ->
    Formatted = [format_address(A) || A <- Addrs],
    iolist_to_binary(lists:join(<<", ">>, Formatted)).

encode_display_name(Name) ->
    case is_ascii(Name) of
        true ->
            case needs_quoting(Name) of
                true -> <<"\"", (escape_quotes(Name))/binary, "\"">>;
                false -> Name
            end;
        false ->
            <<"=?UTF-8?B?", (base64:encode(Name))/binary, "?=">>
    end.

%% Title-case a lowercased header name for nicer output (best effort).
header_case(Name) ->
    Parts = binary:split(Name, <<"-">>, [global]),
    Cased = [capitalize(P) || P <- Parts],
    iolist_to_binary(lists:join(<<"-">>, Cased)).

capitalize(<<>>) -> <<>>;
capitalize(<<C, Rest/binary>>) ->
    <<(string:uppercase(<<C>>))/binary, Rest/binary>>.
