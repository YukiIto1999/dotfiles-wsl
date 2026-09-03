import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const HOOK_ROOT = "/run/current-system/sw/bin";
const TOOL_HOOKS = new Set(["edit", "write", "read", "glob", "grep"]);

function sessionPayload(ctx: ExtensionContext): { session_id: string; cwd: string } {
  return {
    session_id: ctx.sessionManager.getSessionId(),
    cwd: ctx.cwd,
  };
}

async function runHook(
  pi: ExtensionAPI,
  name: string,
  payload: Record<string, unknown>,
  cwd: string,
  signal?: AbortSignal,
): Promise<string> {
  try {
    const result = await pi.exec(
      `${HOOK_ROOT}/bash`,
      [
        "-c",
        'printf "%s" "$1" | exec "$2"',
        "agentmemory-omp",
        JSON.stringify(payload),
        `${HOOK_ROOT}/agentmemory-hook-${name}`,
      ],
      { cwd, signal, timeout: 3500 },
    );
    if (result.code !== 0) {
      pi.logger.warn("OMP AgentMemory hook failed", {
        hook: name,
        code: result.code,
        stderr: result.stderr,
      });
      return "";
    }
    return result.stdout.trim();
  } catch (error) {
    // tool_call hooks must fail open: memory capture must never block the tool.
    pi.logger.warn("OMP AgentMemory hook could not run", {
      hook: name,
      error: String(error),
    });
    return "";
  }
}

export default function agentmemory(pi: ExtensionAPI): void {
  const recalledContext = new Map<string, string>();

  pi.on("session_start", async (_event, ctx) => {
    const payload = sessionPayload(ctx);
    const context = await runHook(pi, "session-start", payload, ctx.cwd);
    if (context) recalledContext.set(payload.session_id, context);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const payload = sessionPayload(ctx);
    await runHook(pi, "prompt-submit", { ...payload, prompt: event.prompt }, ctx.cwd);

    const context = recalledContext.get(payload.session_id);
    if (!context) return;
    recalledContext.delete(payload.session_id);
    return {
      message: {
        customType: "agentmemory-context",
        content: context,
        display: false,
        attribution: "agent",
      },
    };
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!TOOL_HOOKS.has(event.toolName)) return;
    const payload = sessionPayload(ctx);
    await runHook(
      pi,
      "pre-tool-use",
      {
        ...payload,
        tool_name: event.toolName,
        tool_input: event.input,
        tool_call_id: event.toolCallId,
      },
      ctx.cwd,
    );
  });

  pi.on("tool_result", async (event, ctx) => {
    const payload = sessionPayload(ctx);
    await runHook(
      pi,
      event.isError ? "post-tool-failure" : "post-tool-use",
      {
        ...payload,
        tool_name: event.toolName,
        tool_input: event.input,
        tool_response: event.content,
        tool_call_id: event.toolCallId,
      },
      ctx.cwd,
    );
  });

  pi.on("session_before_compact", async (event, ctx) => {
    await runHook(
      pi,
      "pre-compact",
      {
        ...sessionPayload(ctx),
        custom_instructions: event.customInstructions,
      },
      ctx.cwd,
      event.signal,
    );
  });

  pi.on("session_stop", async (event, ctx) => {
    await runHook(
      pi,
      "stop",
      {
        ...sessionPayload(ctx),
        turn_id: event.turn_id,
        stop_hook_active: event.stop_hook_active,
      },
      ctx.cwd,
      event.signal,
    );
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const payload = sessionPayload(ctx);
    recalledContext.delete(payload.session_id);
    await runHook(pi, "session-end", payload, ctx.cwd);
  });
}
