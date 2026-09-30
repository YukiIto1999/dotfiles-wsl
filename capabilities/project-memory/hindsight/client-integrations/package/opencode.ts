import type { Plugin } from "@opencode-ai/plugin";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "opencode";
const HOST_TIMEOUT_MS = 30000;

type Part = { type?: string; text?: string; synthetic?: boolean; ignored?: boolean };
type HookResult = { code: number; stdout: string; stderr: string };

function textOf(parts: Part[] | undefined): string {
  if (!parts) return "";
  return parts
    .filter((part) => part?.type === "text" && typeof part.text === "string" && !part.synthetic && !part.ignored)
    .map((part) => part.text)
    .join("\n")
    .trim();
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
  };
};

async function runHook(cwd: string, event: string, payload: Record<string, unknown>): Promise<HookResult> {
  const signal = AbortSignal.timeout(HOST_TIMEOUT_MS);
  try {
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

const projectMemoryPlugin: Plugin = async (input: PluginInput) => {
  const cwd = input.worktree || input.directory || process.cwd();
  const pendingInjections = new Map<string, { context: string }>();

  return {
    "chat.message": async (
      event: { sessionID?: string },
      output: { parts?: Part[] },
    ) => {
      const sessionID = event.sessionID;
      if (!sessionID) return;
      const pending = { context: "" };
      pendingInjections.set(sessionID, pending);
      const result = await runHook(cwd, "prompt-submit", {
        cwd,
        session_id: sessionID,
        prompt: textOf(output.parts),
      });
      if (result.code !== 0) {
        await warn(input.client, `[project-memory] prompt-submit failed: ${result.stderr || `exit ${result.code}`}`);
      }
      if (pendingInjections.get(sessionID) === pending) {
        pending.context = result.code === 0 ? result.stdout : "";
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
      if (inputEvent.event?.type !== "session.idle") return;
      const sessionID = inputEvent.event.properties?.sessionID;
      if (sessionID) pendingInjections.delete(sessionID);
    },
  };
};

export default projectMemoryPlugin;
