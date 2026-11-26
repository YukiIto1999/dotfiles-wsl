import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "omp";
// 想起は最初の依頼の応答を待たせる。Hindsight の rerank は CPU の負荷で遅れ、load 27 では 15〜26 秒かかったため、
// 8 秒で諦めて警告だけを出し、依頼の処理を先に進める（2026-11-26 の実測）
const RECALL_TIMEOUT_MS = 8_000;

type Recalled = { context: string } | { warning: string };

function warn(pi: ExtensionAPI, ctx: ExtensionContext, message: string): void {
  pi.logger.warn(message);
  ctx.ui.notify(message, "warning");
}

// 子孫が出力 pipe を持つ場合があるため単一 process の kill と待機の打切りは不可
/**
 * 時間切れの recall の子と同じ process group の全回収
 * @param pid - 当該 recall の process group leader
 * @param completion - 当該子の終了監視と出力読取の Promise 一覧
 * @returns 全待機対象の settle 後の完了
 */
async function reclaim(pid: number, completion: readonly Promise<unknown>[]): Promise<void> {
  try {
    process.kill(-pid, "SIGKILL");
  } catch (error) {
    const missing = error && typeof error === "object" && "code" in error && error.code === "ESRCH";
    if (!missing) throw error;
  }
  await Promise.allSettled(completion);
}

/**
 * memory runtime の prompt-submit hook の一回の実行
 * @param payload - stdin に渡す session と project と prompt
 * @returns 注入する context か、利用者へ示す警告
 */
async function runRecall(payload: { session_id: string; cwd: string; prompt: string }): Promise<Recalled> {
  try {
    const child = Bun.spawn([MEMORY_BINARY, "hook", "--harness", MEMORY_HARNESS, "prompt-submit"], {
      cwd: payload.cwd,
      stdin: Buffer.from(JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const completion = [new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited] as const;
    const finished = Promise.all(completion);
    const { promise: expired, resolve } = Promise.withResolvers<"expired">();
    AbortSignal.timeout(RECALL_TIMEOUT_MS).addEventListener("abort", () => resolve("expired"), { once: true });
    let outcome: Awaited<typeof finished> | "expired";
    try {
      outcome = await Promise.race([finished, expired]);
    } catch (error) {
      await reclaim(child.pid, completion);
      throw error;
    }
    if (outcome === "expired") {
      await reclaim(child.pid, completion);
      return { warning: `Project memory recall timed out after ${RECALL_TIMEOUT_MS / 1000}s` };
    }
    const [stdout, stderr, code] = outcome;
    if (code !== 0) return { warning: `Project memory recall failed: ${stderr.trim() || `exit ${code}`}` };
    return { context: stdout.trim() };
  } catch (error) {
    return { warning: `Project memory recall could not run: ${String(error)}` };
  }
}

export default function projectMemory(pi: ExtensionAPI): void {
  // 想起は session ごとに、run を始めた最初の依頼の一回だけ。後の依頼、継続、停止 hook の再投入は注入済みの文脈を会話に持つ。
  // 失敗した想起も繰り返さない。依頼のたびの数秒の待ちが利益を上回るため
  const recalled = new Set<string>();
  pi.on("session_shutdown", () => recalled.clear());

  pi.on("before_agent_start", async (event, ctx) => {
    if (event.reason !== "prompt" || event.prompt.trim() === "") return;
    const sessionId = ctx.sessionManager.getSessionId();
    if (recalled.has(sessionId)) return;
    recalled.add(sessionId);
    const outcome = await runRecall({ session_id: sessionId, cwd: ctx.cwd, prompt: event.prompt });
    if ("warning" in outcome) {
      warn(pi, ctx, outcome.warning);
      return;
    }
    if (!outcome.context) return;
    return {
      message: {
        customType: "project-memory-context",
        content: outcome.context,
        display: false,
        attribution: "agent",
      },
    };
  });
}
