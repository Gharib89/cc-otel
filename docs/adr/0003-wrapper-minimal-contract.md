# Statusline wrapper emits only rate-limit gauges, with identity read from oauthAccount

Claude Code's official telemetry (enhanced beta) covers every adoption KPI — tokens, LOC, commits, PRs, active time, model, effort, skills, MCPs, subagents, hooks — except subscription rate-limit utilization, which exists only in the statusline JSON. The wrapper therefore emits exactly two gauges (`claude_code.usage.utilization`, `claude_code.usage.reset_in_seconds`) with three resource-level labels (`user.email`, `user.account_id`, `session.id`) plus a `window` attribute on each datapoint, throttled to one push per 5 minutes per machine (limits are account-level, so per-session emission adds rows without information).

Identity is read from `.claude.json` `oauthAccount` (`emailAddress` lowercased + `accountUuid`) — the same values Claude Code's native exporter stamps on rows, so wrapper and official rows group identically. The POC's earlier chain (git config → `username@itworx.com` fabrication) produced wrong emails and is deliberately removed; fallback is `CLAUDE_USER_EMAIL` env, else omit the label and resolve server-side by `session.id`/`account_id` join.

The wrapper's statusline duty is forward-only: resolve the user's own statusline from settings.json; if none, output nothing (empty bar, matching the user's real experience). The built-in fallback renderer was removed.
