import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const MEMORY_BINARY = "@memoryBinary@";
const MEMORY_HARNESS = "omp";

function warn(pi: ExtensionAPI, ctx: ExtensionContext, message: string): void {
  pi.logger.warn(message);
  ctx.ui.notify(message, "warning");
}

async function recall(pi: ExtensionAPI, prompt: string, ctx: ExtensionContext): Promise<string> {
  try {
    const child = Bun.spawn(
      [MEMORY_BINARY, "hook", "--harness", MEMORY_HARNESS, "prompt-submit"],
      { cwd: ctx.cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe" },
    );
    const timer = setTimeout(() => child.kill(), 30000);
    try {
      child.stdin.write(JSON.stringify({
        session_id: ctx.sessionManager.getSessionId(),
        cwd: ctx.cwd,
        prompt,
      }));
      child.stdin.end();
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      if (code !== 0) {
        warn(pi, ctx, `Project memory recall failed: ${stderr.trim() || `exit ${code}`}`);
        return "";
      }
      return stdout.trim();
    } finally {
      clearTimeout(timer);
    }
  } catch (error) {
    warn(pi, ctx, `Project memory recall could not run: ${String(error)}`);
    return "";
  }
}

export default function projectMemory(pi: ExtensionAPI): void {
  pi.on("before_agent_start", async (event, ctx) => {
    const context = await recall(pi, event.prompt, ctx);
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
}
