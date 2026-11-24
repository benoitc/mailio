%%% mailio_smtp against a real SMTP server (Mailpit). The unit tests use a
%%% scripted fake server; this suite checks that what a real server received
%%% is what we meant to send. Start it first:
%%%   apps/mailio/test/mailpit/gen-certs.sh
%%%   (cd apps/mailio/test/mailpit && docker compose up -d)
-module(mailio_smtp_mailpit_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    plain_with_login/1,
    authentication_required/1,
    wrong_password/1,
    content_arrives_intact/1,
    non_ascii_message/1,
    attachment_arrives_intact/1,
    bcc_is_not_in_the_headers/1,
    starttls_verified/1,
    starttls_untrusted_refused/1,
    starttls_wrong_host_refused/1
]).

-define(API, "http://127.0.0.1:18025/api/v1").
-define(SMTP_PORT, 11025).

all() ->
    [
        plain_with_login,
        authentication_required,
        wrong_password,
        content_arrives_intact,
        non_ascii_message,
        attachment_arrives_intact,
        bcc_is_not_in_the_headers,
        starttls_verified,
        starttls_untrusted_refused,
        starttls_wrong_host_refused
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    case reachable(?SMTP_PORT) andalso reachable(18025) of
        false ->
            {skip, "Mailpit is not running (see the header of this suite)"};
        true ->
            case find_ca(proplists:get_value(data_dir, Config)) of
                undefined -> {skip, "run apps/mailio/test/mailpit/gen-certs.sh and restart Mailpit"};
                CA -> [{ca, CA} | Config]
            end
    end.

end_per_suite(_) -> ok.

init_per_testcase(_, Config) ->
    ok = clear(),
    Config.

reachable(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary], 500) of
        {ok, S} -> gen_tcp:close(S), true;
        _ -> false
    end.

find_ca(Dir) ->
    Rel = "apps/mailio/test/mailpit/certs/ca.pem",
    case filelib:is_file(filename:join(Dir, Rel)) of
        true -> filename:join(Dir, Rel);
        false ->
            Up = filename:dirname(string:trim(Dir, trailing, "/")),
            case Up =:= Dir of true -> undefined; false -> find_ca(Up) end
    end.

%%--------------------------------------------------------------------
%% Helpers

cfg(Extra) ->
    maps:merge(
        #{host => <<"127.0.0.1">>, port => ?SMTP_PORT, tls => false, ehlo_name => <<"mailio.test">>,
          credentials => {password, <<"testuser">>, <<"testpass">>}},
        Extra).

http_json(Method, Path) ->
    {ok, {{_, 200, _}, _, Body}} = httpc:request(Method, {?API ++ Path, []}, [], [{body_format, binary}]),
    json:decode(Body).

clear() ->
    {ok, _} = httpc:request(delete, {?API ++ "/messages", []}, [], []),
    ok.

