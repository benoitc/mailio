%%% @doc Uniform error values.
%%%
%%% Every Mailio error is `{error, error_map()}' where the map carries a
%%% namespaced atom `code', a human `message', a `retryable' flag, the
%%% `source' subsystem, and free-form `detail'. Codes are namespaced by
%%% subsystem prefix (imap_*, smtp_*, store_*, mime_*, ...). JMAP method
%%% error names map onto these later.
-module(mailio_error).

-export([new/1, new/2, new/3]).
-export([code/1, message/1, is_retryable/1, source/1, detail/1]).
-export([is_error/1, format/1]).

-export_type([error_map/0, t/0]).

-type error_map() :: #{
    code := atom(),
    message := binary(),
    retryable := boolean(),
    source := atom(),
    detail := map()
}.
-type t() :: {error, error_map()}.

%% @doc Build an error from a code alone; message/source/retryable are derived.
-spec new(atom()) -> t().
new(Code) when is_atom(Code) ->
    new(Code, #{}).

-spec new(atom(), map()) -> t().
new(Code, Detail) when is_atom(Code), is_map(Detail) ->
    new(Code, default_message(Code), Detail).

-spec new(atom(), binary(), map()) -> t().
new(Code, Message, Detail) when
    is_atom(Code), is_binary(Message), is_map(Detail)
->
    {error, #{
        code => Code,
        message => Message,
        retryable => default_retryable(Code),
        source => source_of(Code),
        detail => Detail
    }}.

-spec is_error(term()) -> boolean().
is_error({error, #{code := _, message := _, source := _}}) -> true;
is_error(_) -> false.

-spec code(t()) -> atom().
code({error, #{code := C}}) -> C.

-spec message(t()) -> binary().
message({error, #{message := M}}) -> M.

-spec is_retryable(t()) -> boolean().
is_retryable({error, #{retryable := R}}) -> R.

-spec source(t()) -> atom().
source({error, #{source := S}}) -> S.

-spec detail(t()) -> map().
detail({error, #{detail := D}}) -> D.

-spec format(t()) -> binary().
format({error, #{code := C, message := M}}) ->
    iolist_to_binary([atom_to_binary(C, utf8), <<": ">>, M]).

%%====================================================================
%% Internal
%%====================================================================

%% Derive the subsystem from the code's prefix, but only for known
%% subsystem namespaces; otherwise the source is `mailio'. (Plain codes
%% like `not_found' contain an underscore yet have no subsystem prefix.)
-spec source_of(atom()) -> atom().
source_of(Code) ->
    case binary:split(atom_to_binary(Code, utf8), <<"_">>) of
        [Prefix, _Rest] ->
            case lists:member(Prefix, known_prefixes()) of
                true -> binary_to_atom(Prefix, utf8);
                false -> mailio
            end;
        [_Single] ->
            mailio
    end.

-spec known_prefixes() -> [binary()].
known_prefixes() ->
    [
        <<"imap">>,
        <<"smtp">>,
        <<"pop3">>,
        <<"jmap">>,
        <<"store">>,
        <<"mime">>,
        <<"sync">>,
        <<"auth">>
    ].

-spec default_retryable(atom()) -> boolean().
default_retryable(imap_disconnected) -> true;
default_retryable(imap_timeout) -> true;
default_retryable(smtp_transient) -> true;
default_retryable(smtp_connect_failed) -> true;
default_retryable(pop3_disconnected) -> true;
default_retryable(pop3_connect_failed) -> true;
default_retryable(pop3_timeout) -> true;
default_retryable(store_unavailable) -> true;
default_retryable(_) -> false.

-spec default_message(atom()) -> binary().
default_message(Code) ->
    atom_to_binary(Code, utf8).
