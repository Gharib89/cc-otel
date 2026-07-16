#!/usr/bin/env node
// cc-otel statusline wrapper (ADR-0003: minimal rate-limit contract).
//
// Reads the JSON Claude Code pipes on every statusline refresh, forwards it to
// the user's own statusline command so the in-app bar is unchanged, and in
// parallel pushes the embedded `rate_limits` block as an OTLP/JSON gauge to the
// central OpenTelemetry Collector. Official Claude Code telemetry covers every
// other adoption KPI; the one thing it cannot provide is subscription
// rate-limit utilization, which exists only in this statusline payload.
//
// Metrics emitted (exactly two gauges, OTLP/JSON):
//   claude_code.usage.utilization       — rate_limits.*.used_percentage (% 0-100)
//   claude_code.usage.reset_in_seconds  — seconds until rate_limits.*.resets_at
// Datapoint attribute: window (5h | 7d | 7d_sonnet | 7d_opus | ...).
// Resource attributes: service.name=claude-code, user.email, user.account_id,
//   session.id (identity omitted when unknown → rows resolve server-side by
//   session.id join).
//
// Identity is read from `.claude.json` `oauthAccount` (emailAddress lowercased +
// accountUuid) — the same values Claude Code's native exporter stamps on rows,
// so wrapper and official rows group identically. Fallback: CLAUDE_USER_EMAIL
// env; else omit. No git-config sniffing, no username@domain fabrication.
//
// Throttle: at most one push per 5 minutes per machine via a state file
// (rate limits are account-level; per-session emission adds rows without
// information). A payload with no `rate_limits` block triggers no HTTP call.
//
// Failure posture: silent. Statusline runs on every refresh; throwing here
// breaks the user's bar. Errors are logged to STATUSLINE_DEBUG_LOG when set.
// A hard watchdog guarantees we exit within HARD_TIMEOUT_MS regardless of OTLP
// latency.
//
// OTLP endpoint + bearer are REUSED from the fleet telemetry config install.ps1
// bakes — the wrapper re-bakes no secret of its own. Source order: process env
// first, then the installer's managed-settings.json `env` block sitting beside
// this file. The file fallback exists because Claude Code stops propagating
// OTEL_* env to the statusLine subprocess (v2.1.128+), so inherited env alone is
// unreliable; managed-settings.json is the same baked config, always on disk.
//   OTEL_EXPORTER_OTLP_ENDPOINT  base OTLP URL; the metrics path /v1/metrics is appended
//   OTEL_EXPORTER_OTLP_HEADERS   "k=v,k=v" headers, incl. Authorization=Bearer <token>
// The STATUSLINE_* overrides below win when set (used by the test suite):
//   STATUSLINE_OTLP_ENDPOINT   full OTLP HTTP /v1/metrics URL (overrides the OTEL_* pair)
//   STATUSLINE_OTLP_HEADERS    extra headers, "k=v,k=v" form (overrides OTEL_EXPORTER_OTLP_HEADERS)
// Other env:
//   STATUSLINE_OTLP_TIMEOUT_MS HTTP request timeout in ms (default: 5000;
//                              hard watchdog ends the process at 10s regardless)
//   STATUSLINE_THROTTLE_FILE   per-machine throttle state file (default: <tmp>/cc-otel-statusline-throttle)
//   STATUSLINE_DEBUG_LOG       if set, append per-invocation diagnostics here
//   CLAUDE_USER_EMAIL          fallback OAuth email when .claude.json has no oauthAccount
//   CLAUDE_CONFIG_DIR          Claude Code config dir override (locates settings + .claude.json)

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

// Resolve the Claude config dir. Honor CLAUDE_CONFIG_DIR (Claude Code's own
// override) before falling back to <home>/.claude.
function claudeConfigDir() {
  const override = process.env.CLAUDE_CONFIG_DIR;
  if (override && override.trim()) return override.trim();
  return path.join(os.homedir(), ".claude");
}

// Locate `.claude.json`. When CLAUDE_CONFIG_DIR is set, Claude Code stores it
// directly inside that dir; otherwise it lives at <home>/.claude.json.
function claudeJsonPath(env = process.env) {
  const override = env.CLAUDE_CONFIG_DIR;
  return override && override.trim()
    ? path.join(override.trim(), ".claude.json")
    : path.join(os.homedir(), ".claude.json");
}

