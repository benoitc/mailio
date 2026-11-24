%%% @doc MIME helpers for the MCP tools: header lookup, address lists,
%%% text extraction, quoted-history handling and paging. Decoding of
%%% transfer encodings, charsets and RFC 2047 words is done by the mailio
%%% library. Message content is untrusted data: nothing here interprets it
%%% beyond decoding.
-module(mailio_mcp_mime).

-export([
    parse_headers/1,
    header/2,
    decode_words/1,
    addresses/1,
    format_addr/1,
    decode_body/3,
    to_utf8/2,
    html_to_text/1,
    strip_quoted/1,
    page/3,
    message_ids/1
]).

%% @doc Parse a raw header block into [{LowerName, Value}], values unfolded.
-spec parse_headers(binary()) -> [{binary(), binary()}].
parse_headers(Raw) ->
    {Headers, _Body} = mailio_rfc5322:split(<<Raw/binary, "\r\n\r\n">>),
    Headers.

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

%% @doc Decode RFC 2047 encoded words.
-spec decode_words(binary()) -> binary().
decode_words(Bin) when is_binary(Bin) -> mailio_mime_decode:decode_words(Bin);
decode_words(Other) -> Other.

%% @doc Convert bytes in a charset to UTF-8; unknown charsets are decoded
%% as Latin-1 so no text is lost.
-spec to_utf8(binary() | undefined, binary()) -> binary().
to_utf8(Charset, Bin) -> mailio_mime_decode:to_utf8(Bin, Charset).

%% @doc Parse an address list header into [#{name, address}].
-spec addresses(binary() | undefined) -> [map()].
addresses(Value) ->
    [
        #{name => Name, address => Email}
     || #{name := Name, email := Email} <- mailio_rfc5322:parse_addresses(Value)
    ].

format_addr(#{name := undefined, address := A}) -> A;
format_addr(#{name := <<>>, address := A}) -> A;
format_addr(#{name := N, address := A}) -> <<N/binary, " <", A/binary, ">">>.

%% @doc Decode a part's transfer encoding and charset to UTF-8 text.
-spec decode_body(binary(), binary() | undefined, binary() | undefined) -> binary().
decode_body(Bin, Encoding, Charset) ->
    to_utf8(Charset, mailio_mime_decode:decode_transfer(Bin, Encoding)).

html_to_text(Html) -> mailio_html_text:to_text(Html).

%% @doc Remove quoted history: lines starting with ">" and everything
%% after an "On ... wrote:" attribution line.
-spec strip_quoted(binary()) -> binary().
strip_quoted(Text) ->
    Lines = binary:split(Text, [<<"\r\n">>, <<"\n">>], [global]),
    Kept = take_unquoted(Lines, []),
    string:trim(iolist_to_binary(lists:join(<<"\n">>, Kept)), trailing).

take_unquoted([], Acc) ->
    lists:reverse(Acc);
take_unquoted([L | Rest], Acc) ->
    case
        re:run(
            L,
            <<"^(On .{5,200} wrote:|Le .{5,200} a \\x{e9}crit\\s*:|-{2,}\\s*Original Message\\s*-{2,}|From: .*)\\s*$">>,
            [unicode]
        )
    of
        {match, _} when Acc =/= [] ->
            lists:reverse(Acc);
        _ ->
            case L of
                <<$>, _/binary>> -> take_unquoted(Rest, Acc);
                _ -> take_unquoted(Rest, [L | Acc])
            end
    end.

%% @doc One page of text by byte offset, cut on a character boundary.
-spec page(binary(), non_neg_integer(), pos_integer()) -> {binary(), non_neg_integer() | undefined}.
page(Text, Offset, Size) ->
    Total = byte_size(Text),
    case Offset >= Total of
        true ->
            {<<>>, undefined};
        false ->
            Len = min(Size, Total - Offset),
            Chunk = binary:part(Text, Offset, Len),
            Good = valid_prefix(Chunk, Offset + Len < Total),
            Next = Offset + byte_size(Good),
            {Good,
                case Next >= Total of
                    true -> undefined;
                    false -> Next
                end}
    end.

valid_prefix(Chunk, true) ->
    case unicode:characters_to_binary(Chunk, utf8, utf8) of
        {incomplete, Good, _} -> Good;
        {error, Good, _} -> Good;
        B when is_binary(B) -> B
    end;
valid_prefix(Chunk, false) ->
    Chunk.

%% @doc Message-IDs found in a header value, in order.
message_ids(undefined) ->
    [];
message_ids(V) ->
    case re:run(V, <<"<[^<>\\s]+>">>, [global, {capture, first, binary}]) of
        {match, Ms} -> [M || [M] <- Ms];
        nomatch -> []
    end.
