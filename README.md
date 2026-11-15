# ci-actions

Composite GitHub Actions shared by every Phattarachai Artisan project. A fix here ships to the whole
fleet as one release: projects pin the moving major tag (`@v1`), so they pick it up on their next run.

Only the parts that are identical across projects live here. Test, deploy and environment-specific
jobs stay in each project's own workflow.

## telegram-notify

Sends the run's outcome to Telegram, then fails the job if the run failed, so a failed run never
shows a green notify beside a red deploy. Missing secrets skip the message and exit 0.

```yaml
  notify:
    needs: [test, deploy]        # any jobs, any names
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: phattarachai/ci-actions/telegram-notify@v1
        with:
          token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
          needs: ${{ toJSON(needs) }}
```

Every needed job `success` or `skipped` sends `✅ app — test · deploy passed`. Anything else sends
`❌ app — deploy failure`, naming the first job that did not pass. The second line is the branch and
the commit subject, the third the run URL. A send Telegram rejects is a warning on the run, not a
red job.

## changed-files

Lists a pull request's added, copied, modified and renamed files that match some patterns, into a
file. File names never pass through `${{ }}`, so a crafted name cannot inject shell. Needs
`fetch-depth: 0` on checkout.

```yaml
      - id: php
        uses: phattarachai/ci-actions/changed-files@v1
        with:
          patterns: '*.php'
          exclude: |
            _ide_helper*.php
            .phpstorm.meta.php

      - name: Pint
        if: steps.php.outputs.count != '0'
        env:
          LIST: ${{ steps.php.outputs.list }}
        run: tr '\n' '\0' < "$LIST" | xargs -0 vendor/bin/pint --test
```

Patterns are shell `case` patterns, one per line; `*` also matches `/`, so `*.php` matches any depth.

## laravel-migrate

A deploy's migrations behind a rollback point: when migrations are pending (or `migrate:status`
itself fails), it takes a `snapshot:create --compress` first, then runs `migrate --force`. Nothing
pending skips the snapshot. A failed snapshot stops the step before any migration runs.

```yaml
      - uses: phattarachai/ci-actions/laravel-migrate@v1
        with:
          working-directory: /var/www/app     # required: job defaults do not reach into an action
          # artisan: sudo php artisan         # default: php artisan
          # compress: 'false'                 # default: 'true'
          # on-snapshot-failure: continue     # default: stop
```

Outputs `has-pending` (`true`/`false`) and `snapshot` (`created`/`skipped`/`failed`). Needs
`spatie/laravel-db-snapshots` in the app.

### Migrating as the owner role

Production databases split into two roles: the app's runtime role (DML only, password in `.env`) and
an `<app>_owner` role that owns the schema and runs DDL. The owner has **no password**: it logs in
only over the unix socket, through Postgres peer auth (a `pg_ident` map from the deploy OS user) or
MySQL `auth_socket`. Nothing with a password can grant DDL, so a leaked `.env` cannot alter or drop
the schema.

`db-username` runs `migrate:status`, `snapshot:create` and `migrate` as that role, with
`DB_PASSWORD` empty; Laravel's process env beats `.env`. The override is scoped to this step:
nothing after it, and nothing the app serves, sees it.

```yaml
      - run: php artisan optimize:clear          # a cached config ignores env
        working-directory: /var/www/app

      - uses: phattarachai/ci-actions/laravel-migrate@v1     # pgsql, peer auth
        with:
          working-directory: /var/www/app
          db-username: myapp_owner
          db-host: /var/run/postgresql          # the socket directory

      - run: php artisan optimize
        working-directory: /var/www/app
```

```yaml
      - uses: phattarachai/ci-actions/laravel-migrate@v1     # MySQL, auth_socket
        with:
          working-directory: /var/www/app
          db-username: myapp_owner
          db-socket: /run/mysqld/mysqld.sock
```

| Input | Exports for the three calls |
| --- | --- |
| `db-username` | `DB_USERNAME`, and `DB_PASSWORD=''` |
| `db-host` | `DB_HOST` (pgsql: the socket directory) |
| `db-socket` | `DB_SOCKET` (MySQL) |
| `extra-env` | one `KEY=VALUE` per line, for a second connection migrations touch |

```yaml
          extra-env: |
            LOG_DB_USERNAME=myapp_log_owner
            LOG_DB_HOST=/var/run/postgresql
            LOG_DB_PASSWORD=
```

`extra-env` values are literal: no quotes, no `$` expansion, empty allowed. It is parsed, never
eval'd, and the log names only its keys. Blank lines and `#` comments are skipped.

**The migrate step must sit between `optimize:clear` and `optimize`.** With
`bootstrap/cache/config.php` present, Laravel reads neither `.env` nor the process env, so the
override would be silently dropped and migrations would run as the app role (and fail on DDL, or
worse, succeed with the wrong owner). Any override input with a cached config fails the step with
an `::error::` before artisan runs; without override inputs a cached config is only a warning.
The step logs which DB user it runs as, never a password.

A plain step-level `env:` on the `uses:` step also works, because a composite action's steps
inherit it, but it skips that guard, so prefer the inputs:

```yaml
      - uses: phattarachai/ci-actions/laravel-migrate@v1
        env:
          DB_USERNAME: myapp_owner
          DB_PASSWORD: ''
          DB_HOST: /var/run/postgresql
        with:
          working-directory: /var/www/app
```

Run artisan as the deploy user (the default `php artisan`): peer auth maps that OS user, and a
`sudo` prefix drops the exported env through `env_reset`, which the step warns about.

## Releasing

```bash
bash tests/telegram-notify.sh && bash tests/changed-files.sh && bash tests/laravel-migrate.sh
git tag v1.x.y && git tag -f v1 && git push origin v1.x.y && git push -f origin v1
```

A breaking input change is a new major (`v2`); projects move to it one by one.
