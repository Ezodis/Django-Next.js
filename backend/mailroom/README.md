# Admin mailbox

This app is discovered automatically in each project. Inbox lives at
`/admin/mailroom/receivedemail/`; Compose and sent mail supports sending and replies.
Read/unread, archive, MIME and attachment downloads require mailbox permissions.
Bodies render with linked plain text or an allowlisted HTML reader. Mail lives in each
project's own database and is included in its database backups.

## Configuration

`MAILBOX_DOMAIN` overrides this project's `DOMAIN`. The default alias is taken
from `DEFAULT_FROM_EMAIL` when its domain matches, otherwise it is `$`.
Existing messages and saved sender aliases are preserved. Credentials belong in
this project's root `.env` or deployment variables; never copy another project's
credentials. Django email backend/provider configuration stays in `backend/project.py`.
Projects opt in with `project_email_settings()` from `mailroom.configuration`
in their `backend/project.py`. `PROJECT_ACCOUNT_EMAIL` and `DEFAULT_FROM_EMAIL`
default to `$@<MAILBOX_DOMAIN or DOMAIN>`. Explicit environment overrides win.
The helper chooses Cloudflare HTTPS when `CLOUDFLARE_EMAIL_API_TOKEN` is set
(also requires `CLOUDFLARE_ACCOUNT_ID`), Brevo HTTPS when `BREVO_API_KEY` is set,
or the project's SMTP configuration. `EMAIL_BACKEND` can explicitly select a
provider. Console, dummy and file backends leave messages queued instead of
claiming actual delivery. The address identifies the project; it does not create
provider accounts or supply credentials. Each project needs its own activated
sending domain and provider credentials. Stripe accounts likewise retain their
own API keys, webhook secrets, payment-method activation and payout setup.

During a domain move, `MAILBOX_LEGACY_DOMAINS` can contain a comma-separated list
of previous domains accepted by the signed inbound endpoint. Outgoing messages
still use `MAILBOX_DOMAIN` or `DOMAIN`. Keep the old domain's MX/Worker route
active until mail addressed to it is no longer needed.

For incoming email, deploy `cloudflare-worker.js` as an Email Routing Worker.
Set `INBOUND_URL` to this project's backend origin plus `/mailroom/inbound/`.
Set a unique `INBOUND_EMAIL_SECRET` both on the Worker and this backend.
For the canonical local origin or public dev tunnel, use `/api/mailroom/inbound/`
(the proxy strips `/api`). Signed requests include timestamp, envelope and full MIME body; retries are
stored once per recipient, with a 10 MiB maximum. Configure the domain's routing
and MX records with the provider while preserving existing mail routes.

## Workers

Local development workers are declared in each project’s `COMPOSE_SERVICES`.
EDY and EliteCar run `mail-worker`; OldBook reuses its existing order worker.
On Railway or another host, use the same
backend image and project database/email variables with the start command
`python manage.py process_mail --loop`. Apply `python manage.py migrate mailroom`
first. The worker needs no public port. OldBook's existing order worker already
processes mailbox mail, so an extra production mail worker is unnecessary there.
Database row locks serialize concurrent deliveries; retries use backoff and keep
safe errors visible in admin. A crash after provider acceptance but before the DB
commit can duplicate a message; exactly-once delivery requires provider idempotency.

Installing the app does not configure DNS or activate provider accounts. Receiving
and sending each require per-project provider/domain activation.

## Unified admin workspace

Admin shows one Inbox entry for the mailbox. Its workspace contains Inbox,
Unread, Starred, Sent, Outbox, Drafts, Archive, All mail and recoverable Trash.
Incoming messages and outgoing replies share collapsible conversations. Standard
Message-ID, In-Reply-To and References headers connect replies, including replies
received before their parent. Headerless replies use matching subjects and both
correspondents as a fallback; independent new messages with the same subject stay
separate. Reply, Reply all and Forward share the composer. Reply-To is honored;
Reply all excludes the receiving address. Forwarding copies the message text;
download and reattach any original attachments that should accompany it.

Search covers subject, addresses, Cc and message text; results paginate by 30
conversations. Lists defer MIME payloads and full bodies until the reader opens.
Plain URLs and HTML buttons/links are clickable. The HTML reader reconstructs a
small formatting vocabulary, strips scripts, forms, CSS and embedded resources,
and does not load remote images or tracking pixels. Links open a separate tab with
noopener/noreferrer. Original MIME and attachments remain downloadable.

The composer supports multiple To/Cc/Bcc addresses, up to 10 attachments totaling
10 MiB, and explicitly saved drafts. Drafts belong to their author, remain editable,
and are excluded from delivery and other users' views. Sending a saved draft queues
that same record once. Bcc recipients are not included in the delivered MIME headers.
Attachments stay in the project database and its backups. Sending uses the existing
Django provider, with stable Message-ID and reply headers on retries.

Bulk read/unread/archive and retry use the corresponding model change permissions.
Star/trash changes that affect both incoming and outgoing mail require change access
to both. Trash is reversible; it pauses queued mail until restored. No automatic
purge is performed. Compose requires outgoing add permission. All writes require
CSRF protection. Opening a conversation marks it read through an explicit browser
POST; GET requests remain read-only. Outgoing-only users cannot see received mail,
even within a shared conversation. Legacy admin URLs remain permission-checked.

The interface follows Django admin's light/dark theme and adapts to small screens.
`/` focuses search; `c` composes; `r` replies; `j`/`k` navigate conversations and
Escape returns to the list outside input fields. Edited compose forms warn before
leaving; Save draft stores them on the server. Authored labels use Django template i18n;
message content is never sent to the web interface translation provider.

Migration `0004_mailbox_threads_and_drafts` groups existing mail while retaining
raw messages, delivery state and read/archive flags. Run `python manage.py migrate
mailroom` before starting updated web and mail-worker processes. Normal project
startup already runs migrations. This app is part of `SHARED_PATHS`, so new projects
and template sync receive the same functionality without sharing databases, domains,
credentials or mail-provider settings.

The conversation and folder interaction patterns were informed by the MIT-licensed
[Zero](https://github.com/Mail-0/Zero) email client. This implementation stays inside
the existing Django admin and does not require a second application or OAuth service.
