# Report data contract

Fields the Power BI report (#28) must expose, per stakeholder request (Karim). Ported
forward from the POC (`profile/karim_req.txt`, folded into the POC's report contract) and
kept as the acceptance spec for the Users page + session drill.

## User page — one row per developer

| Field | Notes | Model source |
|---|---|---|
| Email | User identity | `dim_user[user_email]` |
| Last seen | Most recent activity timestamp | `dim_user[last_seen]` |
| CC version | Claude Code version last observed | `dim_user[last_cc_version]` |
| Total active days | Distinct days with activity | `[Active Days]` |
| Total sessions | Count of sessions | `[Total Sessions]` |
| Total input tokens | Sum | `[Total Input Tokens]` |
| Total output tokens | Sum | `[Total Output Tokens]` |
| Total commits | Sum | `[Total Commits]` |
| Total PRs | Sum | `[Total PRs]` |
| Avg active time per day | Mean active duration / active day | `[Avg Active Time per Day]` |
| Avg session duration | Mean session length | `[Avg Session Duration]` |
| Total lines of code | Sum (added + removed) | `[Total Lines of Code]` |

## Drill: user → session level

One row per session for the selected user:

| Field | Notes | Model source |
|---|---|---|
| Started at | Session start timestamp | `fact_session[started_at]` |
| Model | Model used | `fact_api_usage` → `dim_model` |
| Effort | Effort level | `fact_api_usage[effort]` |
| Skill | Skills invoked | `bridge_session_skill` |
| MCP | MCP servers used | `bridge_session_mcp` |
| Plugins | Plugins active | `bridge_session_plugin` |
| Agents | Subagents used | `bridge_session_agent` |
| Hooks | Hooks fired | `bridge_session_hook` |
