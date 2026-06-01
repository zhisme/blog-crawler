# blog-comments-tracker

Daily crawler for [zhisme.com](https://zhisme.com) Disqus comment counts.
Notifies via Telegram when counts change.

## Why

Disqus does not notify the forum owner when a new comment is posted on a
thread. This crawler fills the gap: hits the public Disqus API once a day,
diffs against the previous run committed in git, and pings a Telegram bot
on any new threads or increased post counts.

## How it works

1. GitHub Actions cron runs `scripts/crawl.rb` daily.
2. Script pages through `forums/listThreads.json` for the configured forum
   shortname.
3. Builds a sorted CSV at `data/comments.csv` (slug, title, link, posts,
   checked_at).
4. Diffs against the previous CSV (committed by the prior run).
5. On any new threads or post-count increases, sends one plain-text Telegram
   message.
6. Commits the updated CSV back to the repo so the next run has a baseline.

Stdlib only — no `Gemfile`, no bundler, no gems. Just `net/http`, `json`,
`csv`, `uri`, `time`.

## Setup

1. Fork or clone this repo.
2. Get a Disqus public API key from <https://disqus.com/api/applications/>.
   The key is read-only and safe to use in CI secrets.
3. Create a Telegram bot via [@BotFather](https://t.me/BotFather) and save
   the token it prints.
4. Get your chat ID:
   - Send any message to your new bot from your account.
   - Fetch `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser.
   - Find `message.chat.id` in the JSON.
5. In the repo, go to **Settings → Secrets and variables → Actions** and add
   three repository secrets:
   - `DISQUS_API_KEY`
   - `TELEGRAM_BOT_TOKEN`
   - `TELEGRAM_CHAT_ID`
6. Adjust the cron in `.github/workflows/crawl.yml` for your local timezone.
   Current schedule is `0 8 * * *` (08:00 UTC).
   - CET = UTC+1, CEST = UTC+2, MSK = UTC+3.
7. Trigger the workflow manually once (**Actions → crawl → Run workflow**)
   to seed `data/comments.csv`. The first run writes the CSV, skips the
   Telegram notification, and commits the file. Subsequent runs diff
   against it.

The default forum shortname is `zhisme`. Override via the `DISQUS_FORUM`
env var if needed.

## File layout

```
.
├── .github/workflows/crawl.yml   # daily cron + manual dispatch
├── scripts/crawl.rb              # single-file crawler
├── data/comments.csv             # created on first run, committed by CI
├── README.md
├── .gitignore
└── LICENSE
```

`data/comments.csv` is intentionally absent from the initial commit so the
first CI run seeds it without sending a notification (otherwise the bot
would ping for every existing thread).

## Local testing

```sh
DISQUS_API_KEY=... ruby scripts/crawl.rb
```

Leave `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` unset to skip the notify
step; the script will write the CSV and print the diff summary to stdout.

To force a notification path locally, set both Telegram env vars and
temporarily edit or delete `data/comments.csv` between runs to simulate a
change.

## Edge cases

- **First run**: no CSV present → seed and skip notify.
- **Thread deleted on Disqus**: row disappears from new CSV, no notification.
- **Long messages**: Telegram caps at 4096 bytes. The script trims the
  delta list and appends `...and N more` if needed.
- **Disqus rate limit**: 1000 req/hour. One daily run does 1–2 requests.

## License

MIT. See `LICENSE`.
