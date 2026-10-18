import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const GATE = "@gateBinary@";
const EDITING_TOOLS: Record<string, true> = { edit: true, write: true, ast_edit: true };
const READING_TOOLS: Record<string, true> = { read: true };
// 書き込み先を入力から読めない tool。前後の木の指紋を比べて、変えた repository だけを門にかける。
const SHELL_TOOLS: Record<string, true> = { bash: true, eval: true };

type GateKind = "arm" | "edit" | "learn" | "observe" | "stop";

const GATE_TIMEOUT_MS = 20_000;
const DRAIN_REPORT_MS = 30_000;

// 待機の上限と reader の cancel は子の終了の代用にならないため不可
/**
 * 取消した gate の終了監視と出力読取の全完了待ち
 * @param pi - 終了を確認できない間の診断先
 * @param kind - 診断に付ける hook の判定種別
 * @param pid - 当該 gate の process group leader
 * @param completion - 当該子の終了監視と出力読取の Promise 一覧
 * @returns 全待機対象の settle 後の完了
 */
async function reclaim(pi: ExtensionAPI, kind: GateKind, pid: number, completion: readonly Promise<unknown>[]): Promise<void> {
  try {
    process.kill(-pid, "SIGKILL");
  } catch (error) {
    const missing = error && typeof error === "object" && "code" in error && error.code === "ESRCH";
    if (!missing) pi.logger.warn("verification gate could not be signalled", { kind, pid, error: String(error) });
  }
  const report = setInterval(() => {
    pi.logger.warn("verification gate has not ended; still waiting for it", { kind, pid });
  }, DRAIN_REPORT_MS);
  try {
    await Promise.allSettled(completion);
  } finally {
    clearInterval(report);
  }
}

// 本文が argv の長さ制限を超えるため stdin 非対応の pi.exec は不採用
// 出力 pipe を持つ子孫が残るため単一 process の終了は不可
/**
 * hook の許可判定に用いる物理 gate の実行
 * @param pi - 実行失敗と終了待機の診断先
 * @param kind - gate に要求する判定種別
 * @param payload - stdin に渡す当該 hook の JSON event
 * @param cwd - 対象 repository を解決する作業 directory
 * @param signal - 呼出側の取消通知
 * @returns gate の終了 status と診断内容
 */
async function gate(
  pi: ExtensionAPI,
  kind: GateKind,
  payload: Record<string, unknown>,
  cwd: string,
  signal?: AbortSignal,
): Promise<{ code: number; text: string }> {
  try {
    const child = Bun.spawn([GATE, "hook", kind], {
      cwd,
      stdin: Buffer.from(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const completion = [new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited] as const;
    const finished = Promise.all(completion);
    const deadline = AbortSignal.timeout(GATE_TIMEOUT_MS);
    const stop = signal ? AbortSignal.any([deadline, signal]) : deadline;
    const interrupted = new Promise<"interrupted">((resolve) => {
      if (stop.aborted) resolve("interrupted");
      else stop.addEventListener("abort", () => resolve("interrupted"), { once: true });
    });
    let outcome: Awaited<typeof finished> | "interrupted";
    try {
      outcome = await Promise.race([finished, interrupted]);
    } catch (error) {
      await reclaim(pi, kind, child.pid, completion);
      throw error;
    }
    if (outcome === "interrupted") {
      // join 中に来た deadline による中断理由の上書きは不可
      const timedOut = deadline.aborted;
      await reclaim(pi, kind, child.pid, completion);
      return {
        code: -1,
        text: timedOut
          ? `Verification gate ${kind} timed out after ${GATE_TIMEOUT_MS / 1000}s.`
          : `Verification gate ${kind} was aborted.`,
      };
    }
    const [stdout, stderr] = outcome;
    const code = child.exitCode ?? -1;
    return {
      code,
      text: stdout.trim() || stderr.trim() || `Verification gate ${kind} exited with code ${code}.`,
    };
  } catch (error) {
    pi.logger.warn("verification gate could not run", { kind, error: String(error) });
    return { code: 1, text: `Verification gate ${kind} could not run: ${String(error)}` };
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
    if (EDITING_TOOLS[event.toolName] !== true) return;
    const held = await gate(pi, "edit", payload, ctx.cwd);
    if (held.code === 0) return;
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
    if (READING_TOOLS[event.toolName] === true) {
      if (event.isError) return;
      await gate(
        pi,
        "learn",
        {
          ...payload,
          hook_event_name: "PostToolUse",
          is_error: false,
          tool_result: { content: event.content, details: event.details },
        },
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
    if (held.code === 0) return;
    return { decision: "block" as const, reason: held.text };
  });
}
