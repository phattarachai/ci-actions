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

## Releasing

```bash
bash tests/telegram-notify.sh && bash tests/changed-files.sh
git tag v1.x.y && git tag -f v1 && git push origin v1.x.y && git push -f origin v1
```

A breaking input change is a new major (`v2`); projects move to it one by one.
