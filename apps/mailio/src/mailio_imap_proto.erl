%%% @doc Pure IMAP4rev1 protocol codec (no I/O).
%%%
%%% Two halves, both side-effect free and exhaustively unit-testable:
%%%
%%%  - command encoders: build the client command bytes for a tag;
%%%  - response decoding: `read_response/1' frames one complete logical
%%%    response out of a byte buffer (correctly consuming `{n}' literals
%%%    that span physical lines), and `parse_response/1' turns those bytes
%%%    into a structured term.
%%%
%%% The connection FSM owns all sockets and timing; this module only knows
%%% bytes <-> terms.
-module(mailio_imap_proto).

%% Command encoders
-export([
    capability/1,
    login/3,
    starttls/1,
    logout/1,
    enable/2,
    select_qresync/4,
    select/2,
    examine/2,
    list/3,
    status/3,
    uid_fetch/3,
    uid_store/4,
    uid_search/2,
    uid_copy/3,
    uid_move/3,
    append/4,
    expunge/1,
    uid_expunge/2,
    idle/1,
    idle_done/0,
    noop/1,
    authenticate_plain/3,
    authenticate_xoauth2/1,
    xoauth2_response/2
]).

%% Response decoding
-export([read_response/1, read_response/2, parse_response/1]).

-define(MAX_LITERAL, 67108864).
-define(MAX_LINE, 65536).
-define(MAX_RESPONSE, 100663296).

%% Helpers exposed for the FSM/adapter
-export([quote/1, format_seqset/1, parse_uid_set/1]).

-export_type([response/0, token/0]).

-type token() ::
    {atom, binary()}
    | {number, integer()}
    | {string, binary()}
    | {list, [token()]}
    | nil.

-type response() ::
    {continuation, binary()}
    | {tagged, Tag :: binary(), Status :: atom(), #{code => term(), text => binary()}}
    | {untagged, term()}.

%%====================================================================
%% Command encoders
%%====================================================================

-spec capability(binary()) -> iodata().
capability(Tag) -> [Tag, " CAPABILITY\r\n"].

-spec login(binary(), binary(), binary()) -> iodata().
login(Tag, User, Pass) ->
    [Tag, " LOGIN ", quote(User), " ", quote(Pass), "\r\n"].

-spec authenticate_plain(binary(), binary(), binary()) -> iodata().
authenticate_plain(Tag, User, Pass) ->
    Token = base64:encode(<<0, User/binary, 0, Pass/binary>>),
    [Tag, " AUTHENTICATE PLAIN ", Token, "\r\n"].

%% SASL XOAUTH2 without an initial response, so it works on servers that do
%% not offer SASL-IR: send the command, then answer the server's `+' with
%% `xoauth2_response/2'.
-spec authenticate_xoauth2(binary()) -> iodata().
authenticate_xoauth2(Tag) ->
    [Tag, " AUTHENTICATE XOAUTH2\r\n"].

-spec xoauth2_response(binary(), binary()) -> iodata().
xoauth2_response(User, Token) ->
    [base64:encode(<<"user=", User/binary, 1, "auth=Bearer ", Token/binary, 1, 1>>), "\r\n"].

-spec starttls(binary()) -> iodata().
starttls(Tag) -> [Tag, " STARTTLS\r\n"].

-spec logout(binary()) -> iodata().
logout(Tag) -> [Tag, " LOGOUT\r\n"].

-spec noop(binary()) -> iodata().
noop(Tag) -> [Tag, " NOOP\r\n"].

-spec enable(binary(), [binary()]) -> iodata().
enable(Tag, Caps) -> [Tag, " ENABLE ", lists:join(" ", Caps), "\r\n"].

-spec select(binary(), binary()) -> iodata().
select(Tag, Mailbox) -> [Tag, " SELECT ", quote(Mailbox), "\r\n"].

%% SELECT with the QRESYNC parameter (RFC 7162): the server replies with
%% VANISHED (EARLIER) for expunged UIDs and FETCH for flag changes since
%% the given mod-sequence.
-spec select_qresync(binary(), binary(), non_neg_integer(), non_neg_integer()) -> iodata().
select_qresync(Tag, Mailbox, UidValidity, ModSeq) ->
    [
        Tag,
        " SELECT ",
        quote(Mailbox),
        " (QRESYNC (",
        integer_to_binary(UidValidity),
        " ",
        integer_to_binary(ModSeq),
        "))\r\n"
    ].

-spec examine(binary(), binary()) -> iodata().
examine(Tag, Mailbox) -> [Tag, " EXAMINE ", quote(Mailbox), "\r\n"].

-spec list(binary(), binary(), binary()) -> iodata().
list(Tag, Ref, Pattern) ->
    [Tag, " LIST ", quote(Ref), " ", quote(Pattern), "\r\n"].

-spec status(binary(), binary(), [binary()]) -> iodata().
status(Tag, Mailbox, Items) ->
    [Tag, " STATUS ", quote(Mailbox), " (", lists:join(" ", Items), ")\r\n"].

%% UID FETCH <set> (<items>)
-spec uid_fetch(binary(), term(), [binary()]) -> iodata().
uid_fetch(Tag, SeqSet, Items) ->
    [Tag, " UID FETCH ", format_seqset(SeqSet), " (", lists:join(" ", Items), ")\r\n"].

%% UID STORE <set> (+|-)FLAGS(.SILENT) (<flags>)
-spec uid_store(binary(), term(), {add | remove | set, boolean()}, [binary()]) -> iodata().
uid_store(Tag, SeqSet, {Action, Silent}, Flags) ->
    Op =
        case Action of
            add -> "+FLAGS";
            remove -> "-FLAGS";
            set -> "FLAGS"
        end,
    Suffix =
        case Silent of
            true -> ".SILENT";
            false -> ""
        end,
    [
        Tag,
        " UID STORE ",
        format_seqset(SeqSet),
        " ",
        Op,
        Suffix,
        " (",
        lists:join(" ", Flags),
        ")\r\n"
    ].

-spec uid_search(binary(), iodata()) -> iodata().
uid_search(Tag, Criteria) ->
    [Tag, " UID SEARCH ", Criteria, "\r\n"].

-spec uid_copy(binary(), term(), binary()) -> iodata().
uid_copy(Tag, SeqSet, Dest) ->
    [Tag, " UID COPY ", format_seqset(SeqSet), " ", quote(Dest), "\r\n"].

-spec uid_move(binary(), term(), binary()) -> iodata().
uid_move(Tag, SeqSet, Dest) ->
    [Tag, " UID MOVE ", format_seqset(SeqSet), " ", quote(Dest), "\r\n"].

%% APPEND uses a synchronizing literal for the message bytes; the caller
%% sends the returned prefix, waits for the `+' continuation, then the data.
-spec append(binary(), binary(), [binary()], binary()) -> {iodata(), binary()}.
append(Tag, Mailbox, Flags, Raw) ->
    FlagPart =
        case Flags of
            [] -> "";
            _ -> [" (", lists:join(" ", Flags), ")"]
        end,
    Prefix = [
        Tag,
        " APPEND ",
        quote(Mailbox),
        FlagPart,
        " {",
        integer_to_binary(byte_size(Raw)),
        "}\r\n"
    ],
    {Prefix, <<Raw/binary, "\r\n">>}.

