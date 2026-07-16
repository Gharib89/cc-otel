// Tests for cc-otel-wrapper.mjs — minimal rate-limit contract (ADR-0003).
//
// Seams asserted (external behavior, no internals):
//   1. buildOtlpBody   — statusline JSON + identity → OTLP/JSON body (two gauges).
//   2. readIdentityFrom — .claude.json oauthAccount / CLAUDE_USER_EMAIL → identity.
//   3. resolveInnerCmdFrom — settings.json chain → inner statusline command / null.
//   4. throttleAllows  — state-file 5-minute throttle.
//   5. resolveEndpoint/resolveHeaders — OTLP target from OTEL_* env, STATUSLINE_* override.
//   6. End-to-end stdin contract — spawn the wrapper, assert forwarding, OTLP
//      push, throttle, and silent-failure posture.
//
// node:test (built-in) + node:assert/strict. No external deps.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import { once } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";

import {
  buildOtlpBody,
  resolveInnerCmdFrom,
  readIdentityFrom,
  throttleAllows,
  resolveEndpoint,
  resolveHeaders,
  readManagedSettingsEnv,
} from "./cc-otel-wrapper.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WRAPPER = path.join(__dirname, "cc-otel-wrapper.mjs");

// ---------------------------------------------------------------------------
// Fixtures / helpers
// ---------------------------------------------------------------------------

function tmpDir(prefix = "cc-otel-") {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}
function tmpConfigDir() {
  const dir = tmpDir("cc-otel-cfg-");
  fs.mkdirSync(path.join(dir, ".claude"), { recursive: true });
  return dir;
}
const writeUserSettings = (home, obj) =>
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify(obj));

// A configDir laid out like Claude Code's CLAUDE_CONFIG_DIR: it directly
// contains settings.json and .claude.json.
function tmpCliConfigDir() {
  const dir = tmpDir("cc-otel-clicfg-");
  return dir;
}
const writeClaudeJson = (configDir, obj) =>
  fs.writeFileSync(path.join(configDir, ".claude.json"), JSON.stringify(obj));

const IDENTITY = { email: "ahmed.gharib@itworx.com", accountId: "acct-uuid-123" };

const SAMPLE = {
  session_id: "0193ca7f-6a2e-7c4a-9e21-0f1c11ab1234",
  model: { id: "claude-sonnet-4-6", display_name: "Sonnet 4.6" },
  rate_limits: {
    five_hour: { used_percentage: 18, resets_at: 1778850000 },
    seven_day: { used_percentage: 33, resets_at: 1779000000 },
    seven_day_sonnet: { used_percentage: 2, resets_at: 1779000000 },
  },
};

const resourceAttrs = (body) => body.resourceMetrics[0].resource.attributes;
const resourceAttr = (body, key) =>
  resourceAttrs(body).find((a) => a.key === key)?.value.stringValue;

// ---------------------------------------------------------------------------
// buildOtlpBody — only the two rate-limit gauges
// ---------------------------------------------------------------------------

test("buildOtlpBody emits exactly the two rate-limit gauges, nothing else", () => {
  const body = buildOtlpBody(SAMPLE, Date.now(), IDENTITY);
  assert.ok(body, "body must not be null");
  const metrics = body.resourceMetrics[0].scopeMetrics[0].metrics;
  const names = metrics.map((m) => m.name).sort();
  assert.deepEqual(names, [
    "claude_code.usage.reset_in_seconds",
    "claude_code.usage.utilization",
  ]);
});

test("buildOtlpBody: utilization gauge has one datapoint per window, window-labelled", () => {
  const body = buildOtlpBody(SAMPLE, Date.now(), IDENTITY);
  const util = body.resourceMetrics[0].scopeMetrics[0].metrics.find(
    (m) => m.name === "claude_code.usage.utilization",
  );
  assert.equal(util.gauge.dataPoints.length, 3);
  const byWindow = Object.fromEntries(
    util.gauge.dataPoints.map((p) => [
      p.attributes.find((a) => a.key === "window").value.stringValue,
      p.asDouble,
    ]),
  );
  assert.equal(byWindow["5h"], 18);
  assert.equal(byWindow["7d"], 33);
  assert.equal(byWindow["7d_sonnet"], 2);
});

