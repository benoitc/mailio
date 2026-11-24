%%% @doc Time handling: RFC 3339 instants, date-only bounds in an IANA time
%%% zone, and the zone rules themselves (read from the system TZif files,
%%% including the POSIX rule that covers dates after the last stored
%%% transition). Windows are start-inclusive, end-exclusive.
-module(mailio_mcp_time).

-export([
    parse_bound/2,
    day_window/2,
    offset_at/2,
    local_to_utc/2,
    to_rfc3339/1,
    parse_header_date/1,
    rfc5322_now/0,
    parse_imap_date/1,
    check_zone/1
]).

-define(EPOCH_GREG, 62167219200).

%%====================================================================
%% Bounds
%%====================================================================

%% @doc Parse an instant (RFC 3339 with offset) or a date-only value that
%% needs a zone. Returns unix seconds of the instant, or of local midnight.
-spec parse_bound(binary(), binary() | undefined) ->
    {ok, integer(), instant | date} | {error, term()}.
parse_bound(<<Y:4/binary, $-, M:2/binary, $-, D:2/binary>>, Zone) ->
    case Zone of
        undefined ->
            {error, time_zone_required};
        _ ->
            case ymd(Y, M, D) of
                {ok, Date} ->
                    case local_to_utc(greg(Date, {0, 0, 0}), Zone) of
                        {ok, T} -> {ok, T, date};
                        E -> E
                    end;
                E ->
                    E
            end
    end;
parse_bound(Bin, _Zone) when is_binary(Bin) ->
    try
        T = calendar:rfc3339_to_system_time(binary_to_list(Bin), [{unit, second}]),
        {ok, T, instant}
    catch
        _:_ -> {error, {bad_time, Bin}}
    end;
parse_bound(_, _) ->
    {error, bad_time}.

%% @doc [Start, End) of one local calendar day.
-spec day_window(binary(), binary()) -> {ok, integer(), integer()} | {error, term()}.
day_window(<<Y:4/binary, $-, M:2/binary, $-, D:2/binary>>, Zone) ->
    case ymd(Y, M, D) of
        {ok, Date} ->
            Next = calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date) + 1),
            case
                {
                    local_to_utc(greg(Date, {0, 0, 0}), Zone),
                    local_to_utc(greg(Next, {0, 0, 0}), Zone)
                }
            of
                {{ok, S}, {ok, E}} -> {ok, S, E};
                {{error, _} = Er, _} -> Er;
                {_, {error, _} = Er} -> Er
            end;
        E ->
            E
    end;
day_window(_, _) ->
    {error, bad_date}.

ymd(Y, M, D) ->
    try
        Date = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
        true = calendar:valid_date(Date),
        {ok, Date}
    catch
        _:_ -> {error, bad_date}
    end.

%% Wall-clock datetime as seconds since 1970 as if it were UTC.
greg(Date, Time) ->
    calendar:datetime_to_gregorian_seconds({Date, Time}) - ?EPOCH_GREG.

to_rfc3339(T) ->
    list_to_binary(calendar:system_time_to_rfc3339(T, [{unit, second}, {offset, "Z"}])).

