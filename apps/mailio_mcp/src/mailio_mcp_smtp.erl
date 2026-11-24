%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Submission bridge: maps an account's outgoing settings to the
%%% `mailio_smtp' client and its result to the shape the send state machine
%%% records. The protocol itself lives in the mailio library.
-module(mailio_mcp_smtp).

-export([submit/4]).

%% Returns
%%   {ok, #{accepted, rejected, reply}}      accepted for submission
%%   {error, {before_data, Reason}}           nothing was sent, safe to retry
%%   {error, {rejected, Code, Text, Info}}    the server refused the message
%%   {error, {unknown, Reason}}               body sent, no final reply
-spec submit(map(), binary(), [binary()], iodata()) -> {ok, map()} | {error, term()}.
submit(Account, From, Rcpts, Data) ->
    case mailio_smtp:submit(config(Account), From, Rcpts, Data) of
        {ok, #{accepted := A, rejected := R, reply := Reply}} ->
            {ok, #{accepted => A, rejected => R, reply => Reply}};
        {error, #{code := smtp_rejected, detail := D}} ->
            {error,
                {rejected, maps:get(code, D, 550), maps:get(reply, D, <<"refused">>), #{
                    stage => maps:get(stage, D, unknown),
                    rejected => maps:get(rejected, D, [])
                }}};
        {error, #{code := smtp_outcome_unknown, detail := D}} ->
            {error, {unknown, maps:get(reason, D, no_final_reply)}};
        {error, #{code := Code, detail := D}} ->
            {error, {before_data, {Code, D}}}
    end.

config(#{outgoing := Out, auth_out := Auth}) ->
    Cfg = mailio_mcp_net:config(Out, Auth),
    case maps:is_key(port, Cfg) of
        true ->
            Cfg;
        false ->
            Cfg#{
                port => default_port(maps:get(tls, Out, starttls)),
                ehlo_name => maps:get(ehlo_name, Out, <<"localhost">>)
            }
    end.

default_port(implicit) -> 465;
default_port(_) -> 587.