-spec expunge(binary()) -> iodata().
expunge(Tag) -> [Tag, " EXPUNGE\r\n"].

-spec uid_expunge(binary(), term()) -> iodata().
uid_expunge(Tag, SeqSet) ->
    [Tag, " UID EXPUNGE ", format_seqset(SeqSet), "\r\n"].

-spec idle(binary()) -> iodata().
idle(Tag) -> [Tag, " IDLE\r\n"].

-spec idle_done() -> iodata().
idle_done() -> "DONE\r\n".

%%====================================================================
%% Response framing (literal-aware)
%%====================================================================

%% @doc Frame one complete logical response from the buffer. Returns the
%% response bytes (including embedded literal data, excluding the final
%% CRLF) and the remaining buffer, or `more' if incomplete. Uses the default
%% limits, see {@link read_response/2}.
-spec read_response(binary()) -> {ok, binary(), binary()} | more | {error, response_too_large}.
read_response(Buffer) ->
    read_response(Buffer, #{}).

%% @doc Like {@link read_response/1} with explicit limits: `max_literal'
%% (one literal), `max_line' (one line outside literals) and `max_response'
%% (a whole logical response). A peer that announces or sends more gets
%% `{error, response_too_large}' before the data is buffered.
-spec read_response(binary(), map()) ->
    {ok, binary(), binary()} | more | {error, response_too_large}.
read_response(Buffer, Opts) ->
    Limits = #{
        literal => maps:get(max_literal, Opts, ?MAX_LITERAL),
        line => maps:get(max_line, Opts, ?MAX_LINE),
        response => maps:get(max_response, Opts, ?MAX_RESPONSE)
    },
    case logical_length(Buffer, 0, Limits) of
        more ->
            more;
        {error, _} = Err ->
            Err;
        {ok, TotalLen, CrlfLen} ->
            Line = binary:part(Buffer, 0, TotalLen - CrlfLen),
            Rest = binary:part(Buffer, TotalLen, byte_size(Buffer) - TotalLen),
            {ok, Line, Rest}
    end.

%% Walk physical lines, jumping over literal payloads, until a CRLF that is
%% not preceded by a literal spec. Returns the total length up to and
%% including that terminating CRLF.
logical_length(Buffer, Pos, Limits) ->
    case find_crlf(Buffer, Pos) of
        nomatch ->
            case byte_size(Buffer) - Pos > maps:get(line, Limits) of
                true -> {error, response_too_large};
                false -> more
            end;
        CrlfPos when CrlfPos - Pos > map_get(line, Limits) ->
            {error, response_too_large};
        CrlfPos ->
            case literal_before(Buffer, Pos, CrlfPos) of
                {literal, N} ->
                    DataStart = CrlfPos + 2,
                    DataEnd = DataStart + N,
                    if
                        N > map_get(literal, Limits) -> {error, response_too_large};
                        DataEnd > map_get(response, Limits) -> {error, response_too_large};
                        byte_size(Buffer) >= DataEnd -> logical_length(Buffer, DataEnd, Limits);
                        true -> more
                    end;
                none ->
                    case CrlfPos + 2 > map_get(response, Limits) of
                        true -> {error, response_too_large};
                        false -> {ok, CrlfPos + 2, 2}
                    end
            end
    end.

find_crlf(Buffer, Pos) when Pos + 1 < byte_size(Buffer) ->
    case Buffer of
        <<_:Pos/binary, "\r\n", _/binary>> -> Pos;
        _ -> find_crlf(Buffer, Pos + 1)
    end;
find_crlf(_Buffer, _Pos) ->
    nomatch.

%% Is the segment ending at CrlfPos terminated by a `{n}' or `{n+}' literal
%% spec? Scan backwards: `}' , optional `+', digits, `{'.
literal_before(Buffer, From, CrlfPos) when CrlfPos > From ->
    case binary:at(Buffer, CrlfPos - 1) of
        $} -> scan_literal_digits(Buffer, From, CrlfPos - 2, false, []);
        _ -> none
    end;
