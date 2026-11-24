%%% @doc MIME tree parser (pure, total).
%%%
%%% Parses raw RFC 5322 bytes into a tree of parts. A leaf part carries a
%%% decoded `body'; a multipart or message/rfc822 part carries `parts'.
%%% The parser never throws: structural problems (missing boundary,
%%% truncation, excessive nesting) are recorded in each part's `defects'
%%% list and parsing continues best-effort, matching the "never crash on
%%% real-world mail" policy.
-module(mailio_mime).

-export([parse/1]).
-export([
    type/1,
    subtype/1,
    content_type/1,
    is_multipart/1,
    is_attachment/1,
    filename/1,
    charset/1,
    body/1,
    parts/1,
    defects/1,
    header/2
]).
-export([walk/2, leaves/1]).

-export_type([part/0]).

-type part() :: #{
    type := binary(),
    subtype := binary(),
    params := map(),
    encoding := binary(),
    disposition := binary() | undefined,
    disposition_params := map(),
    charset := binary() | undefined,
    filename := binary() | undefined,
    content_id := binary() | undefined,
    headers := mailio_rfc5322:header_list(),
    defects := [term()],
    body => binary(),
    parts => [part()]
}.

-define(MAX_DEPTH, 50).
%% Parts parsed per message; the rest are dropped with a `too_many_parts'
%% defect. Overridable with the `mailio' app env `max_mime_parts'.
-define(MAX_PARTS, 1000).

%%====================================================================
%% Parsing
%%====================================================================

%% @doc Parse raw message bytes into a part tree.
-spec parse(binary()) -> part().
parse(Raw) when is_binary(Raw) ->
    Budget = counters:new(1, []),
    parse_part(Raw, 0, Budget).

parse_part(Raw, Depth, Budget) ->
    counters:add(Budget, 1, 1),
    {Headers, Body} = mailio_rfc5322:split(Raw),
    {Type, Sub, CtParams} = mailio_rfc5322:parse_content_type(
        mailio_rfc5322:header(<<"content-type">>, Headers)
    ),
    Cte = normalize_cte(mailio_rfc5322:header(<<"content-transfer-encoding">>, Headers)),
    {Disp, DispParams} = mailio_rfc5322:parse_content_disposition(
        mailio_rfc5322:header(<<"content-disposition">>, Headers)
    ),
    Base = #{
        type => Type,
        subtype => Sub,
        params => CtParams,
        encoding => Cte,
        disposition => Disp,
        disposition_params => DispParams,
        charset => maps:get(<<"charset">>, CtParams, undefined),
        filename => extract_filename(CtParams, DispParams),
        content_id => extract_content_id(Headers),
        headers => Headers,
        defects => []
    },
    classify(Base, Type, Sub, CtParams, Body, Depth, Budget).

%% Multipart: split on the boundary, parse each sub-part.
classify(Base, <<"multipart">>, _Sub, CtParams, Body, Depth, Budget) ->
    case maps:get(<<"boundary">>, CtParams, undefined) of
        undefined ->
            %% No boundary: treat the body as a single opaque leaf.
            leaf(add_defect(Base, no_boundary), Body);
        _Boundary when Depth >= ?MAX_DEPTH ->
            leaf(add_defect(Base, max_depth_exceeded), Body);
        Boundary ->
            Remaining = max(0, max_parts() - counters:get(Budget, 1)),
            case split_parts(Body, Boundary, Remaining) of
                {[], _Closed, true} ->
                    leaf(add_defect(Base, too_many_parts), Body);
                {[], _Closed, false} ->
                    leaf(add_defect(Base, empty_multipart), Body);
                {PartBins, Closed, SplitDropped} ->
                    {Children, Dropped} = parse_children(PartBins, Depth + 1, Budget, []),
                    B0 =
                        case SplitDropped orelse Dropped of
                            true -> add_defect(Base, too_many_parts);
                            false -> Base
                        end,
                    B1 =
                        case Closed of
                            true -> B0;
                            false -> add_defect(B0, no_closing_boundary)
                        end,
                    B1#{parts => Children}
            end
    end;
%% message/rfc822 (and partial/external are treated as opaque leaves).
classify(Base, <<"message">>, <<"rfc822">>, _CtParams, Body, Depth, Budget) when
    Depth < ?MAX_DEPTH
->
    case counters:get(Budget, 1) >= max_parts() of
        true ->
            leaf(add_defect(Base, too_many_parts), Body);
        false ->
            Decoded = mailio_mime_decode:decode_transfer(Body, maps:get(encoding, Base)),
            Nested = parse_part(Decoded, Depth + 1, Budget),
            Base#{parts => [Nested]}
    end;
%% Leaf part: decode transfer encoding.
classify(Base, _Type, _Sub, _CtParams, Body, _Depth, _Budget) ->
    Decoded = mailio_mime_decode:decode_transfer(Body, maps:get(encoding, Base)),
    leaf(Base, Decoded).

%% Parse children in order until the part budget is spent.
parse_children([], _Depth, _Budget, Acc) ->
    {lists:reverse(Acc), false};
parse_children([P | Rest], Depth, Budget, Acc) ->
    case counters:get(Budget, 1) >= max_parts() of
        true -> {lists:reverse(Acc), true};
        false -> parse_children(Rest, Depth, Budget, [parse_part(P, Depth, Budget) | Acc])
    end.

leaf(Base, Body) ->
    Base#{body => Body}.

max_parts() ->
    application:get_env(mailio, max_mime_parts, ?MAX_PARTS).

