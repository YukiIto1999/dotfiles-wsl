import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const GATE = "/run/current-system/sw/bin/dotfiles-agent-gate";
const EDITING_TOOLS: Record<string, true> = { edit: true, write: true, ast_edit: true };
const READING_TOOLS: Record<string, true> = { read: true };
// 書き込み先を入力から読めない tool。前後の木の指紋を比べて、変えた repository だけを門にかける。
const SHELL_TOOLS: Record<string, true> = { bash: true, eval: true };

async function gate(
  pi: ExtensionAPI,
  kind: "arm" | "edit" | "learn" | "observe" | "stop",
  payload: Record<string, unknown>,
  cwd: string,
  signal?: AbortSignal,
): Promise<{ code: number; text: string }> {
  try {
    const result = await pi.exec(
      "/run/current-system/sw/bin/bash",
      [
        "-c",
        'printf "%s" "$1" | exec "$2" hook "$3"',
        "verification-gate",
        JSON.stringify(payload),
        GATE,
        kind,
      ],
      { cwd, signal, timeout: 20_000 },
    );
    return { code: result.code, text: result.stdout.trim() };
  } catch (error) {
    // 門が起こせないこと自体で仕事を止めない。止めるのは未検証と未読を観測したときだけである。
    pi.logger.warn("verification gate could not run", { kind, error: String(error) });
    return { code: 0, text: "" };
  }
}

export default function verificationGate(pi: ExtensionAPI): void {
  // 設計の規律は決める時点で呼ばれなければ意味がない。読んでいない領域は触らせない。
  pi.on("tool_call", async (event, ctx: ExtensionContext) => {
    const payload = {
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      tool_name: event.toolName,
      tool_input: event.input,
    };
    if (SHELL_TOOLS[event.toolName] === true) {
      await gate(
        pi,
        "observe",
        { ...payload, hook_event_name: "PreToolUse", tool_use_id: event.toolCallId },
        ctx.cwd,
      );
      return;
    }
    if (READING_TOOLS[event.toolName] === true) {
      await gate(pi, "learn", payload, ctx.cwd);
      return;
    }
    if (EDITING_TOOLS[event.toolName] !== true) return;
    const held = await gate(pi, "edit", payload, ctx.cwd);
    if (held.code === 0 || held.text.length === 0) return;
    return { block: true as const, reason: held.text };
  });

  pi.on("tool_result", async (event, ctx: ExtensionContext) => {
    const payload = {
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      tool_name: event.toolName,
      tool_input: event.input,
    };
    // 失敗した shell の呼び出しも木を変えうるので、結果を問わず後の指紋を採る。
    if (SHELL_TOOLS[event.toolName] === true) {
      await gate(
        pi,
        "observe",
        { ...payload, hook_event_name: "PostToolUse", tool_use_id: event.toolCallId },
        ctx.cwd,
      );
      return;
    }
    if (event.isError || EDITING_TOOLS[event.toolName] !== true) return;
    await gate(pi, "arm", payload, ctx.cwd);
  });

  pi.on("session_stop", async (event, ctx: ExtensionContext) => {
    const held = await gate(
      pi,
      "stop",
      {
        session_id: ctx.sessionManager.getSessionId(),
        cwd: ctx.cwd,
        stop_hook_active: event.stop_hook_active,
      },
      ctx.cwd,
      event.signal,
    );
    if (held.code === 0 || held.text.length === 0) return;
    return { decision: "block" as const, reason: held.text };
  });
}
