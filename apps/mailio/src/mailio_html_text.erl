%%% @doc HTML to plain text extraction (pure, total).
%%%
%%% Used to derive indexable text and previews from text/html parts. This
%%% is not a renderer: it strips tags, drops script/style content, inserts
%%% line breaks for block-level elements, decodes character references, and
%%% collapses whitespace. Good enough for search and preview, deliberately
%%% not a layout engine.
-module(mailio_html_text).

-export([to_text/1, preview/2]).

%% @doc Convert an HTML (UTF-8) binary to collapsed plain text. Input that
%% is not valid UTF-8 is reinterpreted as latin1 so the function is total.
-spec to_text(binary()) -> binary().
to_text(Html) when is_binary(Html) ->
    Raw = strip(sanitize(Html), normal, <<>>),
    collapse(Raw).

%% Ensure valid UTF-8 so the downstream `string' calls cannot raise.
sanitize(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Out when is_binary(Out) -> Out;
        _ -> unicode:characters_to_binary(Bin, latin1, utf8)
    end.

%% @doc First N characters of the extracted text, for Email.preview.
-spec preview(binary(), pos_integer()) -> binary().
preview(Html, Max) ->
    Text = to_text(Html),
    case string:length(Text) =< Max of
        true ->
            Text;
        false ->
            unicode:characters_to_binary(
                string:slice(Text, 0, Max)
            )
    end.

%%====================================================================
%% Tag stripping
%%====================================================================

%% Mode is `normal' or `{skip, EndTag}' while inside script/style.
strip(<<>>, _Mode, Acc) ->
    Acc;
strip(<<$<, Rest/binary>>, normal, Acc) ->
    {TagName, Rest1} = read_tag(Rest),
    case classify_tag(TagName) of
        {skip_until, End} -> strip(Rest1, {skip, End}, Acc);
        block -> strip(Rest1, normal, <<Acc/binary, $\n>>);
        inline -> strip(Rest1, normal, Acc)
    end;
strip(<<$&, Rest/binary>>, normal, Acc) ->
    {Decoded, Rest1} = read_entity(Rest),
    strip(Rest1, normal, <<Acc/binary, Decoded/binary>>);
strip(<<C, Rest/binary>>, normal, Acc) ->
    strip(Rest, normal, <<Acc/binary, C>>);
%% Skipping inside script/style: look for the matching close tag.
strip(<<$<, Rest/binary>> = Bin, {skip, End}, Acc) ->
    case is_close_tag(Rest, End) of
        {true, Rest1} ->
            strip(Rest1, normal, Acc);
        false ->
            <<_, R/binary>> = Bin,
            strip(R, {skip, End}, Acc)
    end;
strip(<<_C, Rest/binary>>, {skip, _} = Mode, Acc) ->
    strip(Rest, Mode, Acc).

%% Read up to the closing '>' returning the lowercased tag name (sans
%% attributes, sans leading '/').
read_tag(Bin) ->
    {Inner, Rest} = take_until_gt(Bin, <<>>),
    {tag_name(Inner), Rest}.

take_until_gt(<<>>, Acc) -> {Acc, <<>>};
take_until_gt(<<$>, Rest/binary>>, Acc) -> {Acc, Rest};
take_until_gt(<<C, Rest/binary>>, Acc) -> take_until_gt(Rest, <<Acc/binary, C>>).

tag_name(Inner) ->
    Trimmed = string:trim(Inner, leading),
    NoSlash =
        case Trimmed of
            <<$/, R/binary>> -> R;
            _ -> Trimmed
        end,
    Name = take_name(NoSlash, <<>>),
    string:lowercase(Name).

take_name(<<>>, Acc) ->
    Acc;
take_name(<<C, Rest/binary>>, Acc) when
    C =/= $\s, C =/= $\t, C =/= $\r, C =/= $\n, C =/= $/, C =/= $>
->
    take_name(Rest, <<Acc/binary, C>>);
take_name(_, Acc) ->
    Acc.

classify_tag(<<"script">>) ->
    {skip_until, <<"script">>};
classify_tag(<<"style">>) ->
    {skip_until, <<"style">>};
classify_tag(<<"head">>) ->
    {skip_until, <<"head">>};
classify_tag(Name) ->
    case lists:member(Name, block_tags()) of
        true -> block;
        false -> inline
    end.

block_tags() ->
    [
        <<"p">>,
        <<"br">>,
        <<"div">>,
        <<"li">>,
        <<"tr">>,
        <<"table">>,
        <<"h1">>,
        <<"h2">>,
        <<"h3">>,
        <<"h4">>,
        <<"h5">>,
        <<"h6">>,
        <<"ul">>,
        <<"ol">>,
        <<"blockquote">>,
        <<"pre">>,
        <<"hr">>,
        <<"section">>,
        <<"article">>,
        <<"header">>,
        <<"footer">>,
        <<"td">>
    ].