add_defect(#{defects := D} = Part, Defect) ->
    Part#{defects => [Defect | D]}.

%%====================================================================
%% Multipart boundary splitting (RFC 2046 s5.1)
%%====================================================================

%% Returns {[PartBytes], Closed :: boolean()}. The preamble (before the
%% first delimiter) and epilogue (after the close delimiter) are dropped.
split_parts(Body, Boundary, MaxParts) ->
    Delim = <<"\n--", Boundary/binary>>,
    %% Prepend a newline so a delimiter at offset 0 is matched too; the
    %% resulting empty preamble is discarded.
    case binary:split(<<"\n", Body/binary>>, Delim) of
        %% no delimiter found at all
        [_Preamble] -> {[], false, false};
        [_Preamble, Rest] -> collect_segments(Rest, Delim, MaxParts, [])
    end.

%% Split one boundary at a time so a message with millions of delimiters never
%% creates an unbounded intermediate list before the part budget is applied.
collect_segments(<<"--", _/binary>>, _Delim, 0, Acc) ->
    {lists:reverse(Acc), true, false};
collect_segments(<<>>, _Delim, 0, Acc) ->
    {lists:reverse(Acc), false, false};
collect_segments(_Rest, _Delim, 0, Acc) ->
    {lists:reverse(Acc), false, true};
collect_segments(Rest, Delim, Left, Acc) ->
    [Seg | Tail] = binary:split(Rest, Delim),
    case Seg of
        <<"--", _/binary>> ->
            %% Close delimiter: everything after is epilogue.
            {lists:reverse(Acc), true, false};
        _ ->
            Acc1 = [clean_part(Seg) | Acc],
            case Tail of
                [] -> {lists:reverse(Acc1), false, false};
                [Next] -> collect_segments(Next, Delim, Left - 1, Acc1)
            end
    end.

%% A raw segment is `[transport-padding] CRLF <part> CR' (the trailing LF
%% and the preceding CRLF are owned by the delimiters). Strip the leading
%% boundary-line remainder up to the first LF, and one trailing CR.
clean_part(Seg) ->
    Body =
        case binary:split(Seg, <<"\n">>) of
            [_BoundaryTail, Rest] -> Rest;
            [Whole] -> Whole
        end,
    strip_trailing_cr(Body).

strip_trailing_cr(Bin) ->
    S = byte_size(Bin),
    case S > 0 andalso binary:at(Bin, S - 1) =:= $\r of
        true -> binary:part(Bin, 0, S - 1);
        false -> Bin
    end.

%%====================================================================
%% Accessors
%%====================================================================

-spec type(part()) -> binary().
type(#{type := T}) -> T.

-spec subtype(part()) -> binary().
subtype(#{subtype := S}) -> S.

-spec content_type(part()) -> binary().
content_type(#{type := T, subtype := S}) -> <<T/binary, "/", S/binary>>.

-spec is_multipart(part()) -> boolean().
is_multipart(#{type := <<"multipart">>}) -> true;
is_multipart(_) -> false.

-spec is_attachment(part()) -> boolean().
is_attachment(#{disposition := <<"attachment">>}) -> true;
is_attachment(#{filename := F}) when is_binary(F) -> true;
is_attachment(_) -> false.

-spec filename(part()) -> binary() | undefined.
filename(#{filename := F}) -> F.

-spec charset(part()) -> binary() | undefined.
charset(#{charset := C}) -> C.

-spec body(part()) -> binary() | undefined.
body(Part) -> maps:get(body, Part, undefined).

-spec parts(part()) -> [part()].
parts(Part) -> maps:get(parts, Part, []).

-spec defects(part()) -> [term()].
defects(#{defects := D}) -> D.

-spec header(binary(), part()) -> binary() | undefined.
header(Name, #{headers := H}) -> mailio_rfc5322:header(Name, H).

%%====================================================================
%% Tree traversal
%%====================================================================

%% @doc Depth-first fold over every part (including container parts).
-spec walk(fun((part(), Acc) -> Acc), Acc) -> fun((part()) -> Acc) when Acc :: term().
walk(Fun, Acc0) ->
    fun(Part) -> do_walk(Part, Fun, Acc0) end.

do_walk(Part, Fun, Acc) ->
    Acc1 = Fun(Part, Acc),
    lists:foldl(fun(Child, A) -> do_walk(Child, Fun, A) end, Acc1, parts(Part)).

%% @doc All leaf parts (those with a decoded body), in document order.
-spec leaves(part()) -> [part()].
leaves(Part) ->
    lists:reverse((walk(fun collect_leaf/2, []))(Part)).

collect_leaf(Part, Acc) ->
    case maps:is_key(body, Part) of
        true -> [Part | Acc];
        false -> Acc
    end.

%%====================================================================
%% Helpers
%%====================================================================

normalize_cte(undefined) -> <<"7bit">>;
normalize_cte(Bin) -> mailio_ascii:lower(mailio_ascii:trim(Bin)).

extract_filename(CtParams, DispParams) ->
    case maps:get(<<"filename">>, DispParams, undefined) of
        undefined -> decode_param(maps:get(<<"name">>, CtParams, undefined));
        F -> decode_param(F)
    end.

%% A param value may still contain RFC 2047 words (non-standard but common).
decode_param(undefined) -> undefined;
decode_param(Bin) -> mailio_mime_decode:decode_words(Bin).

extract_content_id(Headers) ->
    case mailio_rfc5322:header(<<"content-id">>, Headers) of
        undefined ->
            undefined;
        Value ->
            case mailio_rfc5322:parse_message_id(Value) of
                undefined -> undefined;
                Id -> Id
            end
    end.
