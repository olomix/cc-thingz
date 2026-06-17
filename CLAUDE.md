# Repository Conventions

## Public repository — no personal data

This repository is **public**. Personal data must never be committed to it,
neither in tracked files nor in git history (commit metadata is exempt only for
authorship attribution that is intentionally public).

This is a hard rule for both **writing code** and **reviewing changes**:

* Do **not** introduce real personal data: email addresses, phone numbers,
  home/work paths containing usernames (e.g. `/Users/<name>/...`), real
  notebook/folder names, private hostnames, or any other identifying details.
* Use placeholders or generic examples (`/path/to/notes`, `user@example.com`)
  in code, tests, and documentation.
* Author/copyright attribution (the project author's name in `LICENSE`,
  `plugin.json`, `marketplace.json`) is intentional and allowed.
* When reviewing a diff, flag any newly added personal data as a blocker.