test("buildOtlpBody: datapoint attributes are window-only (identity lives on the resource)", () => {
  const body = buildOtlpBody(SAMPLE, Date.now(), IDENTITY);
  for (const m of body.resourceMetrics[0].scopeMetrics[0].metrics) {
    for (const p of m.gauge.dataPoints) {
      const keys = p.attributes.map((a) => a.key);
      assert.deepEqual(keys, ["window"], `datapoint should carry only window, got ${keys}`);
    }
  }
});

test("buildOtlpBody: identity + session.id are resource attributes matching official values", () => {
  const body = buildOtlpBody(SAMPLE, Date.now(), IDENTITY);
  assert.equal(resourceAttr(body, "service.name"), "claude-code");
  assert.equal(resourceAttr(body, "user.email"), "ahmed.gharib@itworx.com");
  assert.equal(resourceAttr(body, "user.account_id"), "acct-uuid-123");
  assert.equal(resourceAttr(body, "session.id"), SAMPLE.session_id);
});

test("buildOtlpBody: omits identity labels when identity is empty (resolves server-side)", () => {
  const body = buildOtlpBody(SAMPLE, Date.now(), { email: null, accountId: null });
  assert.equal(resourceAttr(body, "user.email"), undefined);
  assert.equal(resourceAttr(body, "user.account_id"), undefined);
  // session.id still present (from payload) so rows can join server-side.
  assert.equal(resourceAttr(body, "session.id"), SAMPLE.session_id);
});

test("buildOtlpBody: no context / session / cost gauges are ever emitted", () => {
  const payload = {
    ...SAMPLE,
    context_window: { used_percentage: 40, total_input_tokens: 1000, total_output_tokens: 500 },
    cost: { total_duration_ms: 123, total_api_duration_ms: 45 },
  };
  const names = buildOtlpBody(payload, Date.now(), IDENTITY)
    .resourceMetrics[0].scopeMetrics[0].metrics.map((m) => m.name);
  assert.ok(!names.some((n) => n.startsWith("claude_code.context")));
  assert.ok(!names.some((n) => n.startsWith("claude_code.session")));
});

test("buildOtlpBody returns null when rate_limits absent or malformed", () => {
  assert.equal(buildOtlpBody({}, Date.now(), IDENTITY), null);
  assert.equal(buildOtlpBody({ rate_limits: null }, Date.now(), IDENTITY), null);
  assert.equal(buildOtlpBody({ rate_limits: "nope" }, Date.now(), IDENTITY), null);
});

test("buildOtlpBody returns null when every sub-window is malformed", () => {
  const body = buildOtlpBody(
    { rate_limits: { five_hour: { used_percentage: "x" }, seven_day: null } },
    Date.now(),
    IDENTITY,
  );
  assert.equal(body, null);
});

test("buildOtlpBody: reset_in_seconds = resets_at − now, floored at 0", () => {
  const nowMs = 1_778_000_000 * 1000;
  const payload = {
    rate_limits: {
      five_hour: { used_percentage: 50, resets_at: 1_778_000_300 }, // +5min
      seven_day: { used_percentage: 25, resets_at: 1_777_999_000 }, // already past
    },
  };
  const reset = buildOtlpBody(payload, nowMs, IDENTITY)
    .resourceMetrics[0].scopeMetrics[0].metrics.find(
      (m) => m.name === "claude_code.usage.reset_in_seconds",
    );
  assert.equal(reset.unit, "s");
  const byWindow = Object.fromEntries(
    reset.gauge.dataPoints.map((p) => [
      p.attributes.find((a) => a.key === "window").value.stringValue,
      p.asDouble,
    ]),
  );
  assert.equal(byWindow["5h"], 300);
  assert.equal(byWindow["7d"], 0);
});

