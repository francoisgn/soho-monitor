// Claude plan usage for one Claude Code profile, as one JSON object on stdout (ADR 0001).
//
// Run by SohoMonitor: `node usage.mjs` with
//   CLAUDE_CONFIG_DIR         the profile's config directory (its own login, read by Claude Code itself)
//   SOHO_CLAUDE_EXECUTABLE    the installed `claude` binary, unmodified (the SDK's bundled copy is not shipped)
// It opens an Agent SDK session whose prompt never yields, so no message is ever sent to the model (cost 0), asks
// Claude Code for the structured data behind `/usage`, prints the server's usage rows, and closes the session.
// This script never reads a token, a credentials file or the Keychain.
//
// Output (exit 0): {"subscription_type": string|null, "rate_limits_available": bool, "limits": [row]|null}
//   row = {kind, group, percent, severity, resets_at, scope_model, is_active}, as the server sent them.
// Failure (exit 1): {"error": "<one line>"}.
import { query } from "@anthropic-ai/claude-agent-sdk";

const TIMEOUT_MS = 25_000; // the app kills the helper after 30 s; fail first with a message of our own

function finish(object, code) {
  process.stdout.write(`${JSON.stringify(object)}\n`, () => process.exit(code));
}

function fail(message) {
  const line = String(message).split("\n")[0].slice(0, 300);
  finish({ error: line }, 1);
}

const executable = process.env.SOHO_CLAUDE_EXECUTABLE;
if (!process.env.CLAUDE_CONFIG_DIR) fail("CLAUDE_CONFIG_DIR is not set");
else if (!executable) fail("SOHO_CLAUDE_EXECUTABLE is not set");
else {
  let release = () => {};
  const idle = new Promise((resolve) => (release = resolve));
  // Keeps the session open without ever sending a message: the control request needs a live session only.
  async function* noPrompt() {
    await idle;
  }

  const q = query({
    prompt: noPrompt(),
    options: {
      pathToClaudeCodeExecutable: executable,
      settingSources: [], // no user, project or local settings: hooks and plugins of the profile stay out
      persistSession: false, // no transcript written in the profile
      env: { ...process.env },
    },
  });
  const stop = () => {
    release();
    q.close?.();
  };
  process.on("SIGTERM", () => {
    stop();
    process.exit(143);
  });
  const timer = setTimeout(() => {
    stop();
    fail(`no answer from Claude Code within ${TIMEOUT_MS / 1000} s`);
  }, TIMEOUT_MS);

  try {
    const usage = await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
    const rows = usage?.rate_limits?.limits;
    clearTimeout(timer);
    stop();
    finish(
      {
        subscription_type: usage?.subscription_type ?? null,
        rate_limits_available: usage?.rate_limits_available === true,
        limits: Array.isArray(rows)
          ? rows.map((row) => ({
              kind: row?.kind ?? null,
              group: row?.group ?? null,
              percent: row?.percent ?? null,
              severity: row?.severity ?? null,
              resets_at: row?.resets_at ?? null,
              scope_model: row?.scope?.model?.display_name ?? null,
              is_active: row?.is_active === true,
            }))
          : null,
      },
      0,
    );
  } catch (error) {
    clearTimeout(timer);
    stop();
    fail(error instanceof Error ? error.message : error);
  }
}
