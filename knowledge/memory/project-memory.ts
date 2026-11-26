import { createHash } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "omp";
const RECALL_TIMEOUT_MS = 30_000;

type Recalled = { context: string } | { warning: string };

/** session ごとの入力と停止の観測 */
interface Ingress {
  /** input event の累計 */
  submitted: number;
  /** recall を始めた時点で処理済みとみなした submitted */
  handled: number;
  /** 停止からの再開に対する記憶の再取得を抑える継続待機の印 */
  stopped: boolean;
  /** 開始通知と入力の対応を特定できない重複入力の印 */
  overlapping: boolean;
}

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
  // prompt 全文の保持と file への保存は入力の残存になるため不可
  const recalls = new Map<string, Map<string, Promise<string>>>();
  const ingress = new Map<string, Ingress>();

  const sessionOf = (ctx: ExtensionContext) => ctx.sessionManager.getSessionId();

  function ingressOf(sessionId: string): Ingress {
    let state = ingress.get(sessionId);
    if (!state) {
      state = { submitted: 0, handled: 0, stopped: false, overlapping: false };
      ingress.set(sessionId, state);
    }
    return state;
  }

  async function recall(ctx: ExtensionContext, prompt: string): Promise<string> {
    const outcome = await runRecall({ session_id: sessionOf(ctx), cwd: ctx.cwd, prompt });
    if ("warning" in outcome) {
      warn(pi, ctx, outcome.warning);
      return "";
    }
    return outcome.context;
  }

  // prompt の同一性だけの再利用は同文の新しい入力へ古い記憶を返すため不可
  pi.on("input", (_event, ctx) => {
    const sessionId = sessionOf(ctx);
    const state = ingressOf(sessionId);
    state.overlapping ||= state.stopped || state.submitted !== state.handled || recalls.has(sessionId);
    state.submitted++;
    recalls.delete(sessionId);
  });

  pi.on("session_stop", (_event, ctx) => {
    ingressOf(sessionOf(ctx)).stopped = true;
  });

  // 先行 hook の block で通知が途切れるため session_stop 単独による継続判定は不可
  pi.on("agent_end", (event, ctx) => {
    const sessionId = sessionOf(ctx);
    const state = ingressOf(sessionId);
    state.stopped = event.willContinue === true;
    if (!state.stopped) {
      recalls.delete(sessionId);
      if (!ctx.hasPendingMessages()) state.overlapping = false;
    }
  });

  const forgetAll = () => {
    recalls.clear();
    ingress.clear();
  };
  pi.on("session_switch", forgetAll);
  pi.on("session_shutdown", forgetAll);

  pi.on("before_agent_start", async (event, ctx) => {
    if (event.reason !== "prompt" || event.prompt.trim() === "") return;
    const sessionId = sessionOf(ctx);
    const state = ingressOf(sessionId);
    // prompt の本文だけの判定は文面が変わる再開を新しい要求として再取得するため不可
    const resumption = !state.overlapping && state.stopped && state.submitted === state.handled;
    if (resumption) return;
    state.stopped = false;
    state.handled = state.submitted;

    let context: Promise<string>;
    // 混在した入力と開始通知を対応づけられないため抑止と再利用による取得の省略は不可
    if (state.overlapping) {
      context = recall(ctx, event.prompt);
    } else {
      let session = recalls.get(sessionId);
      if (!session) {
        session = new Map();
        recalls.set(sessionId, session);
      }
      const key = `${ctx.cwd}\0${createHash("sha256").update(event.prompt).digest("hex")}`;
      const cached = session.get(key);
      context = cached ?? recall(ctx, event.prompt);
      if (!cached) session.set(key, context);
    }
    const text = await context;
    if (!text) return;
    return {
      message: {
        customType: "project-memory-context",
        content: text,
        display: false,
        attribution: "agent",
      },
    };
  });
}
