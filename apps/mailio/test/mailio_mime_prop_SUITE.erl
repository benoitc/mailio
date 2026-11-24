%%% @doc Randomized property / fuzz suite for the MIME stack (M2).
%%%
%%% Uses a seeded PRNG (no external property-testing dependency) so runs are
%%% deterministic and CI-friendly. Two properties:
%%%
%%%  1. round-trip: render(P) |> parse == structurally-equivalent P, for
%%%     randomly generated part trees;
%%%  2. totality: parse/1 and html_text:to_text/1 never raise, on random
%%%     bytes and on mutations of real messages.
-module(mailio_mime_prop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2]).
-export([
    roundtrip_random_trees/1,
    parse_never_crashes_on_random_bytes/1,
    parse_never_crashes_on_mutations/1,
    decode_inverse_qp/1,
    decode_inverse_base64/1
]).

-define(ITERATIONS, 2000).

all() ->
    [
        roundtrip_random_trees,
        parse_never_crashes_on_random_bytes,
        parse_never_crashes_on_mutations,
        decode_inverse_qp,
        decode_inverse_base64
    ].

init_per_testcase(TC, Config) ->
    %% Deterministic per-case seed.
    rand:seed(exsss, {erlang:phash2(TC), 42, 7}),
    Config.

%%====================================================================
%% Property 1: render/parse round-trip
%%====================================================================
roundtrip_random_trees(_Config) ->
    lists:foreach(
        fun(_) ->
            Spec = gen_part(0),
            Bytes = mailio_mime_render:render(to_render(Spec)),
            Parsed = mailio_mime:parse(Bytes),
            assert_equivalent(Spec, Parsed)
        end,
        lists:seq(1, 300)
    ),
    ok.

%% A spec is {leaf, Type, Sub, Encoding, Body} | {multi, Sub, [Spec]}.
gen_part(Depth) ->
    case Depth < 2 andalso rand:uniform(3) =:= 1 of
        true ->
            N = 1 + rand:uniform(3),
            {multi, <<"mixed">>, [gen_part(Depth + 1) || _ <- lists:seq(1, N)]};
        false ->
            gen_leaf()
    end.

gen_leaf() ->
    Body = gen_body(),
    %% base64 survives arbitrary bytes; 7bit only when ascii & boundary-safe.
    Enc =
        case is_safe_7bit(Body) of
            true ->
                case rand:uniform(2) of
                    1 -> <<"7bit">>;
                    _ -> <<"base64">>
                end;
            false ->
                <<"base64">>
        end,
    {leaf, <<"text">>, <<"plain">>, Enc, Body}.

gen_body() ->
    Len = rand:uniform(64),
    case rand:uniform(2) of
        1 -> list_to_binary([rand:uniform(94) + 32 || _ <- lists:seq(1, Len)]);
        2 -> crypto:strong_rand_bytes(Len)
    end.

%% 7bit-safe: ASCII, no bare CR/LF, no line that could look like a boundary.
is_safe_7bit(Body) ->
    lists:all(fun(B) -> B >= 32 andalso B < 127 end, binary_to_list(Body)).

to_render({leaf, T, S, Enc, Body}) ->
    #{type => T, subtype => S, encoding => Enc, body => Body};
to_render({multi, Sub, Children}) ->
    #{
        type => <<"multipart">>,
        subtype => Sub,
        parts => [to_render(C) || C <- Children]
    }.

assert_equivalent({leaf, _T, _S, _Enc, Body}, Parsed) ->
    ?assertNot(mailio_mime:is_multipart(Parsed)),
    ?assertEqual(Body, mailio_mime:body(Parsed));
assert_equivalent({multi, _Sub, Children}, Parsed) ->
    ?assert(mailio_mime:is_multipart(Parsed)),
    ParsedParts = mailio_mime:parts(Parsed),
    ?assertEqual(length(Children), length(ParsedParts)),
    lists:foreach(
        fun({Spec, P}) -> assert_equivalent(Spec, P) end,
        lists:zip(Children, ParsedParts)
    ).

%%====================================================================
%% Property 2: totality on random bytes
%%====================================================================
parse_never_crashes_on_random_bytes(_Config) ->
    lists:foreach(
        fun(_) ->
            Bytes = crypto:strong_rand_bytes(rand:uniform(2048)),
            P = mailio_mime:parse(Bytes),
            ?assert(is_map(P)),
            ?assert(is_binary(mailio_mime:type(P))),
            %% Walking leaves and extracting text must also be total.
            _ = [
                mailio_html_text:to_text(mailio_mime:body(L))
             || L <- mailio_mime:leaves(P),
                mailio_mime:body(L) =/= undefined
            ]
        end,
        lists:seq(1, ?ITERATIONS)
    ),
    ok.

parse_never_crashes_on_mutations(_Config) ->
    Seeds = seed_messages(),
    lists:foreach(
        fun(_) ->
            Seed = lists:nth(rand:uniform(length(Seeds)), Seeds),
            Mutated = mutate(Seed),
            P = mailio_mime:parse(Mutated),
            ?assert(is_map(P)),
            _ = mailio_mime:leaves(P)
        end,
        lists:seq(1, ?ITERATIONS)
    ),
    ok.

mutate(Bin) ->
    case byte_size(Bin) of
        0 ->
            Bin;
        N ->
            NumMutations = rand:uniform(8),
            lists:foldl(
                fun(_, Acc) ->
                    Pos = rand:uniform(byte_size(Acc)) - 1,
                    <<Pre:Pos/binary, _:8, Post/binary>> = pad(Acc, Pos),
                    <<Pre/binary, (rand:uniform(256) - 1):8, Post/binary>>
                end,
                Bin,
                lists:seq(1, NumMutations)
            ),
            %% Occasionally truncate.
            case rand:uniform(3) of
                1 -> binary:part(Bin, 0, rand:uniform(N));
                _ -> Bin
            end
    end.

pad(Bin, Pos) when byte_size(Bin) > Pos -> Bin;
pad(Bin, Pos) -> <<Bin/binary, 0:(8 * (Pos + 1 - byte_size(Bin)))>>.

seed_messages() ->
    [
        <<"Content-Type: text/plain\r\n\r\nhello">>,
        <<
            "Content-Type: multipart/mixed; boundary=X\r\n\r\n"
            "--X\r\nContent-Type: text/plain\r\n\r\na\r\n--X--\r\n"
        >>,
        <<
            "Content-Type: message/rfc822\r\n\r\n"
            "From: x@y\r\nSubject: s\r\n\r\nbody"
        >>,
        <<
            "Subject: =?utf-8?B?aGVsbG8=?=\r\nContent-Type: text/html\r\n\r\n"
            "<p>hi</p>"
        >>
    ].

%%====================================================================
%% Property 3: decoder inverses
%%====================================================================
decode_inverse_qp(_Config) ->
    lists:foreach(
        fun(_) ->
            Body = crypto:strong_rand_bytes(rand:uniform(128)),
            Encoded = mailio_mime_render:render(
                #{
                    type => <<"text">>,
                    subtype => <<"plain">>,
                    encoding => <<"quoted-printable">>,
                    body => Body
                }
            ),
            Parsed = mailio_mime:parse(Encoded),
            ?assertEqual(Body, mailio_mime:body(Parsed))
        end,
        lists:seq(1, 500)
    ),
    ok.

decode_inverse_base64(_Config) ->
    lists:foreach(
        fun(_) ->
            Body = crypto:strong_rand_bytes(rand:uniform(256)),
            ?assertEqual(Body, mailio_mime_decode:decode_base64(base64:encode(Body)))
        end,
        lists:seq(1, 500)
    ),
    ok.
