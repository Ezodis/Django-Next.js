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

For incoming email, deploy `cloudflare-worker.js` as an Email Routing Worker.
Set `INBOUND_URL` to this project's backend origin plus `/mailroom/inbound/`.
Set a unique `INBOUND_EMAIL_SECRET` both on the Worker and this backend.
For the canonical local origin or public dev tunnel, use `/api/mailroom/inbound/`
(the proxy strips `/api`). Signed requests include timestamp, envelope and full MIME body; retries are
stored once per recipient, with a 10 MiB maximum. Configure the domain's routing
and MX records with the provider while preserving existing mail routes.

## Workers

Local development starts `mail-worker`. On Railway or another host, use the same
backend image and project database/email variables with the start command
`python manage.py process_mail --loop`. Apply `python manage.py migrate mailroom`
first. The worker needs no public port. OldBook's existing order worker already
processes mailbox mail, so an extra production mail worker is unnecessary there.
Database row locks serialize concurrent deliveries; retries use backoff and keep
safe errors visible in admin. A crash after provider acceptance but before the DB
commit can duplicate a message; exactly-once delivery requires provider idempotency.

Installing the app does not configure DNS or activate provider accounts. Receiving
and sending each require per-project provider/domain activation.