test("buildOtlpBody: only utilization gauge when no resets_at present", () => {
  const names = buildOtlpBody(
    { rate_limits: { five_hour: { used_percentage: 10 }, seven_day: { used_percentage: 20 } } },
    Date.now(),
    IDENTITY,
  ).resourceMetrics[0].scopeMetrics[0].metrics.map((m) => m.name);
  assert.deepEqual(names, ["claude_code.usage.utilization"]);
});

test("buildOtlpBody preserves arbitrary Anthropic windows generically", () => {
  const windows = buildOtlpBody(
    {
      rate_limits: {
        five_hour: { used_percentage: 10 },
        seven_day_opus: { used_percentage: 55 },
        seven_day_oauth_apps: { used_percentage: 7 },
      },
    },
    Date.now(),
    IDENTITY,
  )
    .resourceMetrics[0].scopeMetrics[0].metrics[0].gauge.dataPoints.map(
      (p) => p.attributes.find((a) => a.key === "window").value.stringValue,
    );
  assert.deepEqual(windows.sort(), ["5h", "7d_oauth_apps", "7d_opus"]);
});

// ---------------------------------------------------------------------------
// readIdentityFrom — oauthAccount is the source of truth
// ---------------------------------------------------------------------------

test("readIdentityFrom reads oauthAccount email (lowercased) + accountUuid", () => {
  const cfg = tmpCliConfigDir();
  writeClaudeJson(cfg, {
    oauthAccount: { emailAddress: "Ahmed.Gharib@ITWorx.com", accountUuid: "uuid-abc" },
  });
  const id = readIdentityFrom({ env: { CLAUDE_CONFIG_DIR: cfg } });
  assert.equal(id.email, "ahmed.gharib@itworx.com");
  assert.equal(id.accountId, "uuid-abc");
});

test("readIdentityFrom: oauthAccount email wins over CLAUDE_USER_EMAIL", () => {
  const cfg = tmpCliConfigDir();
  writeClaudeJson(cfg, {
    oauthAccount: { emailAddress: "real@itworx.com", accountUuid: "uuid-abc" },
  });
  const id = readIdentityFrom({ env: { CLAUDE_CONFIG_DIR: cfg, CLAUDE_USER_EMAIL: "env@x.com" } });
  assert.equal(id.email, "real@itworx.com");
});

test("readIdentityFrom: falls back to CLAUDE_USER_EMAIL when no oauthAccount, accountId stays null", () => {
  const cfg = tmpCliConfigDir(); // no .claude.json written
  const id = readIdentityFrom({ env: { CLAUDE_CONFIG_DIR: cfg, CLAUDE_USER_EMAIL: "Env@X.com" } });
  assert.equal(id.email, "env@x.com");
  assert.equal(id.accountId, null);
});

test("readIdentityFrom: omits identity entirely when nothing available", () => {
  const cfg = tmpCliConfigDir();
  const id = readIdentityFrom({ env: { CLAUDE_CONFIG_DIR: cfg } });
  assert.equal(id.email, null);
  assert.equal(id.accountId, null);
});

// ---------------------------------------------------------------------------
// resolveInnerCmdFrom — settings.json chain only
// ---------------------------------------------------------------------------

test("resolveInnerCmd reads statusLine.command from user settings.json", () => {
  const home = tmpConfigDir();
  writeUserSettings(home, { statusLine: { type: "command", command: "npx ccusage statusline" } });
  const cmd = resolveInnerCmdFrom({ configDir: path.join(home, ".claude"), cwd: tmpConfigDir() });
  assert.equal(cmd, "npx ccusage statusline");
});

test("resolveInnerCmd: project local settings beat user settings", () => {
  const home = tmpConfigDir();
  const cwd = tmpConfigDir();
  writeUserSettings(home, { statusLine: { command: "user-cmd" } });
  fs.writeFileSync(
    path.join(cwd, ".claude", "settings.local.json"),
    JSON.stringify({ statusLine: { command: "local-cmd" } }),
  );
  const cmd = resolveInnerCmdFrom({ configDir: path.join(home, ".claude"), cwd });
  assert.equal(cmd, "local-cmd");
});

