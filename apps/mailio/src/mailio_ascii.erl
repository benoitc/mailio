%%% @doc Byte-safe ASCII helpers (pure, total).
%%%
%%% The `string' module interprets its input as Unicode and raises on
%%% invalid UTF-8. Header bytes and MIME tokens arrive as arbitrary bytes
%%% (real-world and adversarial mail is frequently not valid UTF-8), so the
%%% parser uses these byte-level helpers instead. They only touch the ASCII
%%% range and pass all other bytes through untouched.
-module(mailio_ascii).

-export([lower/1, upper/1, trim/1, trim_leading/1, trim_trailing/1]).
-export([to_integer/2]).

-spec lower(binary()) -> binary().
lower(Bin) -> << <<(lc(B))>> || <<B>> <= Bin >>.

lc(B) when B >= $A, B =< $Z -> B + 32;
lc(B) -> B.

-spec upper(binary()) -> binary().
upper(Bin) -> << <<(uc(B))>> || <<B>> <= Bin >>.

uc(B) when B >= $a, B =< $z -> B - 32;
uc(B) -> B.

-spec trim(binary()) -> binary().
trim(Bin) -> trim_trailing(trim_leading(Bin)).

-spec trim_leading(binary()) -> binary().
trim_leading(<<C, Rest/binary>>)
  when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    trim_leading(Rest);
trim_leading(Bin) -> Bin.

-spec trim_trailing(binary()) -> binary().
trim_trailing(Bin) ->
    S = byte_size(Bin),
    case S > 0 andalso is_ws(binary:at(Bin, S - 1)) of
        true -> trim_trailing(binary:part(Bin, 0, S - 1));
        false -> Bin
    end.

is_ws(C) -> C =:= $\s orelse C =:= $\t orelse C =:= $\r orelse C =:= $\n.

%% @doc Parse a leading signed integer from a (possibly non-UTF8) binary.
%% Returns `Default' if no digits are present. Never raises.
-spec to_integer(binary(), Default) -> integer() | Default.
to_integer(Bin, Default) ->
    case int_prefix(trim_leading(Bin), <<>>) of
        <<>> -> Default;
        Digits -> binary_to_integer(Digits)
    end.

int_prefix(<<C, Rest/binary>>, <<>>) when C =:= $-; C =:= $+ ->
    int_digits(Rest, <<C>>);
int_prefix(Bin, _) ->
    int_digits(Bin, <<>>).

int_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    int_digits(Rest, <<Acc/binary, C>>);
int_digits(_, Acc) ->
    %% A lone sign is not an integer.
    case Acc of
        <<"-">> -> <<>>;
        <<"+">> -> <<>>;
        _ -> Acc
    end.
