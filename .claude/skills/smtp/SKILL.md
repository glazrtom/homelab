---
name: smtp
description: This skill should be used when adding, wiring, rotating, or debugging outbound email (SMTP) for an app in this homelab repo. Triggers on "smtp", "email", "mail", "send mail", "Gmail app password", "SMTP_PWD", "SMTP_PASSWORD", "mailer".
---

# SMTP

All apps send through one Gmail account, `glazrtom.homelab@gmail.com`, at
`smtp.gmail.com:587` with STARTTLS (From address = the same account). **Every app has its
own Gmail app password**, so one can be revoked without touching the others. There is no
shared or reflected SMTP secret.

## Where each app keeps its password

The password is a key in the app's own sealed Secret, declared in its
`generate-secret.sh` as `resolve KEY --prompt '<App> Gmail app password' --unsafe-force
--follow-up '...'` (`--unsafe-force` so a blanket `--force` never prompts for it; only
`--force-key KEY` does). The non-secret settings (host, port, username, from) live in the
chart's `values.yaml`.

| App | Secret / key | Non-secret settings |
|---|---|---|
| rallly | `rallly` / `SMTP_PWD` | `rallly.smtp.*` in `rallly/values.yaml` |
| dawarich | `dawarich-secrets` / `SMTP_PASSWORD` | `smtp:` in `dawarich/values.yaml`, wired in `dawarich/templates/_env.tpl` |

Each app's `generate-secret.sh` also has a `prompts` entry in
`ansible/roles/secrets/defaults/main.yml`, so `playbooks/secrets.yml` asks for it when no
local plaintext exists. Without the local plaintext or the live Secret the value cannot
be recovered (see `doomsday`); a new app password must be minted.

## Adding SMTP to a new app

1. Google account → Security → App passwords: create one named after the app.
2. In the app's `generate-secret.sh` add the `resolve ... --prompt ... --unsafe-force`
   line; add a matching `prompts` entry to its `secrets_items` item in
   `ansible/roles/secrets/defaults/main.yml`.
3. Put host/port/username/from in the chart's `values.yaml`; map them to the app's env vars
   (or chart values) and read the password via `secretKeyRef`.
4. Run the generate script (the user does; it prompts and seals), then deploy.

Dawarich's env names (read from the app's `lib/smtp_config.rb`): `SMTP_SERVER`, `SMTP_PORT`,
`SMTP_DOMAIN`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, plus `DOMAIN` (host for links
in mail; protocol is always https). Mail is enabled when `SMTP_SERVER` is set. Sidekiq is the
component that actually delivers, so both web and sidekiq carry the env.

## Rotating

`<app>/generate-secret.sh --force-key <KEY>`, enter the new app password, commit the
resealed file, then restart the app and revoke the old app password in Google.

## Testing

Dawarich, from the sidekiq pod:
`bin/rails runner 'p DawarichSettings.email_configured?; p ActionMailer::Base.smtp_settings.except(:password)'`,
then a test send with
`ActionMailer::Base.mail(to: "...", from: ENV["SMTP_FROM"], subject: "test", body: "x").deliver_now`.
`535 5.7.8 Username and Password not accepted` means the app password is wrong or revoked.