// Read the local OAuth identity. Source of truth is `.claude.json`
// `oauthAccount` (emailAddress lowercased + accountUuid) — the same values
// Claude Code's native exporter stamps on rows. Fallback email: CLAUDE_USER_EMAIL.
// Missing pieces come back as null so their labels are simply omitted.
export function readIdentityFrom({ env = process.env } = {}) {
  let email = null;
  let accountId = null;
  try {
    const oauth = JSON.parse(fs.readFileSync(claudeJsonPath(env), "utf8"))?.oauthAccount;
    if (oauth && typeof oauth === "object") {
      if (typeof oauth.emailAddress === "string" && oauth.emailAddress.trim())
        email = oauth.emailAddress.trim().toLowerCase();
      if (typeof oauth.accountUuid === "string" && oauth.accountUuid.trim())
        accountId = oauth.accountUuid.trim();
    }
  } catch {
    // Missing/unreadable/not JSON — fall through to env fallback.
  }
  if (!email && typeof env.CLAUDE_USER_EMAIL === "string" && env.CLAUDE_USER_EMAIL.trim())
    email = env.CLAUDE_USER_EMAIL.trim().toLowerCase();
  return { email, accountId };
}

// Marker that identifies *this* wrapper inside a statusLine.command string, so
// we never forward to ourselves (infinite spawn loop). The in-repo source and
// the deployed copy share the same name: cc-otel-wrapper.mjs.
const SELF_MARKER = "cc-otel-wrapper";

// Read statusLine.command out of a Claude Code settings JSON file. Returns the
// trimmed command string, or null if the file is missing/unreadable/not JSON
// or has no statusLine.command. Tolerant by design — statusline must never throw.
function readStatusLineCommand(file) {
  try {
    const cmd = JSON.parse(fs.readFileSync(file, "utf8"))?.statusLine?.command;
    return typeof cmd === "string" && cmd.trim() ? cmd.trim() : null;
  } catch {
    return null;
  }
}

function pointsAtSelf(cmd) {
  if (cmd.includes(SELF_MARKER)) return true;
  const self = process.argv[1] ? path.basename(process.argv[1]) : "";
  return self ? cmd.includes(self) : false;
}

const quoteIfSpace = (s) => (/\s/.test(s) ? `"${s}"` : s);

// Map a script extension to the interpreter that runs it.
const RUNNERS = {
  ".js": "node",
  ".mjs": "node",
  ".cjs": "node",
  ".py": "python3",
  ".sh": "bash",
  ".ps1": "powershell -NoProfile -File",
};

// A statusLine.command that is just a path to a script (e.g.
// "C:/Users/x/.claude/statusline-command.js" with no interpreter) must be run
// via its interpreter. Handing a bare ".js"/".ps1" path to the Windows shell
// triggers the "how do you want to open this file?" association dialog instead
// of executing it. If the command is a single existing script file, prepend
// the right runner; otherwise leave it untouched (it's a real command line).
function normalizeInnerCmd(raw) {
  const unquoted = raw.replace(/^"(.*)"$/s, "$1");
  try {
    if (fs.existsSync(unquoted) && fs.statSync(unquoted).isFile()) {
      const runner = RUNNERS[path.extname(unquoted).toLowerCase()];
      if (runner) return `${runner} ${quoteIfSpace(unquoted)}`;
    }
  } catch {}
  return raw;
}

// Expand ~ and ${CLAUDE_CONFIG_DIR}/${HOME}/$HOME inside a command string.
// Claude Code does NOT shell-expand settings env values, and on Windows the
// spawn shell (cmd.exe) does not expand ~, so we do it here. This lets a single
// captured command like `node ~/.claude/statusline-command.js` resolve per-user.
function expandPath(s, configDir = claudeConfigDir()) {
  return s
    .replace(/\$\{CLAUDE_CONFIG_DIR\}/g, configDir)
    .replace(/\$\{HOME\}|\$HOME\b/g, os.homedir())
    .replace(/(^|\s)~(?=[/\\])/g, `$1${os.homedir()}`);
}

