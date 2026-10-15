# Admin mailbox

This app is discovered automatically in each project. Inbox lives at
`/admin/mailroom/receivedemail/`; Compose and sent mail supports sending and replies.
Read/unread, archive, MIME and attachment downloads require mailbox permissions.
Bodies render as escaped text without remote HTML resources. Mail lives in each
project's own database and is included in its database backups.

## Configuration

`MAILBOX_DOMAIN` overrides this project's `DOMAIN`. The default alias is taken
from `DEFAULT_FROM_EMAIL` when its domain matches, otherwise it is `support`.
Existing messages and saved sender aliases are preserved. Credentials belong in
this project's root `.env` or deployment variables; never copy another project's
credentials. Django email backend/provider configuration stays in `backend/project.py`.
Existing project email integrations are unchanged. Console, dummy and file
backends leave messages queued instead of claiming actual delivery.

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
Unread, Sent, Outbox and Archive, a searchable message list, a reading pane,
attachments, compose and reply. Search covers subject, addresses and message text;
results are paginated in batches of 30 without loading full MIME payloads.
Bulk read/unread/archive controls and delivery retry require the corresponding
model change permissions. Compose requires outgoing add permission. All writes
require CSRF protection; viewing a message does not change it through a GET.
Outgoing-only users cannot see received mail. Legacy admin URLs remain available
for bookmarked forms but are hidden from navigation.

The interface follows Django admin's light/dark theme and adapts to small screens.
`/` focuses search; `c` opens compose outside input fields. Edited compose forms
warn before leaving the page; Discard explicitly abandons the current form.
Drafts are not stored automatically. Authored labels use Django template i18n;
message content is never sent to the web interface translation provider.