test("resolveInnerCmd skips a command that points back at this wrapper (no self-loop)", () => {
  const home = tmpConfigDir();
  writeUserSettings(home, {
    statusLine: { command: 'node "C:/Program Files/ClaudeCode/cc-otel-wrapper.mjs"' },
  });
  const cmd = resolveInnerCmdFrom({ configDir: path.join(home, ".claude"), cwd: tmpConfigDir() });
  assert.equal(cmd, null);
});

test("resolveInnerCmd returns null when nothing is configured (empty bar)", () => {
  const cmd = resolveInnerCmdFrom({ configDir: path.join(tmpConfigDir(), ".claude"), cwd: tmpConfigDir() });
  assert.equal(cmd, null);
});

test("resolveInnerCmd does NOT scan for ~/.claude statusline files", () => {
  const home = tmpConfigDir();
  fs.writeFileSync(path.join(home, ".claude", "statusline-command.js"), "// user");
  // File present but no settings.json command → resolver ignores it.
  const cmd = resolveInnerCmdFrom({ configDir: path.join(home, ".claude"), cwd: tmpConfigDir() });
  assert.equal(cmd, null);
});

test("resolveInnerCmd prepends the interpreter to a bare script path (Windows association guard)", () => {
  const home = tmpConfigDir();
  const script = path.join(home, ".claude", "statusline-command.js");
  fs.writeFileSync(script, "// noop");
  writeUserSettings(home, { statusLine: { command: script } });
  const cmd = resolveInnerCmdFrom({ configDir: path.join(home, ".claude"), cwd: tmpConfigDir() });
  const expected = `node ${/\s/.test(script) ? `"${script}"` : script}`;
  assert.equal(cmd, expected);
});

test("resolveInnerCmd expands ${CLAUDE_CONFIG_DIR} inside a settings command", () => {
  const home = tmpConfigDir();
  const cfg = path.join(home, ".claude");
  const script = path.join(cfg, "statusline-command.js");
  fs.writeFileSync(script, "// noop");
  writeUserSettings(home, { statusLine: { command: "${CLAUDE_CONFIG_DIR}/statusline-command.js" } });
  const cmd = resolveInnerCmdFrom({ configDir: cfg, cwd: tmpConfigDir() });
  assert.match(cmd, /^node /);
  const resolved = cmd.replace(/^node /, "").replace(/^"|"$/g, "");
  assert.ok(fs.existsSync(resolved), `expanded path should exist: ${resolved}`);
});

// ---------------------------------------------------------------------------
// throttleAllows — one push per window per machine
// ---------------------------------------------------------------------------

test("throttleAllows: first call allows, second within window blocks", () => {
  const stateFile = path.join(tmpDir(), "throttle");
  const now = 1_778_000_000_000;
  assert.equal(throttleAllows({ stateFile, nowMs: now, windowMs: 300_000 }), true);
  assert.equal(throttleAllows({ stateFile, nowMs: now + 60_000, windowMs: 300_000 }), false);
});

test("throttleAllows: allows again once the window elapses", () => {
  const stateFile = path.join(tmpDir(), "throttle");
  const now = 1_778_000_000_000;
  assert.equal(throttleAllows({ stateFile, nowMs: now, windowMs: 300_000 }), true);
  assert.equal(throttleAllows({ stateFile, nowMs: now + 300_001, windowMs: 300_000 }), true);
});

test("throttleAllows: an unreadable state file never blocks the push", () => {
  // A directory where the state file is expected → read/write both fail; must still allow.
  const stateFile = tmpDir(); // path is a directory, not a file
  assert.equal(throttleAllows({ stateFile, nowMs: 1_778_000_000_000, windowMs: 300_000 }), true);
});

// ---------------------------------------------------------------------------
// resolveEndpoint / resolveHeaders — reuse OTEL_* env, STATUSLINE_* overrides
// ---------------------------------------------------------------------------