// Resolve the inner statusline command — the one the user actually configured,
// which our managed-settings wrapper sits in front of. Resolved from the
// settings.json chain only, mirroring Claude Code's own precedence:
//   project local -> project -> user, skipping any entry pointing at us.
// Nothing found → null (caller outputs an empty bar). No file-candidate scan,
// no built-in fallback renderer. <config> = CLAUDE_CONFIG_DIR or <home>/.claude.
export function resolveInnerCmdFrom({
  configDir = claudeConfigDir(),
  cwd = process.cwd(),
} = {}) {
  const settingsFiles = [
    path.join(cwd, ".claude", "settings.local.json"),
    path.join(cwd, ".claude", "settings.json"),
    path.join(configDir, "settings.json"),
  ];
  for (const f of settingsFiles) {
    const cmd = readStatusLineCommand(f);
    if (cmd && !pointsAtSelf(cmd)) return normalizeInnerCmd(expandPath(cmd, configDir));
  }
  return null;
}

let _cachedInner;
function resolveInnerCmd() {
  if (_cachedInner !== undefined) return _cachedInner;
  return (_cachedInner = resolveInnerCmdFrom());
}

// The installer drops managed-settings.json beside this wrapper in InstallRoot;
// its `env` block is the authoritative fleet OTLP target. We locate it from this
// file's own directory so it resolves regardless of the working dir or how the
// statusLine subprocess was spawned.
const WRAPPER_DIR = path.dirname(fileURLToPath(import.meta.url));

// Read the OTEL_* telemetry env the installer baked into managed-settings.json.
// Claude Code strips OTEL_* from the statusLine subprocess (v2.1.128+), so the
// inherited-env path is unreliable; this file is the fallback source of the
// endpoint/token. Tolerant by design (statusline must never throw): a missing /
// unreadable / non-JSON file, or one with no `env` object, yields {}.
export function readManagedSettingsEnv(dir = WRAPPER_DIR) {
  try {
    const env = JSON.parse(fs.readFileSync(path.join(dir, "managed-settings.json"), "utf8"))?.env;
    return env && typeof env === "object" ? env : {};
  } catch {
    return {};
  }
}

// Read once per process: statusline fires on every refresh, and the baked file
// does not change under a running install.
const MANAGED_SETTINGS_ENV = readManagedSettingsEnv();

// OTLP endpoint. STATUSLINE_OTLP_ENDPOINT (a full /v1/metrics URL) wins when set.
// Otherwise use the base OTEL_EXPORTER_OTLP_ENDPOINT — from process env if Claude
// Code passed it through, else from managed-settings.json — and append the
// metrics signal path. Last resort is the local default.
export function resolveEndpoint(env = process.env, managed = MANAGED_SETTINGS_ENV) {
  const override = env.STATUSLINE_OTLP_ENDPOINT;
  if (override && override.trim()) return override.trim();
  const base = env.OTEL_EXPORTER_OTLP_ENDPOINT || managed.OTEL_EXPORTER_OTLP_ENDPOINT;
  if (base && base.trim()) return base.trim().replace(/\/+$/, "") + "/v1/metrics";
  return "http://localhost:4318/v1/metrics";
}

// OTLP headers (carry Authorization=Bearer <fleet-token>). STATUSLINE_OTLP_HEADERS
// wins; otherwise OTEL_EXPORTER_OTLP_HEADERS from process env, else from
// managed-settings.json.
export function resolveHeaders(env = process.env, managed = MANAGED_SETTINGS_ENV) {
  const override = env.STATUSLINE_OTLP_HEADERS;
  const raw =
    override && override.trim()
      ? override
      : env.OTEL_EXPORTER_OTLP_HEADERS || managed.OTEL_EXPORTER_OTLP_HEADERS;
  return parseKv(raw);
}

const OTLP_ENDPOINT = resolveEndpoint();
// Guard against a misconfigured value: Number("") is 0 and Number("abc") is NaN,
// either of which would abort the request instantly. Fall back to the default.
const OTLP_TIMEOUT_MS = (() => {
  const n = Number(process.env.STATUSLINE_OTLP_TIMEOUT_MS);
  return Number.isFinite(n) && n > 0 ? n : 5000;
})();
const OTLP_HEADERS = resolveHeaders();
const DEBUG_LOG = process.env.STATUSLINE_DEBUG_LOG;
const THROTTLE_FILE =
  process.env.STATUSLINE_THROTTLE_FILE ??
  path.join(os.tmpdir(), "cc-otel-statusline-throttle");