%% Check whether Bin begins with "/End>" (the close tag for a skip region).
is_close_tag(Bin, End) ->
    case Bin of
        <<$/, _/binary>> ->
            {Inner, Rest} = take_until_gt(Bin, <<>>),
            case string:lowercase(tag_name(Inner)) of
                End -> {true, Rest};
                _ -> false
            end;
        _ ->
            false
    end.

%%====================================================================
%% Character references
%%====================================================================

read_entity(Bin) ->
    case take_entity(Bin, <<>>) of
        {ok, Name, Rest} ->
            case decode_entity(Name) of
                {ok, Text} -> {Text, Rest};
                error -> {<<$&, Name/binary, $;>>, Rest}
            end;
        error ->
            {<<$&>>, Bin}
    end.

%% Read up to ';' (bounded, so a stray '&' doesn't swallow the document).
take_entity(<<$;, Rest/binary>>, Acc) when Acc =/= <<>> -> {ok, Acc, Rest};
take_entity(<<C, Rest/binary>>, Acc) when
    byte_size(Acc) < 32 andalso
        ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
            (C >= $0 andalso C =< $9) orelse C =:= $#)
->
    take_entity(Rest, <<Acc/binary, C>>);
take_entity(_, _) ->
    error.

decode_entity(<<$#, $x, Hex/binary>>) -> codepoint(Hex, 16);
decode_entity(<<$#, $X, Hex/binary>>) -> codepoint(Hex, 16);
decode_entity(<<$#, Dec/binary>>) -> codepoint(Dec, 10);
decode_entity(Name) -> named_entity(Name).

codepoint(Bin, Base) ->
    Str = binary_to_list(Bin),
    try list_to_integer(Str, Base) of
        CP when
            is_integer(CP) andalso CP > 0 andalso CP =< 16#10FFFF andalso
                (CP < 16#D800 orelse CP > 16#DFFF)
        ->
            {ok, <<CP/utf8>>};
        _ ->
            error
    catch
        _:_ -> error
    end.

named_entity(<<"amp">>) -> {ok, <<"&">>};
named_entity(<<"lt">>) -> {ok, <<"<">>};
named_entity(<<"gt">>) -> {ok, <<">">>};
named_entity(<<"quot">>) -> {ok, <<"\"">>};
named_entity(<<"apos">>) -> {ok, <<"'">>};
named_entity(<<"nbsp">>) -> {ok, <<" ">>};
named_entity(<<"copy">>) -> {ok, <<"©"/utf8>>};
named_entity(<<"reg">>) -> {ok, <<"®"/utf8>>};
named_entity(<<"trade">>) -> {ok, <<"™"/utf8>>};
named_entity(<<"mdash">>) -> {ok, <<"—"/utf8>>};
named_entity(<<"ndash">>) -> {ok, <<"–"/utf8>>};
named_entity(<<"hellip">>) -> {ok, <<"…"/utf8>>};
named_entity(<<"laquo">>) -> {ok, <<"«"/utf8>>};
named_entity(<<"raquo">>) -> {ok, <<"»"/utf8>>};
named_entity(<<"euro">>) -> {ok, <<"€"/utf8>>};
named_entity(<<"pound">>) -> {ok, <<"£"/utf8>>};
named_entity(<<"rsquo">>) -> {ok, <<"’"/utf8>>};
named_entity(<<"lsquo">>) -> {ok, <<"‘"/utf8>>};
named_entity(<<"rdquo">>) -> {ok, <<"”"/utf8>>};
named_entity(<<"ldquo">>) -> {ok, <<"“"/utf8>>};
named_entity(_) -> error.

%%====================================================================
%% Whitespace collapsing
%%====================================================================

%% Collapse runs of whitespace to single spaces, but keep newlines (at
%% most one blank line), and trim.
collapse(Bin) ->
    mailio_ascii:trim(collapse(Bin, <<>>, start)).

collapse(<<>>, Acc, _State) ->
    Acc;
collapse(<<$\n, Rest/binary>>, Acc, State) ->
    case State of
        %% swallow repeated newlines
        nl -> collapse(Rest, Acc, nl);
        _ -> collapse(Rest, <<Acc/binary, $\n>>, nl)
    end;
collapse(<<C, Rest/binary>>, Acc, State) when
    C =:= $\s; C =:= $\t; C =:= $\r
->
    case State of
        space -> collapse(Rest, Acc, space);
        nl -> collapse(Rest, Acc, nl);
        start -> collapse(Rest, Acc, start);
        text -> collapse(Rest, <<Acc/binary, $\s>>, space)
    end;
collapse(<<C, Rest/binary>>, Acc, _State) ->
    collapse(Rest, <<Acc/binary, C>>, text).