test("resolveEndpoint: appends /v1/metrics to the base OTEL_EXPORTER_OTLP_ENDPOINT", () => {
  assert.equal(
    resolveEndpoint({ OTEL_EXPORTER_OTLP_ENDPOINT: "https://collector.example.com" }),
    "https://collector.example.com/v1/metrics",
  );
});

test("resolveEndpoint: trims a trailing slash on the base before appending", () => {
  assert.equal(
    resolveEndpoint({ OTEL_EXPORTER_OTLP_ENDPOINT: "https://collector.example.com/" }),
    "https://collector.example.com/v1/metrics",
  );
});

test("resolveEndpoint: STATUSLINE_OTLP_ENDPOINT overrides the OTEL_* base verbatim", () => {
  assert.equal(
    resolveEndpoint({
      OTEL_EXPORTER_OTLP_ENDPOINT: "https://collector.example.com",
      STATUSLINE_OTLP_ENDPOINT: "http://127.0.0.1:9999/v1/metrics",
    }),
    "http://127.0.0.1:9999/v1/metrics",
  );
});

test("resolveEndpoint: falls back to localhost when no env is set", () => {
  assert.equal(resolveEndpoint({}), "http://localhost:4318/v1/metrics");
});

test("resolveEndpoint: reads the base from managed-settings.json when OTEL_*/STATUSLINE_* are unset", () => {
  const managed = { OTEL_EXPORTER_OTLP_ENDPOINT: "https://collector.example.com" };
  assert.equal(resolveEndpoint({}, managed), "https://collector.example.com/v1/metrics");
});

test("resolveEndpoint: inherited OTEL_* env beats managed-settings.json", () => {
  const managed = { OTEL_EXPORTER_OTLP_ENDPOINT: "https://from-file.example.com" };
  assert.equal(
    resolveEndpoint({ OTEL_EXPORTER_OTLP_ENDPOINT: "https://from-env.example.com" }, managed),
    "https://from-env.example.com/v1/metrics",
  );
});