const HARD_TIMEOUT_MS = 10_000;
const THROTTLE_WINDOW_MS = 5 * 60_000;
const SCOPE_NAME = "cc-otel.statusline";
const METRIC_NAME = "claude_code.usage.utilization";
const RESET_METRIC_NAME = "claude_code.usage.reset_in_seconds";

const debug = (msg) => {
  if (!DEBUG_LOG) return;
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`, { flag: "a" });
  } catch {
    // Cannot debug-log the debug-log failure. Stay silent.
  }
};

// One push per window per machine. Reads the last-push timestamp from the state
// file; if it is within windowMs of now, block. Otherwise record now and allow.
// Best-effort: an unreadable/unwritable state file never blocks the push.
export function throttleAllows({ stateFile, nowMs, windowMs = THROTTLE_WINDOW_MS }) {
  try {
    const last = Number(fs.readFileSync(stateFile, "utf8").trim());
    if (Number.isFinite(last) && nowMs - last < windowMs) return false;
  } catch {
    // No prior state (or unreadable) — treat as allowed.
  }
  try {
    fs.writeFileSync(stateFile, String(nowMs));
  } catch {
    // Cannot persist — allow this push; we just can't throttle the next one.
  }
  return true;
}

export function buildOtlpBody(payload, nowMs = Date.now(), identity) {
  if (!payload || typeof payload !== "object") return null;
  const rl = payload.rate_limits;
  if (!rl || typeof rl !== "object") return null;

  const timeUnixNano = String(BigInt(nowMs) * 1_000_000n);
  const nowSec = Math.floor(nowMs / 1000);
  const sessionId = typeof payload.session_id === "string" ? payload.session_id : null;

  const utilPoints = [];
  const resetPoints = [];
  for (const [key, win] of Object.entries(rl)) {
    if (!win || typeof win !== "object") continue;
    const window =
      key === "five_hour"
        ? "5h"
        : key.startsWith("seven_day")
          ? "7d" + key.slice("seven_day".length)
          : key;
    const windowAttrs = [attr("window", window)];
    const pct = pickGaugeValue(win);
    if (pct !== null) {
      utilPoints.push({ attributes: windowAttrs, timeUnixNano, asDouble: pct });
    }
    const resetsAt = typeof win.resets_at === "number" ? win.resets_at : null;
    if (resetsAt !== null) {
      resetPoints.push({
        attributes: windowAttrs,
        timeUnixNano,
        asDouble: Math.max(0, resetsAt - nowSec),
      });
    }
  }
  if (utilPoints.length === 0 && resetPoints.length === 0) return null;

  const metrics = [];
  if (utilPoints.length > 0) {
    metrics.push({
      name: METRIC_NAME,
      description: "Claude Code rate-limit utilization (percent, 0-100, Anthropic-computed)",
      gauge: { dataPoints: utilPoints },
    });
  }
  if (resetPoints.length > 0) {
    metrics.push({
      name: RESET_METRIC_NAME,
      unit: "s",
      description: "Seconds until the rate-limit window resets (Anthropic-supplied resets_at)",
      gauge: { dataPoints: resetPoints },
    });
  }

  // Resolve identity only now that we know we're emitting — avoids parsing
  // .claude.json on every statusline refresh that carries no rate_limits.
  const id = identity ?? readIdentityFrom();
  const resourceAttrs = [attr("service.name", "claude-code")];
  if (id?.email) resourceAttrs.push(attr("user.email", id.email));
  if (id?.accountId) resourceAttrs.push(attr("user.account_id", id.accountId));
  if (sessionId) resourceAttrs.push(attr("session.id", sessionId));

  return {
    resourceMetrics: [
      {
        resource: { attributes: resourceAttrs },
        scopeMetrics: [{ scope: { name: SCOPE_NAME }, metrics }],
      },
    ],
  };
}

function attr(key, value) {
  return { key, value: { stringValue: String(value) } };
}

function pickGaugeValue(win) {
  // Statusline payload uses `used_percentage`. Older variants may use
  // `utilization`. Accept either; reject non-numeric.
  const raw =
    typeof win.used_percentage === "number"
      ? win.used_percentage
      : typeof win.utilization === "number"
        ? win.utilization
        : null;
  if (raw === null || Number.isNaN(raw)) return null;
  return raw;
}

function parseKv(raw) {
  if (!raw) return {};
  const out = {};
  for (const pair of raw.split(",")) {
    const idx = pair.indexOf("=");
    if (idx <= 0) continue;
    const k = pair.slice(0, idx).trim();
    const v = pair.slice(idx + 1).trim();
    if (k) out[k] = v;
  }
  return out;
}

export async function postOtlp(body, endpoint = OTLP_ENDPOINT, timeoutMs = OTLP_TIMEOUT_MS) {
  if (!body) return { skipped: true };
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...OTLP_HEADERS },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    return { status: res.status, ok: res.ok };
  } finally {
    clearTimeout(t);
  }
}

async function pushBestEffort(raw) {
  try {
    const payload = JSON.parse(raw);
    if (DEBUG_LOG) {
      debug(`payload keys: ${Object.keys(payload).join(",")}`);
      const rl = payload?.rate_limits;
      if (rl && typeof rl === "object") {
        for (const [k, v] of Object.entries(rl)) {
          if (v && typeof v === "object") {
            debug(`  rate_limits.${k}: ${JSON.stringify(v)}`);
          }
        }
      }
    }
    const body = buildOtlpBody(payload);
    if (!body) {
      debug("no rate_limits in payload — skip push");
      return;
    }
    if (!throttleAllows({ stateFile: THROTTLE_FILE, nowMs: Date.now() })) {
      debug("throttled — under 5 min since last push");
      return;
    }
    const { status, ok, skipped } = await postOtlp(body);
    const metricsArr = body.resourceMetrics[0].scopeMetrics[0].metrics;
    const totalPoints = metricsArr.reduce((n, m) => n + (m.gauge?.dataPoints?.length ?? 0), 0);
    if (skipped) debug("post skipped");
    else if (!ok) debug(`otlp post failed: status=${status}`);
    else debug(`otlp post ok: status=${status} metrics=${metricsArr.length} points=${totalPoints}`);
  } catch (err) {
    debug(`pushBestEffort threw: ${err?.message ?? err}`);
  }
}

function forwardToInner(stdinBuf) {
  const innerCmd = resolveInnerCmd();
  debug(`resolved inner cmd: ${innerCmd ?? "(none — empty bar)"}`);
  // No user statusline configured → output nothing (matches the user's real
  // experience of an empty bar). Never echo the raw JSON payload.
  if (!innerCmd) return Promise.resolve();
  return new Promise((resolve) => {
    // Run through a shell so multi-arg / quoted commands (npx ccusage, oh-my-posh,
    // paths with spaces) execute exactly as Claude Code would run statusLine.command.
    const child = spawn(innerCmd, { shell: true, stdio: ["pipe", "inherit", "inherit"] });
    let resolved = false;
    const done = () => {
      if (resolved) return;
      resolved = true;
      resolve();
    };
    child.on("error", (e) => {
      // Inner command couldn't launch — leave the bar empty rather than echoing
      // JSON. Silent posture; the user's own command is the only renderer.
      debug(`inner cmd error: ${e?.message ?? e}`);
      done();
    });
    child.on("close", done);
    child.stdin.on("error", () => {});
    try {
      child.stdin.write(stdinBuf);
      child.stdin.end();
    } catch (e) {
      debug(`inner cmd write error: ${e?.message ?? e}`);
      done();
    }
  });
}

async function main() {
  let stdinBuf = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) stdinBuf += chunk;

  // Hard watchdog so statusline never hangs the user's bar.
  const killer = setTimeout(() => process.exit(0), HARD_TIMEOUT_MS);
  killer.unref?.();

  // Forward + push run in parallel; both swallow their own failures.
  await Promise.allSettled([forwardToInner(stdinBuf), pushBestEffort(stdinBuf)]);
  clearTimeout(killer);
}

// Allow this file to be imported by tests without auto-running main().
const isMainModule = (() => {
  try {
    return import.meta.url === pathToFileURL(process.argv[1]).href;
  } catch {
    return false;
  }
})();

if (isMainModule) {
  main().catch((err) => {
    debug(`main threw: ${err?.message ?? err}`);
    process.exit(0);
  });
}