%% The one captured message, with its full detail.
the_message() ->
    #{<<"messages">> := Msgs} = http_json(get, "/messages"),
    [#{<<"ID">> := Id}] = Msgs,
    http_json(get, "/message/" ++ binary_to_list(Id)).

addrs(L) -> [maps:get(<<"Address">>, A) || A <- L].

build(Spec) -> mailio_mime_render:build(Spec).

simple(Spec) ->
    build(maps:merge(#{from => [#{email => <<"me@example.test">>, name => <<"Me">>}],
                       to => [#{email => <<"you@example.test">>}],
                       subject => <<"hello">>, message_id => <<"m1@mailio.test">>,
                       text => <<"Hi there.\r\n">>}, Spec)).

%%--------------------------------------------------------------------
%% Cases

plain_with_login(_) ->
    {ok, R} = mailio_smtp:submit(cfg(#{}), <<"me@example.test">>, [<<"you@example.test">>], simple(#{})),
    [<<"you@example.test">>] = maps:get(accepted, R),
    [] = maps:get(rejected, R),
    250 = maps:get(code, R),
    Msg = the_message(),
    <<"hello">> = maps:get(<<"Subject">>, Msg),
    ok.

authentication_required(_) ->
    {error, #{code := Code}} =
        mailio_smtp:submit(maps:remove(credentials, cfg(#{})), <<"me@example.test">>,
                           [<<"you@example.test">>], simple(#{})),
    true = lists:member(Code, [smtp_rejected, smtp_transient]),
    #{<<"messages">> := []} = http_json(get, "/messages"),
    ok.

wrong_password(_) ->
    {error, #{code := smtp_auth_failed}} =
        mailio_smtp:submit(cfg(#{credentials => {password, <<"testuser">>, <<"nope">>}}),
                           <<"me@example.test">>, [<<"you@example.test">>], simple(#{})),
    #{<<"messages">> := []} = http_json(get, "/messages"),
    ok.

content_arrives_intact(_) ->
    %% a line that starts with a dot must survive the SMTP dot-stuffing, and
    %% so must a line that is only a dot
    Text = <<"first\r\n.leading dot\r\n.\r\nlast line\r\n">>,
    {ok, _} = mailio_smtp:submit(cfg(#{}), <<"me@example.test">>, [<<"you@example.test">>],
                                 simple(#{text => Text})),
    Msg = the_message(),
    Body = maps:get(<<"Text">>, Msg),
    Lines = [string:trim(L, trailing, "\r") || L <- binary:split(Body, <<"\n">>, [global])],
    true = lists:member(<<".leading dot">>, Lines),
    true = lists:member(<<".">>, Lines),
    true = lists:member(<<"last line">>, Lines),
    <<"me@example.test">> = maps:get(<<"Address">>, maps:get(<<"From">>, Msg)),
    [<<"you@example.test">>] = addrs(maps:get(<<"To">>, Msg)),
    ok.

non_ascii_message(_) ->
    {ok, _} = mailio_smtp:submit(cfg(#{}), <<"me@example.test">>, [<<"you@example.test">>],
                                 simple(#{subject => <<"Caf\xc3\xa9 \xe2\x82\xac"/utf8>>,
                                          text => <<"Cr\xc3\xa8me br\xc3\xbbl\xc3\xa9e\r\n"/utf8>>})),
    Msg = the_message(),
    <<"Caf\xc3\xa9 \xe2\x82\xac"/utf8>> = maps:get(<<"Subject">>, Msg),
    true = binary:match(maps:get(<<"Text">>, Msg), <<"Cr\xc3\xa8me br\xc3\xbbl\xc3\xa9e"/utf8>>) =/= nomatch,
    ok.

attachment_arrives_intact(_) ->
    Bytes = crypto:strong_rand_bytes(300000),
    Raw = mailio_mime_render:render(#{
        type => <<"multipart">>, subtype => <<"mixed">>,
        headers => [{<<"From">>, <<"me@example.test">>}, {<<"To">>, <<"you@example.test">>},
                    {<<"Subject">>, <<"with file">>}, {<<"MIME-Version">>, <<"1.0">>}],
        parts => [
            #{type => <<"text">>, subtype => <<"plain">>, charset => <<"utf-8">>, encoding => <<"7bit">>,
              body => <<"see attached\r\n">>},
            #{type => <<"application">>, subtype => <<"octet-stream">>, encoding => <<"base64">>,
              disposition => <<"attachment">>, filename => <<"blob.bin">>, body => Bytes}]}),
    {ok, _} = mailio_smtp:submit(cfg(#{}), <<"me@example.test">>, [<<"you@example.test">>], Raw),
    Msg = the_message(),
    [#{<<"FileName">> := <<"blob.bin">>, <<"PartID">> := PartId}] = maps:get(<<"Attachments">>, Msg),
    Id = maps:get(<<"ID">>, Msg),
    {ok, {{_, 200, _}, _, Got}} = httpc:request(
        get, {?API ++ "/message/" ++ binary_to_list(Id) ++ "/part/" ++ binary_to_list(PartId), []},
        [], [{body_format, binary}]),
    Bytes = Got,
    ok.

bcc_is_not_in_the_headers(_) ->
    %% The envelope reaches the Bcc recipient, but the message we send never
    %% names them. The server derives its Bcc list from the envelope, so a
    %% recipient it lists as Bcc was not in any header.
    Raw = simple(#{}),
    nomatch = binary:match(Raw, <<"hidden@example.test">>),
    {ok, R} = mailio_smtp:submit(cfg(#{}), <<"me@example.test">>,
                                 [<<"you@example.test">>, <<"hidden@example.test">>], Raw),
    2 = length(maps:get(accepted, R)),
    Msg = the_message(),
    [<<"you@example.test">>] = addrs(maps:get(<<"To">>, Msg)),
    [<<"hidden@example.test">>] = addrs(maps:get(<<"Bcc">>, Msg)),
    ok.

starttls_verified(Config) ->
    CA = ?config(ca, Config),
    {ok, _} = mailio_smtp:submit(cfg(#{host => <<"localhost">>, tls => starttls, cacertfile => CA}),
                                 <<"me@example.test">>, [<<"you@example.test">>], simple(#{})),
    <<"hello">> = maps:get(<<"Subject">>, the_message()),
    ok.

starttls_untrusted_refused(_) ->
    %% the certificate is not in the default trust store
    {error, #{code := smtp_tls_failed}} =
        mailio_smtp:submit(cfg(#{host => <<"localhost">>, tls => starttls}),
                           <<"me@example.test">>, [<<"you@example.test">>], simple(#{})),
    #{<<"messages">> := []} = http_json(get, "/messages"),
    ok.

starttls_wrong_host_refused(Config) ->
    CA = ?config(ca, Config),
    %% the certificate is for "localhost", not for 127.0.0.1
    {error, #{code := smtp_tls_failed}} =
        mailio_smtp:submit(cfg(#{host => <<"127.0.0.1">>, tls => starttls, cacertfile => CA}),
                           <<"me@example.test">>, [<<"you@example.test">>], simple(#{})),
    #{<<"messages">> := []} = http_json(get, "/messages"),
    ok.
