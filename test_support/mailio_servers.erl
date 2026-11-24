%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc The real mail servers the interoperability suites run against, and
%%% what each one offers. A suite takes a profile and skips a case when the
%%% server does not offer what the case needs. Adding a server is adding a
%%% profile here and a group in each suite.
-module(mailio_servers).

-export([profile/1, all/0, ca_file/0, reachable/1]).

all() -> [dovecot, greenmail, stalwart].

%% The private CA made by apps/mailio/test/mailpit/gen-certs.sh.
ca_file() ->
    filename:join([
        filename:dirname(filename:dirname(?FILE)),
        "apps",
        "mailio",
        "test",
        "mailpit",
        "certs",
        "ca.pem"
    ]).

reachable(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary], 500) of
        {ok, S} ->
            gen_tcp:close(S),
            true;
        _ ->
            false
    end.

%% What each server offers. A key that is missing means "not offered", and the
%% case that needs it is skipped for that server.
profile(dovecot) ->
    #{
        name => dovecot,
        user => <<"testuser">>,
        pass => <<"testpass">>,
        imap => 31143,
        imap_tls => 31993,
        imap_starttls => true,
        exact_sizes => true,
        pop3_stls => false,
        %% the host name in the certificate
        tls_host => <<"localhost">>,
        pop3 => 31110,
        pop3_tls => 31995,
        verify => ca
    };
profile(greenmail) ->
    #{
        name => greenmail,
        user => <<"alice">>,
        pass => <<"secret">>,
        address => <<"alice@example.test">>,
        imap => 3143,
        imap_tls => 3993,
        pop3 => 3110,
        pop3_tls => 3995,
        smtp => 3025,
        smtp_tls => 3465,
        %% GreenMail makes a self-signed certificate on every start
        verify => none
    };
%% Stalwart: apps/mailio/test/stalwart/setup.sh. It refuses a plain login, so
%% every connection upgrades with STARTTLS or STLS first.
profile(stalwart) ->
    #{
        name => stalwart,
        user => <<"alice@interop.test">>,
        pass => <<"interop-secret">>,
        address => <<"alice@interop.test">>,
        plain_tls => starttls,
        imap => 32143,
        imap_tls => 32993,
        imap_starttls => true,
        pop3 => 32110,
        pop3_tls => 32995,
        pop3_stls => true,
        smtp => 32587,
        smtp_tls => 32465,
        verify => none
    }.
