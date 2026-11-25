%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% Shared definitions for mailio_store.

-include_lib("mailio/include/mailio.hrl").

-ifndef(MAILIO_STORE_HRL).
-define(MAILIO_STORE_HRL, true).

%% Document id prefixes (path-style, exploit barrel prefix indexing).
%% Defined as string literals so they compose in binary literals and
%% match in binary patterns: `<<?ID_EMAIL, Id/binary>>'.
-define(ID_EMAIL, "email/").
-define(ID_MAILBOX, "mailbox/").
-define(ID_THREAD, "thread/").
-define(ID_MSGID, "msgid/").
-define(ID_BLOB, "blob/").
-define(ID_TEXT, "text/").
-define(ID_IDENTITY, "identity/").
-define(ID_SUBMISSION, "submission/").
-define(ID_SYNC_IMAP, "sync/imap/").
%% Present while a mailbox that was recreated has not been read in full again.
-define(ID_SYNC_RESET, "sync/reset/").
-define(ID_UIDMAP, "uidmap/").
-define(ID_RULE, "rule/").
-define(ID_JOB, "job/").
-define(ID_ACCOUNT, "account/").
-define(ID_GRANT, "grant/").

%% Internal sub-map key. Fields under this key are Mailio-internal and are
%% stripped when serializing to a JMAP HTTP client.
%%
%% NOTE: must NOT start with an underscore. barrel excludes top-level keys
%% beginning with `_' from its ARS path index (reserved, like `_rev'), so a
%% `_mailio' namespace would make every internal field (subject_norm,
%% from_norm, received_ts, ...) unqueryable. The JMAP layer strips this key
%% explicitly rather than relying on an underscore convention.
-define(MAILIO_NS, <<"mailio">>).

-endif.