%% @doc The current time as an RFC 5322 Date header value, in UTC.
-spec rfc5322_now() -> binary().
rfc5322_now() ->
    {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(
        erlang:system_time(second), second
    ),
    Days = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"},
    Months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
    Dow = element(calendar:day_of_the_week(Y, M, D), Days),
    iolist_to_binary(
        io_lib:format("~s, ~2..0w ~s ~4..0w ~2..0w:~2..0w:~2..0w +0000", [
            Dow, D, element(M, Months), Y, H, Mi, S
        ])
    ).

%% @doc RFC 5322 Date header to unix seconds.
parse_header_date(Bin) ->
    try
        Clean = string:trim(re:replace(Bin, <<"\\s*\\(.*\\)\\s*$">>, <<>>, [{return, binary}])),
        Clean2 =
            case binary:split(Clean, <<",">>) of
                [_, Rest] -> string:trim(Rest);
                [Only] -> Only
            end,
        {match, [D, Mon, Y, H, Mi, S0, Off]} = re:run(
            Clean2,
            <<"^(\\d{1,2})\\s+([A-Za-z]{3})\\s+(\\d{2,4})\\s+",
                "(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\s*([+-]\\d{4}|[A-Za-z]+)?">>,
            [{capture, all_but_first, binary}]
        ),
        Yr0 = binary_to_integer(Y),
        Yr =
            if
                Yr0 < 50 -> Yr0 + 2000;
                Yr0 < 100 -> Yr0 + 1900;
                true -> Yr0
            end,
        Sec =
            case S0 of
                <<>> -> 0;
                _ -> binary_to_integer(S0)
            end,
        Local = greg(
            {Yr, month(Mon), binary_to_integer(D)},
            {binary_to_integer(H), binary_to_integer(Mi), Sec}
        ),
        {ok, Local - zone_offset(Off)}
    catch
        _:_ -> error
    end.

%% @doc IMAP INTERNALDATE ("17-Jul-1996 02:44:25 -0700") to unix seconds.
parse_imap_date(Bin) ->
    try
        {match, [D, Mon, Y, H, Mi, S, Off]} = re:run(
            string:trim(Bin),
            <<"^\\s*(\\d{1,2})-([A-Za-z]{3})-(\\d{4})\\s+(\\d{2}):(\\d{2}):(\\d{2})\\s+([+-]\\d{4})">>,
            [{capture, all_but_first, binary}]
        ),
        Local = greg(
            {binary_to_integer(Y), month(Mon), binary_to_integer(D)},
            {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)}
        ),
        {ok, Local - zone_offset(Off)}
    catch
        _:_ -> error
    end.

zone_offset(<<S, HH:2/binary, MM:2/binary>>) when S =:= $+; S =:= $- ->
    V = binary_to_integer(HH) * 3600 + binary_to_integer(MM) * 60,
    case S of
        $+ -> V;
        $- -> -V
    end;
zone_offset(<<"GMT">>) ->
    0;
zone_offset(<<"UT">>) ->
    0;
zone_offset(<<"Z">>) ->
    0;
zone_offset(_) ->
    0.

month(<<M:3/binary>>) ->
    L = string:lowercase(M),
    {_, N} = lists:keyfind(
        L,
        1,
        lists:zip(
            [
                <<"jan">>,
                <<"feb">>,
                <<"mar">>,
                <<"apr">>,
                <<"may">>,
                <<"jun">>,
                <<"jul">>,
                <<"aug">>,
                <<"sep">>,
                <<"oct">>,
                <<"nov">>,
                <<"dec">>
            ],
            lists:seq(1, 12)
        )
    ),
    N.

%%====================================================================
%% Zone rules
%%====================================================================

check_zone(Zone) ->
    case load(Zone) of
        {ok, _} -> ok;
        E -> E
    end.

%% @doc UTC offset in seconds in effect at unix time T.
-spec offset_at(integer(), binary()) -> integer().
offset_at(T, Zone) ->
    {ok, Z} = load(Zone),
    zone_offset_at(T, Z).

%% @doc Convert a wall-clock time (seconds as if UTC) to a unix instant.
%% An ambiguous time takes its first occurrence; a time in a gap is moved
%% forward by the length of the gap.
-spec local_to_utc(integer(), binary()) -> {ok, integer()} | {error, term()}.
local_to_utc(Local, Zone) ->
    case load(Zone) of
        {ok, Z} ->
            Cands = lists:usort([zone_offset_at(Local - 86400, Z), zone_offset_at(Local + 86400, Z)]),
            Valid = [Local - O || O <- Cands, zone_offset_at(Local - O, Z) =:= O],
            case Valid of
                [] -> {ok, Local - zone_offset_at(Local - 86400, Z)};
                _ -> {ok, lists:min(Valid)}
            end;
        E ->
            E
    end.

