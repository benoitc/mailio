# Store raw messages as files

This page shows how to keep the raw bytes of messages as files on disk instead of attachments inside the database, how to move an existing store over, and how to find and repair blobs that are missing or damaged. You need it when the database grows large from message bodies, or when you replicate accounts between nodes.

Message metadata, flags, mailboxes and blob references always stay in the database. Only the bytes move.

## Switch new messages to files

Set the backend and, if you want one, the directory:

```erlang
{mailio_store, [
    {blob_backend, files},
    {blob_root, "/var/lib/mailio/blobs"}   %% default: <data_dir>/blobs
]}
```

The default is `docdb`, which keeps the bytes as an attachment on the blob document. Nothing changes until you set `files`.

A blob is stored as `<blob_root>/<account database>/<aa>/<sha256>`, where `aa` is the first two hex digits. The name is the SHA-256 of the content, so identical messages are one file and any file can be checked against its own name. A file is written to a `tmp` directory, synced and renamed into place, so a reader never sees half a message.

Blobs written before the switch stay readable, and so do blobs written after switching back: a read looks in the configured place first and in the other one second.

## Move existing messages to files

Count what would move, then move it. Run it through the account writer so it is serialized with ingestion:

```erlang
{ok, #{moved := N}} = mailio_account_writer:migrate_blobs(AccountId, #{dry_run => true}),
{ok, Result} = mailio_account_writer:migrate_blobs(AccountId, #{}).
%% #{moved => 120, skipped => 3, failed => []}
```

For each blob the attachment is checked against its hash, the file is written and read back, the document is marked, and only then is the attachment removed. If the process stops half way, nothing is lost and running it again finishes the job. A blob whose attachment does not match its hash is left where it is and listed under `failed`.

## Check the store

```erlang
{ok, Report} = mailio_fsck:check_blobs(AccountId).
%% #{missing => [Hex], corrupt => [Hex], orphan_files => [Hex]}
```

- `missing`: the database knows the blob, but its bytes are not here. This is what a replica looks like when documents arrive before the files.
- `corrupt`: a file whose content no longer matches its name.
- `orphan_files`: a file no blob document names, for example after a crash between writing the file and the document.

## Repair

```erlang
{ok, R} = mailio_fsck:repair_blobs(AccountId, #{orphan_grace => 86400}).
%% #{quarantined => 1, orphans_removed => 0, pulled => 2, failed => []}
```

Repair moves a corrupt file to `<blob_root>/<account>/corrupt/` (it is kept for inspection, not served), removes orphan files older than `orphan_grace` seconds (a young one may be a write in progress), and fetches what is missing.

## Fetch missing blobs from another node

Documents replicate through the database; the bytes of a file do not. Tell the store how to ask a peer for a blob by hash:

```erlang
application:set_env(mailio_store, blob_fetcher,
    fun(Db, Hex) ->
        case my_peer:fetch_blob(Db, Hex) of
            {ok, Bytes} -> {ok, Bytes};
            {error, _} = Err -> Err
        end
    end).
```

`mailio_blob:pull_missing/1` and `repair_blobs/2` call it for each missing blob. Whatever the peer returns is hashed before it is stored, and bytes that do not match the name are refused, so a bad or hostile peer cannot put wrong content in the store. Without a fetcher, repair reports what is missing and fetches nothing.

## Notes

- Garbage collection works the same with files: a blob with no references waits out the grace period, then its document and its file are removed together.
- The fetcher and the transport to a peer are yours; the store only defines the call.
- Back up the blob directory together with the database. Either alone is an incomplete copy.
