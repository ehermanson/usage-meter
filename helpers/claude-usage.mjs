#!/usr/bin/env node
// Reads Claude plan usage the same way Relay does: via the Claude Agent SDK's
// experimental get_usage control request over a warm Claude Code subprocess.
// Prints a single JSON line to stdout and exits.
//
//   { "ok": true,  "rate_limits": { "five_hour": { "utilization": 4, "resets_at": "..." }, ... },
//                  "subscription_type": "..." }
//   { "ok": false, "error": "Rate limited. Please try again later.", "code": "rate_limit_error" }

// Generous enough for two warm CLI startups (the config-dir probe retries
// once on an empty snapshot); each startup is individually capped at 30s.
const OVERALL_TIMEOUT_MS = 65_000;

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

// Claude Code resolves its sign-in state relative to CLAUDE_CONFIG_DIR — and
// *whether* the variable is set changes where credentials are looked up (the
// exact store is a CLI internal we can't reliably detect from outside).
// Setups that pin it per-invocation (e.g. `alias claude='CLAUDE_CONFIG_DIR=
// ~/.claude claude'`) sign in under the pinned dir, which a GUI-spawned bare
// CLI never sees — the headless session then reports
// rate_limits_available:false even though the user's own terminal works fine.
//
// Resolution: an explicit setting (the app's picker or a real env var) wins;
// then a login-shell export; otherwise start unset like a bare spawn. `source`
// tells the caller whether the choice was the user's ("user") or merely a
// guess ("none") that a failed fetch is allowed to flip.
function resolveConfigDir() {
  if (process.env.CLAUDE_CONFIG_DIR) {
    return { dir: process.env.CLAUDE_CONFIG_DIR, source: "user" };
  }
  try {
    const exported = execFileSync(
      "/bin/sh",
      ["-lc", 'printf "%s" "$CLAUDE_CONFIG_DIR"'],
      { encoding: "utf8" },
    ).trim();
    if (exported) return { dir: exported, source: "user" };
  } catch {
    /* shell lookup failed */
  }
  return { dir: null, source: "none" };
}

// A prompt iterable that never yields keeps the query handle open long enough
// to issue the usage control request, exactly like Relay's PromptQueue.
async function* idlePrompt() {
  await new Promise(() => {});
}

// One full fetch: warm CLI subprocess (inheriting this process's env, incl.
// any CLAUDE_CONFIG_DIR set by the caller) → get_usage → snapshot.
async function readUsageSnapshot(startup, pathToClaudeCodeExecutable) {
  const warm = await startup({
    options: { pathToClaudeCodeExecutable },
    initializeTimeoutMs: 30_000,
  });
  const handle = warm.query(idlePrompt());
  try {
    const getUsage = handle.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
    if (typeof getUsage !== "function") {
      return fail("SDK too old: get_usage not available", "unsupported");
    }
    try {
      return await getUsage.call(handle);
    } catch (err) {
      failIfOutdatedCli(String(err?.message ?? err ?? ""));
      throw err;
    }
  } finally {
    try {
      await handle.close();
    } catch {
      /* ignore */
    }
  }
}

// "Empty": the CLI answered but says plan limits don't apply and carries no
// data — the signature of a config-dir mismatch (vs. an error or throttle).
function isEmptySnapshot(snap) {
  return (
    !snap?.error &&
    !snap?.rate_limits_available &&
    (!snap?.rate_limits || typeof snap.rate_limits !== "object")
  );
}

async function main() {
  const startup = await resolveStartup();
  const pathToClaudeCodeExecutable = resolveClaudeBin();
  if (!pathToClaudeCodeExecutable) {
    return fail("Claude Code executable not found", "claude_not_found");
  }
  const { dir: configDir, source } = resolveConfigDir();
  if (configDir) process.env.CLAUDE_CONFIG_DIR = configDir;

  let snap = await readUsageSnapshot(startup, pathToClaudeCodeExecutable);

  // Probe: an empty snapshot usually means the config-dir guess missed the
  // sign-in (Keychain vs a pinned CLAUDE_CONFIG_DIR are separate credential
  // worlds). When the choice was ours — not the user's — flip the guess and
  // try once more: unset → ~/.claude. Costs one extra warm startup, only on
  // the failure path, and self-corrects both kinds of setup.
  if (isEmptySnapshot(snap) && source !== "user") {
    const dot = join(homedir(), ".claude");
    if (existsSync(dot)) {
      process.env.CLAUDE_CONFIG_DIR = dot;
      const retry = await readUsageSnapshot(startup, pathToClaudeCodeExecutable);
      // Keep whichever attempt carries data; on a double miss prefer the one
      // that at least knows the subscription (it yields a better message).
      if (!isEmptySnapshot(retry) || retry?.subscription_type) snap = retry;
    }
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
    if (snap?.rate_limits_available) {
      return fail("Usage temporarily throttled", "throttled", subscription);
    }
    // rate_limits_available:false — the SDK says plan limits don't apply to
    // this session (API key, Bedrock, or Vertex) or the OAuth token is
    // missing the profile scope (an older sign-in). If we know the user is
    // on a claude.ai plan (pro/max/team/enterprise), the stale token is the
    // likely culprit and signing in again fixes it.
    if (subscription) {
      return fail(
        "Sign in to Claude Code again (/login) to enable usage reporting",
        "no_scope",
        subscription,
      );
    }
    return fail(
      "This session has no plan rate limits (API key, Bedrock, or Vertex)",
      "no_plan",
      subscription,
    );
  }

  clearTimeout(watchdog);
  emit({ ok: true, rate_limits: limits, subscription_type: subscription });
  process.exit(0);
}

main().catch((err) => fail(err?.message ?? err, "exception"));