zone_offset_at(T, #{trans := Trans, types := Types, footer := Footer, first := First}) ->
    case Trans of
        [] ->
            footer_offset(T, Footer, element(1, First));
        _ ->
            {LastT, _} = lists:last(Trans),
            if
                T < element(1, hd(Trans)) -> element(1, First);
                T >= LastT, Footer =/= undefined -> footer_offset(T, Footer, 0);
                true -> element(1, lists:nth(find_idx(T, Trans), Types))
            end
    end.

find_idx(T, Trans) ->
    find_idx(T, Trans, 0).
find_idx(T, [{_, Idx}, {Next, _} | _], _) when T < Next -> Idx + 1;
find_idx(_T, [{_, Idx}], _) -> Idx + 1;
find_idx(T, [_ | Rest], A) -> find_idx(T, Rest, A + 1).

footer_offset(_T, undefined, Default) ->
    Default;
footer_offset(T, #{std := Std, dst := none}, _) ->
    _ = T,
    Std;
footer_offset(T, #{std := Std, dst := Dst, start := S, 'end' := E}, _) ->
    {Y, _, _} = date_of(T + Std),
    StartUtc = rule_local(Y, S) - Std,
    EndUtc = rule_local(Y, E) - Dst,
    InDst =
        case StartUtc < EndUtc of
            true -> T >= StartUtc andalso T < EndUtc;
            false -> T >= StartUtc orelse T < EndUtc
        end,
    case InDst of
        true -> Dst;
        false -> Std
    end.

date_of(T) ->
    {D, _} = calendar:gregorian_seconds_to_datetime(T + ?EPOCH_GREG),
    D.

rule_local(Y, {M, W, Dow, TimeSecs}) ->
    %% 0 = Sunday
    FirstDow = calendar:day_of_the_week({Y, M, 1}) rem 7,
    Delta = (Dow - FirstDow + 7) rem 7,
    Day0 = 1 + Delta + (W - 1) * 7,
    Last = calendar:last_day_of_the_month(Y, M),
    Day =
        case Day0 > Last of
            true -> Day0 - 7;
            false -> Day0
        end,
    greg({Y, M, Day}, {0, 0, 0}) + TimeSecs.

%%====================================================================
%% TZif loading
%%====================================================================

load(Zone) when is_binary(Zone) ->
    Key = {?MODULE, Zone},
    case persistent_term:get(Key, undefined) of
        undefined ->
            case read_zone(Zone) of
                {ok, Z} = Ok ->
                    persistent_term:put(Key, Z),
                    Ok;
                E ->
                    E
            end;
        Z ->
            {ok, Z}
    end;
load(_) ->
    {error, bad_time_zone}.

read_zone(Zone) ->
    case
        re:run(Zone, <<"^[A-Za-z0-9_+/-]+$">>) =:= nomatch orelse
            binary:match(Zone, <<"..">>) =/= nomatch
    of
        true ->
            {error, {unknown_time_zone, Zone}};
        false ->
            Dirs =
                case os:getenv("TZDIR") of
                    false -> [];
                    D -> [D]
                end ++
                    [
                        "/usr/share/zoneinfo",
                        "/usr/lib/zoneinfo",
                        "/usr/share/lib/zoneinfo",
                        "/var/db/timezone/zoneinfo"
                    ],
            read_first(Dirs, binary_to_list(Zone))
    end.

read_first([], _) ->
    {error, {unknown_time_zone, no_zoneinfo}};
read_first([D | Rest], Zone) ->
    case file:read_file(filename:join(D, Zone)) of
        {ok, Bin} ->
            try
                {ok, parse_tzif(Bin)}
            catch
                _:_ -> {error, {bad_zoneinfo, Zone}}
            end;
        _ ->
            read_first(Rest, Zone)
    end.

parse_tzif(<<"TZif", Ver, _:15/binary, Counts:24/binary, Rest/binary>>) ->
    {IsUt, IsStd, Leap, TimeCnt, TypeCnt, CharCnt} = counts(Counts),
    V1Len = TimeCnt * 5 + TypeCnt * 6 + CharCnt + Leap * 8 + IsStd + IsUt,
    case Ver of
        $\0 ->
            erlang:error(v1_only_unsupported);
        _ ->
            <<_:V1Len/binary, "TZif", _, _:15/binary, Counts2:24/binary, Rest2/binary>> = Rest,
            {IsUt2, IsStd2, Leap2, TimeCnt2, TypeCnt2, CharCnt2} = counts(Counts2),
            Len2 = TimeCnt2 * 9 + TypeCnt2 * 6 + CharCnt2 + Leap2 * 12 + IsStd2 + IsUt2,
            <<Body:Len2/binary, Footer/binary>> = Rest2,
            Z = block_with(Body, 8, Counts2),
            Z#{footer => parse_footer(Footer)}
    end.

counts(<<A:32, B:32, C:32, D:32, E:32, F:32>>) -> {A, B, C, D, E, F}.

block_with(Body, TS, Counts) ->
    {_, _, _, TimeCnt, TypeCnt, _} = counts(Counts),
    Bits = TS * 8,
    <<TimesBin:(TimeCnt * TS)/binary, IdxBin:TimeCnt/binary, TypesBin:(TypeCnt * 6)/binary,
        _/binary>> = Body,
    Times = [T || <<T:Bits/signed>> <= TimesBin],
    Idxs = binary_to_list(IdxBin),
    Types = [{Off, Dst} || <<Off:32/signed, Dst, _Abbr>> <= TypesBin],
    First =
        case [Ty || {_, 0} = Ty <- Types] of
            [F | _] -> F;
            [] -> hd(Types)
        end,
    #{trans => lists:zip(Times, Idxs), types => Types, first => First}.

parse_footer(<<"\n", Rest/binary>>) ->
    case binary:split(Rest, <<"\n">>) of
        [<<>> | _] -> undefined;
        [Tz | _] -> parse_posix(Tz)
    end;
parse_footer(_) ->
    undefined.

parse_posix(Tz) ->
    try
        {_, R1} = name(Tz),
        {Std, R2} = offset(R1),
        case R2 of
            <<>> ->
                #{std => -Std, dst => none};
            _ ->
                {_, R3} = name(R2),
                {DstOff, R4} =
                    case R3 of
                        <<$,, _/binary>> -> {Std - 3600, R3};
                        _ -> offset(R3)
                    end,
                <<$,, RulesBin/binary>> = R4,
                [SB, EB] = binary:split(RulesBin, <<",">>),
                #{std => -Std, dst => -DstOff, start => rule(SB), 'end' => rule(EB)}
        end
    catch
        _:_ -> undefined
    end.

name(<<$<, Rest/binary>>) ->
    [N, R] = binary:split(Rest, <<">">>),
    {N, R};
name(Bin) ->
    {Len, _} = binary:match(Bin, [
        <<"+">>,
        <<"-">>,
        <<"0">>,
        <<"1">>,
        <<"2">>,
        <<"3">>,
        <<"4">>,
        <<"5">>,
        <<"6">>,
        <<"7">>,
        <<"8">>,
        <<"9">>,
        <<",">>
    ]),
    <<N:Len/binary, R/binary>> = Bin,
    {N, R}.

offset(Bin) ->
    {Sign, R} =
        case Bin of
            <<$-, X/binary>> -> {-1, X};
            <<$+, X/binary>> -> {1, X};
            X -> {1, X}
        end,
    {Secs, Rest} = hms(R),
    {Sign * Secs, Rest}.

hms(Bin) ->
    {H, R1} = int(Bin),
    case R1 of
        <<$:, R2/binary>> ->
            {M, R3} = int(R2),
            case R3 of
                <<$:, R4/binary>> ->
                    {S, R5} = int(R4),
                    {H * 3600 + M * 60 + S, R5};
                _ ->
                    {H * 3600 + M * 60, R3}
            end;
        _ ->
            {H * 3600, R1}
    end.

int(Bin) ->
    {Digits, Rest} = lists:splitwith(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)),
    {list_to_integer(Digits), list_to_binary(Rest)}.

rule(<<$M, R/binary>>) ->
    {M, <<$., R1/binary>>} = int(R),
    {W, <<$., R2/binary>>} = int(R1),
    {D, R3} = int(R2),
    Time =
        case R3 of
            <<$/, T/binary>> ->
                {S, _} = signed_hms(T),
                S;
            _ ->
                7200
        end,
    {M, W, D, Time}.

signed_hms(<<$-, R/binary>>) ->
    {S, X} = hms(R),
    {-S, X};
signed_hms(<<$+, R/binary>>) ->
    hms(R);
signed_hms(R) ->
    hms(R).
