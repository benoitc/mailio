%%% Shared definitions for Mailio.

-ifndef(MAILIO_HRL).
-define(MAILIO_HRL, true).

%% Document id prefixes (path-style, exploit barrel prefix indexing).
%% Defined as string literals so they compose in binary literals and
%% match in binary patterns: `<<?ID_EMAIL, Id/binary>>'.
-define(ID_EMAIL,      "email/").
-define(ID_MAILBOX,    "mailbox/").
-define(ID_THREAD,     "thread/").
-define(ID_MSGID,      "msgid/").
-define(ID_BLOB,       "blob/").
-define(ID_TEXT,       "text/").
-define(ID_IDENTITY,   "identity/").
-define(ID_SUBMISSION, "submission/").
-define(ID_SYNC_IMAP,  "sync/imap/").
-define(ID_RULE,       "rule/").
-define(ID_JOB,        "job/").
-define(ID_ACCOUNT,    "account/").
-define(ID_GRANT,      "grant/").

%% Internal sub-map key. Fields under this key are Mailio-internal and are
%% stripped when serializing to a JMAP HTTP client.
-define(MAILIO_NS, <<"_mailio">>).

%% System keyword (JMAP) strings.
-define(KW_SEEN,     <<"$seen">>).
-define(KW_FLAGGED,  <<"$flagged">>).
-define(KW_ANSWERED, <<"$answered">>).
-define(KW_DRAFT,    <<"$draft">>).
-define(KW_FORWARDED,<<"$forwarded">>).

-endif.
