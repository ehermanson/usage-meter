#!/usr/bin/env node
// Reads Claude plan usage the same way Relay does: via the Claude Agent SDK's
// experimental get_usage control request over a warm Claude Code subprocess.
// Prints a single JSON line to stdout and exits.
//
//   { "ok": true,  "rate_limits": { "five_hour": { "utilization": 4, "resets_at": "..." }, ... },
//                  "subscription_type": "..." }
//   { "ok": false, "error": "Rate limited. Please try again later.", "code": "rate_limit_error" }

const OVERALL_TIMEOUT_MS = 35_000;

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function fail(message, code, subscription) {
  emit({
    ok: false,
    error: String(message ?? "unknown error"),
    code: code ?? null,
    subscription_type: subscription ?? null,
  });
  process.exit(0);
}

// An out-of-date Claude Code CLI rejects the get_usage control request with
// "Unsupported control request subtype: get_usage". Detect that (whether it
// surfaces as a rejection or an error payload) and show something actionable
// instead of leaking the raw protocol error.
function failIfOutdatedCli(message) {
  if (/unsupported control request subtype/i.test(message)) {
    fail("Claude Code is out of date — update it to enable usage reporting", "unsupported");
  }
}

// Hard watchdog so the helper can never hang the menu-bar app.
const watchdog = setTimeout(() => fail("Timed out reading Claude usage", "timeout"), OVERALL_TIMEOUT_MS);

async function resolveStartup() {
  // Resolve the SDK from this helper's own node_modules — bundled next to the
  // script inside the .app, or installed in helpers/ during development.
  try {
    const mod = await import("@anthropic-ai/claude-agent-sdk");
    if (typeof mod.startup === "function") return mod.startup;
    throw new Error("startup() not exported");
  } catch (err) {
    throw new Error(`Claude Agent SDK not found: ${err?.message ?? "unknown"}`);
  }
}

// The SDK needs the path to a Claude Code binary. The Swift app finds the user's
// install (via login-shell PATH) and passes it in USAGE_METER_CLAUDE_BIN; when the
// helper is run directly during development we fall back to a small PATH probe.
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

function resolveClaudeBin() {
  const fromEnv = process.env.USAGE_METER_CLAUDE_BIN;
  if (fromEnv && existsSync(fromEnv)) return fromEnv;

  const candidates = [
    join(homedir(), ".local/bin/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(homedir(), ".claude/local/claude"),
  ];
  for (const c of candidates) if (existsSync(c)) return c;

  try {
    const found = execFileSync("/bin/sh", ["-lc", "command -v claude"], {
      encoding: "utf8",
    }).trim();
    if (found && existsSync(found)) return found;
  } catch {
    /* not on PATH */
  }
  return null;
}

async function main() {
  const startup = await resolveStartup();
  const pathToClaudeCodeExecutable = resolveClaudeBin();
  if (!pathToClaudeCodeExecutable) {
    return fail("Claude Code executable not found", "claude_not_found");
  }
  const warm = await startup({
    options: { pathToClaudeCodeExecutable },
    initializeTimeoutMs: 30_000,
  });

  // A prompt iterable that never yields keeps the query handle open long enough
  // to issue the usage control request, exactly like Relay's PromptQueue.
  async function* idlePrompt() {
    await new Promise(() => {});
  }
  const handle = warm.query(idlePrompt());

  try {
    const getUsage = handle.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
    if (typeof getUsage !== "function") {
      return fail("SDK too old: get_usage not available", "unsupported");
    }
    let snap;
    try {
      snap = await getUsage.call(handle);
    } catch (err) {
      failIfOutdatedCli(String(err?.message ?? err ?? ""));
      throw err;
    }

    if (snap?.error) {
      const msg = String(snap.error.message ?? "usage error");
      failIfOutdatedCli(msg);
      return fail(msg, snap.error.type ?? "error");
    }
    const limits = snap?.rate_limits;
    const subscription = snap?.subscription_type ?? snap?.subscriptionType ?? null;
    if (!limits || typeof limits !== "object") {
      // rate_limits_available:true but rate_limits:null means the usage endpoint
      // is momentarily throttled — a soft, retryable state, not a hard failure.
      const code = snap?.rate_limits_available ? "throttled" : "empty";
      const msg =
        code === "throttled"
          ? "Usage temporarily throttled"
          : "No rate-limit data in usage snapshot";
      return fail(msg, code, subscription);
    }

    clearTimeout(watchdog);
    emit({ ok: true, rate_limits: limits, subscription_type: subscription });
  } finally {
    try {
      await handle.close();
    } catch {
      /* ignore */
    }
  }
  process.exit(0);
}

main().catch((err) => fail(err?.message ?? err, "exception"));