test("resolveHeaders: parses the bearer out of OTEL_EXPORTER_OTLP_HEADERS", () => {
  const h = resolveHeaders({ OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Bearer tok-123" });
  assert.equal(h.Authorization, "Bearer tok-123");
});

test("resolveHeaders: STATUSLINE_OTLP_HEADERS overrides OTEL_EXPORTER_OTLP_HEADERS", () => {
  const h = resolveHeaders({
    OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Bearer base",
    STATUSLINE_OTLP_HEADERS: "Authorization=Bearer override",
  });
  assert.equal(h.Authorization, "Bearer override");
});

test("resolveHeaders: empty when neither header env is set", () => {
  assert.deepEqual(resolveHeaders({}), {});
});

test("resolveHeaders: reads the bearer from managed-settings.json when env is unset", () => {
  const managed = { OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Bearer from-file" };
  assert.equal(resolveHeaders({}, managed).Authorization, "Bearer from-file");
});

test("readManagedSettingsEnv: returns the env block from managed-settings.json beside the wrapper", () => {
  const dir = tmpDir("cc-otel-managed-");
  fs.writeFileSync(
    path.join(dir, "managed-settings.json"),
    JSON.stringify({ env: { OTEL_EXPORTER_OTLP_ENDPOINT: "https://c.example.com" } }),
  );
  assert.deepEqual(readManagedSettingsEnv(dir), {
    OTEL_EXPORTER_OTLP_ENDPOINT: "https://c.example.com",
  });
});

test("readManagedSettingsEnv: {} when the file is absent (never throws)", () => {
  assert.deepEqual(readManagedSettingsEnv(tmpDir("cc-otel-empty-")), {});
});

test("readManagedSettingsEnv: drops non-string values so downstream trim/split never throw", () => {
  const dir = tmpDir("cc-otel-managed-bad-");
  fs.writeFileSync(
    path.join(dir, "managed-settings.json"),
    JSON.stringify({
      env: {
        OTEL_EXPORTER_OTLP_ENDPOINT: 4318, // malformed: number, not string
        OTEL_EXPORTER_OTLP_HEADERS: { Authorization: "x" }, // malformed: object
        CLAUDE_CODE_ENABLE_TELEMETRY: "1", // valid string is kept
      },
    }),
  );
  const managed = readManagedSettingsEnv(dir);
  assert.deepEqual(managed, { CLAUDE_CODE_ENABLE_TELEMETRY: "1" });
  // The malformed values are gone, so resolution stays on the safe path.
  assert.equal(resolveEndpoint({}, managed), "http://localhost:4318/v1/metrics");
  assert.deepEqual(resolveHeaders({}, managed), {});
});

// ---------------------------------------------------------------------------
// End-to-end stdin/spawn tests (real wrapper invocation)
// ---------------------------------------------------------------------------

function startFakeCollector() {
  const received = [];
  const server = http.createServer((req, res) => {
    let buf = "";
    req.on("data", (c) => (buf += c));
    req.on("end", () => {
      const auth = req.headers.authorization;
      try {
        received.push({ url: req.url, auth, body: JSON.parse(buf) });
      } catch {
        received.push({ url: req.url, auth, body: null, raw: buf });
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
    });
  });
  return { server, received };
}

// Isolated CLAUDE_CONFIG_DIR with an inner statusline command + oauth identity,
// plus a fresh throttle file, so spawned wrappers never touch the dev's real
// config or the repo's own settings.
function e2eConfig({ innerCmd = "cat", identity = true } = {}) {
  const cfg = tmpCliConfigDir();
  fs.writeFileSync(
    path.join(cfg, "settings.json"),
    JSON.stringify(innerCmd ? { statusLine: { command: innerCmd } } : {}),
  );
  if (identity) {
    writeClaudeJson(cfg, {
      oauthAccount: { emailAddress: "ahmed.gharib@itworx.com", accountUuid: "uuid-e2e" },
    });
  }
  return {
    CLAUDE_CONFIG_DIR: cfg,
    STATUSLINE_THROTTLE_FILE: path.join(tmpDir(), "throttle"),
  };
}

async function runWrapper(stdinJson, env) {
  const child = spawn("node", [WRAPPER], {
    cwd: tmpDir(), // empty cwd — no project .claude/settings.json in scope
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c) => (stdout += c));
  child.stderr.on("data", (c) => (stderr += c));
  child.stdin.write(stdinJson);
  child.stdin.end();
  const [code] = await once(child, "close");
  return { code, stdout, stderr };
}

test("end-to-end: forwards stdin to the inner cmd and pushes the two-gauge body with resource identity", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  const { code, stdout } = await runWrapper(JSON.stringify(SAMPLE), {
    ...e2eConfig(),
    STATUSLINE_OTLP_ENDPOINT: `http://127.0.0.1:${port}/v1/metrics`,
  });
  await new Promise((r) => server.close(r));

  assert.equal(code, 0, `wrapper exited non-zero: ${code}`);
  assert.match(stdout, /"session_id"/); // `cat` echoed the forwarded payload
  assert.equal(received.length, 1);
  const body = received[0].body;
  const names = body.resourceMetrics[0].scopeMetrics[0].metrics.map((m) => m.name).sort();
  assert.deepEqual(names, [
    "claude_code.usage.reset_in_seconds",
    "claude_code.usage.utilization",
  ]);
  assert.equal(resourceAttr(body, "user.email"), "ahmed.gharib@itworx.com");
  assert.equal(resourceAttr(body, "user.account_id"), "uuid-e2e");
});

test("end-to-end: resolves the endpoint from OTEL_EXPORTER_OTLP_* env (no STATUSLINE_* set)", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  // Only the base OTEL_* endpoint is set; the wrapper must append /v1/metrics.
  // Blank out any STATUSLINE_* the runner inherits from a fleet machine so the
  // OTEL_* resolution path is the one under test.
  const { code } = await runWrapper(JSON.stringify(SAMPLE), {
    ...e2eConfig(),
    STATUSLINE_OTLP_ENDPOINT: "",
    STATUSLINE_OTLP_HEADERS: "",
    OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${port}`,
  });
  await new Promise((r) => server.close(r));

  assert.equal(code, 0);
  assert.equal(received.length, 1);
  assert.equal(received[0].url, "/v1/metrics");
});

test("end-to-end: with OTEL_*/STATUSLINE_* unset, resolves endpoint+bearer from a co-located managed-settings.json (the statusLine-subprocess case)", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  // Copy the real wrapper into a temp InstallRoot with managed-settings.json
  // beside it — the on-disk layout the installer produces. This is the only
  // source of the OTLP target; the spawn env carries no OTEL_*/STATUSLINE_*.
  const installRoot = tmpDir("cc-otel-installroot-");
  const wrapperCopy = path.join(installRoot, "cc-otel-wrapper.mjs");
  fs.copyFileSync(WRAPPER, wrapperCopy);
  fs.writeFileSync(
    path.join(installRoot, "managed-settings.json"),
    JSON.stringify({
      env: {
        OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${port}`,
        OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Bearer fleet-token-from-file",
      },
    }),
  );

  const child = spawn("node", [wrapperCopy], {
    cwd: tmpDir(),
    env: {
      ...process.env,
      ...e2eConfig(),
      OTEL_EXPORTER_OTLP_ENDPOINT: "",
      OTEL_EXPORTER_OTLP_HEADERS: "",
      STATUSLINE_OTLP_ENDPOINT: "",
      STATUSLINE_OTLP_HEADERS: "",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdin.write(JSON.stringify(SAMPLE));
  child.stdin.end();
  const [code] = await once(child, "close");
  await new Promise((r) => server.close(r));

  assert.equal(code, 0);
  assert.equal(received.length, 1, "the push must reach the file-configured endpoint, not localhost");
  assert.equal(received[0].url, "/v1/metrics");
  assert.equal(received[0].auth, "Bearer fleet-token-from-file");
});

test("end-to-end: second invocation within 5 minutes performs no HTTP call", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  const env = {
    ...e2eConfig(), // shared throttle file across both runs
    STATUSLINE_OTLP_ENDPOINT: `http://127.0.0.1:${port}/v1/metrics`,
  };
  await runWrapper(JSON.stringify(SAMPLE), env);
  await runWrapper(JSON.stringify(SAMPLE), env);
  await new Promise((r) => server.close(r));

  assert.equal(received.length, 1, "throttle should suppress the second push");
});

test("end-to-end: no inner command configured → stdout is empty (never raw JSON)", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  const { code, stdout } = await runWrapper(JSON.stringify(SAMPLE), {
    ...e2eConfig({ innerCmd: null }),
    STATUSLINE_OTLP_ENDPOINT: `http://127.0.0.1:${port}/v1/metrics`,
  });
  await new Promise((r) => server.close(r));

  assert.equal(code, 0);
  assert.equal(stdout, "", "no statusline configured → empty bar, never the JSON payload");
});

test("end-to-end: exits 0 when the collector is unreachable", async () => {
  const { code } = await runWrapper(JSON.stringify(SAMPLE), {
    ...e2eConfig(),
    STATUSLINE_OTLP_ENDPOINT: "http://127.0.0.1:1/v1/metrics",
    STATUSLINE_OTLP_TIMEOUT_MS: "500",
  });
  assert.equal(code, 0);
});

test("end-to-end: no rate_limits block → no HTTP call at all", async () => {
  const { server, received } = startFakeCollector();
  server.listen(0);
  await once(server, "listening");
  const port = server.address().port;

  const { code } = await runWrapper(
    JSON.stringify({ session_id: "abc", model: { id: "x" } }),
    { ...e2eConfig(), STATUSLINE_OTLP_ENDPOINT: `http://127.0.0.1:${port}/v1/metrics` },
  );
  await new Promise((r) => server.close(r));
  assert.equal(code, 0);
  assert.equal(received.length, 0);
});

test("end-to-end: exits 0 when stdin is not JSON", async () => {
  const { code } = await runWrapper("totally not json {", {
    ...e2eConfig(),
    STATUSLINE_OTLP_ENDPOINT: "http://127.0.0.1:1/v1/metrics",
  });
  assert.equal(code, 0);
});
