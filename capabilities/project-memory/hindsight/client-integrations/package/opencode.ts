import type { Plugin } from "@opencode-ai/plugin";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "opencode";
const HOST_TIMEOUT_MS = 30000;
const MAX_CAPTURE_MESSAGES = 128;
const MAX_CAPTURE_CHARS = 12000;

type Part = { type?: string; text?: string; synthetic?: boolean; ignored?: boolean };
type OcMessage = {
  info?: {
    role?: string; summary?: unknown; error?: unknown;
    time?: { completed?: number }; finish?: string;
  };
  parts?: Part[];
};
type CaptureMessage =
  | { role: "user"; content: string }
  | { role: "assistant"; content: string; complete: boolean };
type HookResult = { code: number; stdout: string; stderr: string };

function textOf(parts: Part[] | undefined, remaining = 128000): string {
  if (!parts) return "";
  if (parts.length > MAX_CAPTURE_MESSAGES) throw new Error("capture exceeds the part limit");
  const text: string[] = [];
  for (const part of parts) {
    if (part?.type !== "text" || typeof part.text !== "string" || part.synthetic || part.ignored) continue;
    remaining -= part.text.length + 1;
    if (remaining < 0) throw new Error("capture exceeds the text limit");
    text.push(part.text);
  }
  return text.join("\n").trim();
}

function captureMessages(history: OcMessage[]): CaptureMessage[] {
  const messages: CaptureMessage[] = [];
  let remaining = MAX_CAPTURE_CHARS;
  for (let index = history.length - 1, count = 0; index >= 0 && count < MAX_CAPTURE_MESSAGES; index--, count++) {
    const message = history[index];
    const role = message.info?.role;
    if (role !== "user" && role !== "assistant") continue;
    if (message.info?.summary === true) return [];
    const content = textOf(message.parts, remaining);
    remaining -= content.length + 32;
    if (remaining < 0) throw new Error("capture exceeds the text limit");
    if (role === "user") {
      if (!content || messages.length === 0) return [];
      messages.push({ role, content });
      return messages.reverse();
    }
    messages.push({
      role, content,
      complete: message.info?.finish === "stop"
        && typeof message.info.time?.completed === "number"
        && message.info.error === undefined,
    });
  }
  if (history.length >= MAX_CAPTURE_MESSAGES || messages.length) {
    throw new Error("capture has no user boundary within the history limit");
  }
  return [];
}

type PluginInput = {
  worktree?: string;
  directory?: string;
  client: {
    tui: {
      showToast: (input: {
        body: { message: string; variant: "warning" };
        signal: AbortSignal;
      }) => Promise<unknown>;
    };
    session: {
      messages: (input: {
        path: { id: string };
        query: { limit: number };
        signal: AbortSignal;
      }) => Promise<{ data?: OcMessage[]; error?: unknown }>;
    };
  };
};

async function runHook(
  cwd: string,
  event: string,
  payload: Record<string, unknown>,
  signal: AbortSignal = AbortSignal.timeout(HOST_TIMEOUT_MS),
): Promise<HookResult> {
  try {
    signal.throwIfAborted();
    const child = Bun.spawn(
      [MEMORY_BINARY, "hook", "--harness", MEMORY_HARNESS, event],
      { cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe" },
    );
    const abort = () => child.kill();
    signal.addEventListener("abort", abort, { once: true });
    try {
      child.stdin.write(JSON.stringify(payload));
      child.stdin.end();
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      return { code, stdout: stdout.trim(), stderr: stderr.trim() };
    } finally {
      signal.removeEventListener("abort", abort);
    }
  } catch (error) {
    return { code: 1, stdout: "", stderr: String(error) };
  }
}

async function warn(client: PluginInput["client"], message: string): Promise<void> {
  console.warn(message);
  try {
    await client.tui.showToast({
      body: { message, variant: "warning" },
      signal: AbortSignal.timeout(1000),
    });
  } catch {
    console.warn("[project-memory] Could not display the warning in the client");
  }
}

async function warnFailure(client: PluginInput["client"], event: string, result: HookResult): Promise<void> {
  if (result.code === 0) return;
  await warn(client, `[project-memory] ${event} failed: ${result.stderr || `exit ${result.code}`}`);
}

async function warnCaptureResult(client: PluginInput["client"], event: string, stdout: string): Promise<void> {
  if (!stdout) return;
  try {
    const receipt: unknown = JSON.parse(stdout);
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
      await warn(client, `[project-memory] ${event} capture ${String(receipt.state)}, not verified saved; operation_id=${operationId}; document_id=${documentId}`);
    }
  } catch {
    await warn(client, `[project-memory] ${event} returned an unreadable capture receipt`);
  }
}

const projectMemoryPlugin: Plugin = async (input: PluginInput) => {
  const cwd = input.worktree || input.directory || process.cwd();
  const pendingInjections = new Map<string, { context: string }>();
  const captures = new Set<Promise<void>>();
  let disposed = false;

  return {
    dispose: async () => {
      disposed = true;
      await Promise.all(captures);
    },

    "chat.message": async (
      event: { sessionID?: string },
      output: { parts?: Part[] },
    ) => {
      const sessionID = event.sessionID;
      if (!sessionID) return;
      const pending = { context: "" };
      pendingInjections.set(sessionID, pending);
      try {
        const result = await runHook(cwd, "prompt-submit", {
          cwd,
          session_id: sessionID,
          prompt: textOf(output.parts),
        });
        await warnFailure(input.client, "prompt-submit", result);
        if (pendingInjections.get(sessionID) === pending) {
          pending.context = result.code === 0 ? result.stdout : "";
        }
      } catch (error) {
        await warn(input.client, `[project-memory] prompt recall could not run: ${String(error)}`);
      }
    },

    "experimental.chat.system.transform": async (
      event: { sessionID?: string },
      output: { system: string[] },
    ) => {
      if (!event.sessionID) return;
      const pending = pendingInjections.get(event.sessionID);
      if (!pending?.context) return;
      output.system.push(pending.context);
    },

    event: async (inputEvent: {
      event?: { type?: string; properties?: { sessionID?: string } };
    }) => {
      if (disposed || inputEvent.event?.type !== "session.idle") return;
      const sessionID = inputEvent.event.properties?.sessionID;
      if (!sessionID) return;
      pendingInjections.delete(sessionID);
      const capture = (async () => {
        const signal = AbortSignal.timeout(HOST_TIMEOUT_MS - 1000);
        try {
          const response = await input.client.session.messages({
            path: { id: sessionID },
            query: { limit: MAX_CAPTURE_MESSAGES },
            signal,
          });
          if (response.error) throw new Error("session history request failed");
          signal.throwIfAborted();
          const messages = captureMessages(response.data ?? []);
          if (messages.length === 0) return;
          const result = await runHook(cwd, "stop", {
            cwd,
            session_id: sessionID,
            messages,
          }, signal);
          if (result.code !== 0) {
            await warnFailure(input.client, "stop", result);
            return;
          }
          await warnCaptureResult(input.client, "stop", result.stdout);
        } catch (error) {
          await warn(input.client, `[project-memory] stop capture could not run: ${String(error)}`);
        }
      })();
      captures.add(capture);
      try {
        await capture;
      } finally {
        captures.delete(capture);
      }
    },
  };
};

export default projectMemoryPlugin;