literal_before(_Buffer, _From, _CrlfPos) ->
    none.

scan_literal_digits(Buffer, From, Pos, SeenPlus, Digits) when Pos >= From ->
    case binary:at(Buffer, Pos) of
        $+ when not SeenPlus, Digits =:= [] ->
            scan_literal_digits(Buffer, From, Pos - 1, true, Digits);
        D when D >= $0, D =< $9 ->
            scan_literal_digits(Buffer, From, Pos - 1, SeenPlus, [D | Digits]);
        ${ when Digits =/= [] ->
            {literal, binary_to_integer(list_to_binary(Digits))};
        _ ->
            none
    end;
scan_literal_digits(_Buffer, _From, _Pos, _SeenPlus, _Digits) ->
    none.

%%====================================================================
%% Response parsing
%%====================================================================

%% @doc Parse framed response bytes into a structured term.
-spec parse_response(binary()) -> response().
parse_response(<<"+ ", Rest/binary>>) ->
    {continuation, Rest};
parse_response(<<"+", Rest/binary>>) ->
    {continuation, Rest};
parse_response(<<"* ", Rest/binary>>) ->
    {untagged, parse_untagged(Rest)};
parse_response(Bin) ->
    %% Tagged: "<tag> <STATUS> <text>"
    case split_word(Bin) of
        {Tag, Rest} ->
            {StatusWord, Rest2} = split_word(Rest),
            Status = status_atom(StatusWord),
            {Code, Text} = parse_resp_text(Rest2),
            {tagged, Tag, Status, #{code => Code, text => Text}};
        none ->
            {untagged, {other, Bin}}
    end.

parse_untagged(Bin) ->
    {First, Rest} = split_word(Bin),
    case is_all_digits(First) of
        true ->
            N = binary_to_integer(First),
            {Kind, Rest2} = split_word(Rest),
            numeric_response(string:uppercase(Kind), N, Rest2);
        false ->
            keyword_response(string:uppercase(First), Rest)
    end.

numeric_response(<<"EXISTS">>, N, _) ->
    {exists, N};
numeric_response(<<"RECENT">>, N, _) ->
    {recent, N};
numeric_response(<<"EXPUNGE">>, N, _) ->
    {expunge, N};
numeric_response(<<"FETCH">>, N, Rest) ->
    Tokens = tokenize(Rest),
    {fetch, N, fetch_items(Tokens)};
numeric_response(Other, N, _) ->
    {other_numeric, Other, N}.

keyword_response(<<"CAPABILITY">>, Rest) ->
    {capability, [T || {atom, T} <- tokenize(Rest)]};
keyword_response(<<"FLAGS">>, Rest) ->
    {flags, flag_list(unwrap_list(tokenize(Rest)))};
keyword_response(<<"LIST">>, Rest) ->
    parse_list(Rest);
keyword_response(<<"LSUB">>, Rest) ->
    parse_list(Rest);
keyword_response(<<"STATUS">>, Rest) ->
    parse_status(Rest);
keyword_response(<<"SEARCH">>, Rest) ->
    {search, [N || {number, N} <- tokenize(Rest)]};
keyword_response(<<"VANISHED">>, Rest) ->
    parse_vanished(Rest);
keyword_response(Status, Rest) when
    Status =:= <<"OK">>;
    Status =:= <<"NO">>;
    Status =:= <<"BAD">>;
    Status =:= <<"BYE">>;
    Status =:= <<"PREAUTH">>
->
    {Code, Text} = parse_resp_text(Rest),
    {status_resp, status_atom(Status), Code, Text};
keyword_response(Other, Rest) ->
    {other, Other, Rest}.

%% LIST (\Attrs) "delim" name
parse_list(Bin) ->
    case tokenize(Bin) of
        [{list, AttrToks} | RestToks] ->
            Attrs = [A || {atom, A} <- AttrToks],
            {Delim, NameToks} = take_delim(RestToks),
            Name = first_string(NameToks),
            {list, Attrs, Delim, Name};
        _ ->
            {other, <<"LIST">>, Bin}
    end.

take_delim([nil | Rest]) -> {nil, Rest};
take_delim([{string, D} | Rest]) -> {D, Rest};
take_delim([{atom, D} | Rest]) -> {D, Rest};
take_delim(Rest) -> {nil, Rest}.

first_string([{string, S} | _]) -> S;
first_string([{atom, S} | _]) -> S;
first_string(_) -> <<>>.

parse_status(Bin) ->
    case tokenize(Bin) of
        [MbxTok | Rest] ->
            Mailbox = token_to_bin(MbxTok),
            Items = find_list(Rest),
            {status, Mailbox, kv_pairs(Items)};
        [] ->
            {status, <<>>, []}
    end.

find_list([{list, L} | _]) -> L;
find_list([_ | Rest]) -> find_list(Rest);
find_list([]) -> [].

parse_vanished(Bin) ->
    case tokenize(Bin) of
        [{list, [{atom, <<"EARLIER">>}]} | Rest] ->
            {vanished, true, uid_set_from_tokens(Rest)};
        Toks ->
            {vanished, false, uid_set_from_tokens(Toks)}
    end.

uid_set_from_tokens([{atom, Set} | _]) -> parse_uid_set(Set);
uid_set_from_tokens([{number, N} | _]) -> [N];
uid_set_from_tokens(_) -> [].

%%====================================================================
%% resp-text and codes:  "[CODE args] human text"
%%====================================================================

parse_resp_text(Bin) ->
    Trimmed = mailio_ascii:trim_leading(Bin),
    case Trimmed of
        <<"[", Rest/binary>> ->
            case split_bracket(Rest, <<>>) of
                {CodeBin, TextRaw} ->
                    {parse_code(CodeBin), mailio_ascii:trim_leading(TextRaw)};
                none ->
                    {undefined, Trimmed}
            end;
        _ ->
            {undefined, Trimmed}
    end.

split_bracket(<<"]", Rest/binary>>, Acc) -> {Acc, Rest};
split_bracket(<<C, Rest/binary>>, Acc) -> split_bracket(Rest, <<Acc/binary, C>>);
split_bracket(<<>>, _Acc) -> none.

parse_code(CodeBin) ->
    {Name, Args} = split_word(CodeBin),
    case tokenize(Args) of
        [] -> {string:uppercase(Name)};
        Toks -> {string:uppercase(Name), Toks}
    end.

%%====================================================================
%% FETCH item interpretation
%%====================================================================

%% The tokens for a FETCH are a single parenthesized list of key/value
%% pairs. Pull it out and interpret known items.
fetch_items([{list, Items} | _]) -> kv_pairs(Items);
fetch_items(Toks) -> kv_pairs(Toks).

kv_pairs(Tokens) -> kv_pairs(Tokens, []).
kv_pairs([], Acc) ->
    lists:reverse(Acc);
%% A section with a field list, `BODY[HEADER.FIELDS (FROM TO)]' (optionally
%% followed by `<origin>'), tokenizes as an atom, a list and an atom that
%% starts with `]'. Rebuild it as one key so the data lands under it.
kv_pairs([{atom, Key} | Rest], Acc) ->
    case Rest of
        [{list, Fields}, {atom, <<"]", Suffix/binary>>} | Rest1] ->
            case open_section(Key) of
                true ->
                    Names = lists:join(<<" ">>, [token_to_bin(F) || F <- Fields]),
                    Full = string:uppercase(
                        iolist_to_binary([Key, <<" (">>, Names, <<")]">>, Suffix])
                    ),
                    {Value, Rest2} = take_value(Full, Rest1),
                    kv_pairs(Rest2, [{Full, Value} | Acc]);
                false ->
                    plain_pair(Key, Rest, Acc)
            end;
        _ ->
            plain_pair(Key, Rest, Acc)
    end;
kv_pairs([_ | Rest], Acc) ->
    kv_pairs(Rest, Acc).

plain_pair(Key, Rest, Acc) ->
    {Value, Rest2} = take_value(string:uppercase(Key), Rest),
    kv_pairs(Rest2, [{normalize_key(Key), Value} | Acc]).

%% `BODY[HEADER.FIELDS' has an opening bracket and no closing one.
open_section(Key) ->
    binary:match(Key, <<"[">>) =/= nomatch andalso binary:match(Key, <<"]">>) =:= nomatch.

take_value(<<"FLAGS">>, [{list, L} | Rest]) -> {flag_list(L), Rest};
take_value(<<"UID">>, [{number, N} | Rest]) -> {N, Rest};
take_value(<<"RFC822.SIZE">>, [{number, N} | Rest]) -> {N, Rest};
take_value(<<"INTERNALDATE">>, [{string, S} | Rest]) -> {S, Rest};
take_value(<<"MODSEQ">>, [{list, [{number, N} | _]} | Rest]) -> {N, Rest};
take_value(_Key, [{string, S} | Rest]) -> {S, Rest};
take_value(_Key, [{number, N} | Rest]) -> {N, Rest};
take_value(_Key, [{list, L} | Rest]) -> {L, Rest};
take_value(_Key, [nil | Rest]) -> {nil, Rest};
take_value(_Key, []) -> {nil, []};
take_value(_Key, Rest) -> {nil, Rest}.

%% Keep BODY[]/RFC822 keys recognizable, lowercase the common scalar ones.
normalize_key(Key) ->
    case string:uppercase(Key) of
        <<"UID">> -> uid;
        <<"FLAGS">> -> flags;
        <<"RFC822.SIZE">> -> size;
        <<"INTERNALDATE">> -> internaldate;
        <<"MODSEQ">> -> modseq;
        <<"BODY[]">> -> body;
        <<"BODY">> -> body;
        <<"RFC822">> -> body;
        Other -> Other
    end.

flag_list(Tokens) ->
    [token_to_bin(T) || T <- Tokens, T =/= nil].

%% A parenthesized value tokenizes to a single `{list, L}'; unwrap it.
unwrap_list([{list, L}]) -> L;
unwrap_list(Tokens) -> Tokens.

%%====================================================================
%% Generic IMAP data tokenizer
%%====================================================================

%% @doc Tokenize an IMAP data string into a flat token list (parens nest).
tokenize(Bin) ->
    {Tokens, _Rest} = tokens(mailio_ascii:trim_leading(Bin), []),
    Tokens.

tokens(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
tokens(<<")", Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
tokens(<<" ", Rest/binary>>, Acc) ->
    tokens(Rest, Acc);
tokens(<<"\t", Rest/binary>>, Acc) ->
    tokens(Rest, Acc);
tokens(<<"(", Rest/binary>>, Acc) ->
    {Inner, Rest2} = tokens(Rest, []),
    tokens(Rest2, [{list, Inner} | Acc]);
tokens(<<"\"", Rest/binary>>, Acc) ->
    {Str, Rest2} = quoted(Rest, <<>>),
    tokens(Rest2, [{string, Str} | Acc]);
tokens(<<"{", Rest/binary>>, Acc) ->
    case literal(Rest) of
        {ok, Data, Rest2} -> tokens(Rest2, [{string, Data} | Acc]);
        error -> {lists:reverse(Acc), <<>>}
    end;
tokens(Bin, Acc) ->
    {Atom, Rest} = atom_token(Bin, <<>>),
    tokens(Rest, [classify_atom(Atom) | Acc]).

quoted(<<"\\", C, Rest/binary>>, Acc) -> quoted(Rest, <<Acc/binary, C>>);
quoted(<<"\"", Rest/binary>>, Acc) -> {Acc, Rest};
quoted(<<C, Rest/binary>>, Acc) -> quoted(Rest, <<Acc/binary, C>>);
quoted(<<>>, Acc) -> {Acc, <<>>}.

literal(Bin) ->
    case take_digits(Bin, <<>>) of
        {Digits, <<"}\r\n", Rest/binary>>} when Digits =/= <<>> ->
            N = binary_to_integer(Digits),
            case Rest of
                <<Data:N/binary, Rest2/binary>> -> {ok, Data, Rest2};
                _ -> error
            end;
        _ ->
            error
    end.

take_digits(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    take_digits(Rest, <<Acc/binary, D>>);
take_digits(Bin, Acc) ->
    {Acc, Bin}.

%% Atom: run until a delimiter. Brackets are kept (so BODY[] is one atom).
atom_token(<<C, Rest/binary>>, Acc) when
    C =/= $\s, C =/= $\t, C =/= $(, C =/= $), C =/= ${, C =/= $"
->
    atom_token(Rest, <<Acc/binary, C>>);
atom_token(Bin, Acc) ->
    {Acc, Bin}.

classify_atom(<<"NIL">>) ->
    nil;
classify_atom(Bin) ->
    case is_all_digits(Bin) of
        true -> {number, binary_to_integer(Bin)};
        false -> {atom, Bin}
    end.

%%====================================================================
%% Sequence sets
%%====================================================================

%% @doc Format a sequence/uid set for a command.
-spec format_seqset(term()) -> iodata().
format_seqset(N) when is_integer(N) -> integer_to_binary(N);
format_seqset({range, A, B}) ->
    [integer_to_binary(A), ":", to_set_bound(B)];
format_seqset(L) when is_list(L) ->
    lists:join(",", [format_seqset(E) || E <- L]);
format_seqset(Bin) when is_binary(Bin) -> Bin.

to_set_bound('*') -> "*";
to_set_bound(N) when is_integer(N) -> integer_to_binary(N).

%% @doc Parse a uid-set ("1,3:5,9") into an expanded sorted list.
-spec parse_uid_set(binary()) -> [integer()].
parse_uid_set(Bin) ->
    Parts = binary:split(Bin, <<",">>, [global]),
    lists:usort(lists:flatmap(fun parse_uid_range/1, Parts)).

parse_uid_range(Part) ->
    case binary:split(Part, <<":">>) of
        [A, B] -> lists:seq(binary_to_integer(A), binary_to_integer(B));
        [<<>>] -> [];
        [Single] -> [binary_to_integer(Single)]
    end.

%%====================================================================
%% Small helpers
%%====================================================================

%% @doc Quote a string for an IMAP command (always quoted form).
-spec quote(binary()) -> iodata().
quote(Bin) ->
    Escaped = binary:replace(
        binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
        <<"\"">>,
        <<"\\\"">>,
        [global]
    ),
    [$", Escaped, $"].

split_word(Bin) ->
    Trimmed = mailio_ascii:trim_leading(Bin),
    case Trimmed of
        <<>> ->
            none;
        _ ->
            case binary:split(Trimmed, <<" ">>) of
                [Word, Rest] -> {Word, Rest};
                [Word] -> {Word, <<>>}
            end
    end.

status_atom(Word) ->
    case string:uppercase(Word) of
        <<"OK">> -> ok;
        <<"NO">> -> no;
        <<"BAD">> -> bad;
        <<"BYE">> -> bye;
        <<"PREAUTH">> -> preauth;
        Other -> Other
    end.

token_to_bin({string, S}) -> S;
token_to_bin({atom, A}) -> A;
token_to_bin({number, N}) -> integer_to_binary(N);
token_to_bin(nil) -> <<>>;
token_to_bin(_) -> <<>>.

is_all_digits(<<>>) -> false;
is_all_digits(Bin) -> is_all_digits_1(Bin).
is_all_digits_1(<<>>) -> true;
is_all_digits_1(<<D, Rest/binary>>) when D >= $0, D =< $9 -> is_all_digits_1(Rest);
is_all_digits_1(_) -> false.
