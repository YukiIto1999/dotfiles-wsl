import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "omp";
const MAX_CAPTURE_ENTRIES = 128;
const MAX_CAPTURE_CHARS = 12000;

type CapturedMessage =
  | { role: "user"; content: string }
  | { role: "assistant"; content: string; complete: boolean };

type BranchEntry = {
  type?: string;
  parentId?: string | null;
  message?: {
    role?: string;
    content?: unknown;
    stopReason?: string;
  };
};

type TextPart = { type: "text"; text: string };

function isTextPart(part: unknown): part is TextPart {
  if (typeof part !== "object" || part === null) return false;
  if (!("type" in part) || !("text" in part)) return false;
  return part.type === "text" && typeof part.text === "string";
}

function sessionPayload(ctx: ExtensionContext): { session_id: string; cwd: string } {
  return {
    session_id: ctx.sessionManager.getSessionId(),
    cwd: ctx.cwd,
  };
}

function textContent(content: unknown, remaining: number): string {
  if (typeof content === "string") {
    if (content.length > remaining) throw new Error("capture exceeds the text limit");
    return content.trim();
  }
  if (!Array.isArray(content)) return "";
  if (content.length > MAX_CAPTURE_ENTRIES) throw new Error("capture exceeds the part limit");
  const text: string[] = [];
  for (const part of content) {
    if (!isTextPart(part)) continue;
    remaining -= part.text.length + 1;
    if (remaining < 0) throw new Error("capture exceeds the text limit");
    text.push(part.text);
  }
  return text.join("\n").trim();
}

function branchMessages(ctx: ExtensionContext): CapturedMessage[] {
  const messages: CapturedMessage[] = [];
  let remaining = MAX_CAPTURE_CHARS;
  let id = ctx.sessionManager.getLeafId();
  for (let count = 0; id && count < MAX_CAPTURE_ENTRIES; count++) {
    const entry: BranchEntry | undefined = ctx.sessionManager.getEntry(id);
    if (!entry) throw new Error("capture history is incomplete");
    id = entry.parentId ?? null;
    const role = entry.type === "message" ? entry.message?.role : undefined;
    if (role !== "user" && role !== "assistant") continue;
    const content = textContent(entry.message?.content, remaining);
    remaining -= content.length + 32;
    if (remaining < 0) throw new Error("capture exceeds the text limit");
    if (role === "user") {
      if (!content || messages.length === 0) return [];
      messages.push({ role, content });
      return messages.reverse();
    }
    messages.push({ role, content, complete: entry.message?.stopReason === "stop" });
  }
  if (id || messages.length) throw new Error("capture has no user boundary within the history limit");
  return [];
}

function warn(pi: ExtensionAPI, ctx: ExtensionContext, message: string): void {
  pi.logger.warn(message);
  ctx.ui.notify(message, "warning");
}

async function runHook(
  pi: ExtensionAPI,
  name: string,
  payload: Record<string, unknown>,
  ctx: ExtensionContext,
  signal?: AbortSignal,
): Promise<string> {
  if (signal?.aborted) return "";
  try {
    const child = Bun.spawn(
      [MEMORY_BINARY, "hook", "--harness", MEMORY_HARNESS, name],
      { cwd: ctx.cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe" },
    );
    const abort = () => child.kill();
    const timer = setTimeout(abort, 30000);
    signal?.addEventListener("abort", abort, { once: true });
    try {
      child.stdin.write(JSON.stringify(payload));
      child.stdin.end();
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      if (code !== 0) {
        warn(pi, ctx, `Project memory ${name} failed: ${stderr.trim() || `exit ${code}`}`);
        return "";
      }
      return stdout.trim();
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
    }
  } catch (error) {
    warn(pi, ctx, `Project memory ${name} could not run: ${String(error)}`);
    return "";
  }
}

function warnCaptureResult(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  name: string,
  output: string,
): void {
  if (!output) return;
  try {
    const receipt: unknown = JSON.parse(output);
    if (
      typeof receipt === "object" &&
      receipt !== null &&
      "state" in receipt &&
      receipt.state !== "saved"
    ) {
      const operationId = "operation_id" in receipt && typeof receipt.operation_id === "string"
        ? receipt.operation_id
        : "unknown";
      const documentId = "document_id" in receipt && typeof receipt.document_id === "string"
        ? receipt.document_id
        : "unknown";
      warn(pi, ctx, `Project memory capture ${String(receipt.state)}, not verified saved; operation_id=${operationId}; document_id=${documentId}`);
    }
  } catch {
    warn(pi, ctx, `Project memory ${name} returned an invalid capture receipt`);
  }
}

async function capture(
  pi: ExtensionAPI,
  name: "pre-compact" | "stop" | "session-end",
  ctx: ExtensionContext,
  signal?: AbortSignal,
  turn_id?: string,
): Promise<void> {
  if (signal?.aborted) return;
  try {
    const messages = branchMessages(ctx);
    if (messages.length === 0) return;
    const payload = {
      ...sessionPayload(ctx),
      messages,
      ...(turn_id ? { turn_id } : {}),
    };
    const output = await runHook(pi, name, payload, ctx, signal);
    warnCaptureResult(pi, ctx, name, output);
  } catch (error) {
    warn(pi, ctx, `Project memory ${name} capture could not run: ${String(error)}`);
  }
}

export default function projectMemory(pi: ExtensionAPI): void {
  pi.on("before_agent_start", async (event, ctx) => {
    const context = await runHook(
      pi,
      "prompt-submit",
      {
        ...sessionPayload(ctx),
        prompt: event.prompt,
      },
      ctx,
    );
    if (!context) return;
    return {
      message: {
        customType: "project-memory-context",
        content: context,
        display: false,
        attribution: "agent",
      },
    };
  });

  pi.on("session_before_compact", async (event, ctx) => {
    await capture(pi, "pre-compact", ctx, event.signal);
  });

  pi.on("session_stop", async (event, ctx) => {
    await capture(pi, "stop", ctx, event.signal, event.turn_id);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    await capture(pi, "session-end", ctx);
  });
}
