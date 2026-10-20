import { beforeAll, expect, test } from "bun:test";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Handler = (event: Record<string, unknown>, ctx: unknown) => Promise<unknown>;
type Handlers = Map<string, Handler>;

const TEST_TIMEOUT_MS = 60_000;
const home = process.env.HOME as string;
const workDir = join(home, "work");
const skillBody = join(home, ".omp/agent/skills/ui-design/SKILL.md");
const GUARDED_PATH = "/r/surfaces/viewer/x.tsx";
const FREE_PATH = "/r/docs/note.md";
const LARGE_WRITE = 3 * 1024 * 1024;
const COMPLETE = `# ui-design\n${Array.from(
  { length: 6000 },
  (_, index) => `Discipline line ${index + 1} stays in the body so the read exceeds one argument.`,
).join("\n")}\n`;

let real: Handlers;
let hanging: Handlers;

async function load(hookPath: string): Promise<Handlers> {
  const { default: verificationGate } = await import(hookPath);
  const handlers: Handlers = new Map();
  verificationGate({
    on: (name: string, handler: Handler) => handlers.set(name, handler),
    logger: { warn: () => undefined },
  });
  return handlers;
}

function handlerOf(handlers: Handlers, name: string): Handler {
  const handler = handlers.get(name);
  if (!handler) throw new Error(`the hook registered no ${name} handler`);
  return handler;
}

const context = (session: string, cwd = workDir) => ({
  cwd,
  sessionManager: { getSessionId: () => session },
});

const write = (handlers: Handlers, session: string, input: Record<string, unknown>, cwd = workDir) =>
  handlerOf(handlers, "tool_call")({ toolName: "write", toolCallId: `${session}-write`, input }, context(session, cwd));

function readEvent(session: string, shown: string) {
  const lines = shown.split("\n");
  return {
    toolName: "read",
    toolCallId: `${session}-read`,
    input: { path: skillBody },
    isError: false,
    content: [{ type: "text", text: shown }],
    details: {
      resolvedPath: skillBody,
      totalLines: lines.length,
      displayContent: { text: shown, startLine: 1, lineNumbers: lines.map((_, index) => index + 1) },
    },
  };
}

const learn = (session: string, event: Record<string, unknown>) =>
  handlerOf(real, "tool_result")(event, context(session));

async function expectBlockedForSkill(session: string, content = "x") {
  const outcome = (await write(real, session, { path: GUARDED_PATH, content })) as { block: true; reason: string };
  expect(outcome.block).toBe(true);
  expect(outcome.reason).toContain("skill://ui-design");
}

/** pid の再利用と元の process の消滅を区別する同一 boot 内の観測情報 */
interface ProcessIdentity {
  /** 観測した Linux process 番号 */
  pid: number;
  /** 同じ boot 内で照合する /proc の開始 tick */
  started: string;
}

// comm の空白や括弧のため先頭からの field 分割は不可
/**
 * gate の親子関係と寿命を照合する Linux process 情報の観測
 * @param pid - 観測対象の Linux process 番号
 * @returns 状態と親 pid と開始 tick を持つ観測値または読取不能時の undefined
 */
function statOf(pid: number): { state: string; parent: number; started: string } | undefined {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return { state: fields[0], parent: Number(fields[1]), started: fields[19] };
  } catch {
    return undefined;
  }
}

/**
 * 返却時点にまだ動く子孫を検出する生存判定
 * @param pid - 当該 fixture が起動した process 番号
 * @returns 読取可能な非 zombie process なら true
 */
function isRunning(pid: number): boolean {
  const stat = statOf(pid);
  return stat !== undefined && stat.state !== "Z" && stat.state !== "X";
}

// pid だけの照合は再利用された別 process を同じ子と誤認するため不可
/**
 * 同じ pid の zombie を完了としない元 process の消滅判定
 * @param identity - 終了待機前に取得した同一 boot 内の process 情報
 * @returns 元の観測値が消失した場合か別の開始 tick へ変わった場合の true
 */
function isReaped(identity: ProcessIdentity): boolean {
  const stat = statOf(identity.pid);
  return stat === undefined || stat.started !== identity.started;
}

async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = performance.now() + 10_000;
  while (!condition()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(20);
  }
}

async function descendantOf(cwd: string): Promise<number> {
  const file = join(cwd, "descendant.pid");
  await until(() => existsSync(file) && /^\d+$/.test(readFileSync(file, "utf8").trim()), "the gate's descendant");
  return Number(readFileSync(file, "utf8").trim());
}

/**
 * 取消直前の gate と子孫の寿命を比較する観測情報の取得
 * @param cwd - hanging gate が子孫の pid を記録する fixture directory
 * @returns 呼出元が直接所有する gate の識別情報を含む観測値
 * @throws {@link Error} 観測期限内に揃わない gate の識別情報
 */
async function hangingGateOf(cwd: string): Promise<{ gate: ProcessIdentity; descendant: number }> {
  const descendant = await descendantOf(cwd);
  const parent = statOf(descendant)?.parent;
  const gate = parent === undefined ? undefined : statOf(parent);
  if (parent === undefined || gate === undefined) throw new Error("the hanging gate ended before the hook was interrupted");
  expect(gate.parent).toBe(process.pid);
  return { gate: { pid: parent, started: gate.started }, descendant };
}

beforeAll(async () => {
  mkdirSync(dirname(skillBody), { recursive: true });
  mkdirSync(workDir, { recursive: true });
  real = await load(process.env.GATE_HOOK as string);
  hanging = await load(process.env.HANGING_GATE_HOOK as string);
});

test("small events keep refusing unread disciplines and accept read ones", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  expect(await write(real, "small-free", { path: FREE_PATH, content: "note" })).toBeUndefined();
  await expectBlockedForSkill("small");
  await learn("small", readEvent("small", "# ui-design\nShort discipline."));
  expect(await write(real, "small", { path: GUARDED_PATH, content: "x" })).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a write larger than the argv limits reaches the gate", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  const content = "x".repeat(LARGE_WRITE);
  expect(await write(real, "large-write-free", { path: FREE_PATH, content })).toBeUndefined();
  await expectBlockedForSkill("large-write-unread", content);
}, TEST_TIMEOUT_MS);

test("only a complete read beyond the argv limit counts as reading the discipline", async () => {
  writeFileSync(skillBody, COMPLETE);
  const shown = COMPLETE.slice(0, -1);
  const content = "x".repeat(LARGE_WRITE);
  const altered = `${shown.slice(0, 100_000)}§${shown.slice(100_001)}`;
  const refused: Record<string, Record<string, unknown>> = {
    truncated: readEvent("large-truncated", shown.slice(0, -2000)),
    altered: readEvent("large-altered", altered),
    "altered-rendered": {
      ...readEvent("large-altered-rendered", shown),
      content: [{ type: "text", text: altered }],
    },
    "no-display": {
      ...readEvent("large-no-display", shown),
      details: { resolvedPath: skillBody, totalLines: 6001 },
    },
    "no-result": { ...readEvent("large-no-result", shown), content: [], details: undefined },
  };
  for (const [name, event] of Object.entries(refused)) {
    const session = `large-${name}`;
    await learn(session, event);
    await expectBlockedForSkill(session, content);
  }

  await expectBlockedForSkill("large-complete", content);
  await learn("large-complete", readEvent("large-complete", shown));
  expect(await write(real, "large-complete", { path: GUARDED_PATH, content })).toBeUndefined();

  appendFileSync(skillBody, "Changed after the read.\n");
  await expectBlockedForSkill("large-complete", content);
  await learn("large-replayed", readEvent("large-replayed", shown));
  await expectBlockedForSkill("large-replayed", content);
}, TEST_TIMEOUT_MS);

test("unsatisfied stop feedback returns control without accepting the audit and blocks a fresh stop again", async () => {
  const session = "incomplete-conformance-feedback";
  const body = join(home, ".omp/agent/skills/standard-conformance/SKILL.md");
  const shown = "# standard-conformance\nAudit instructions.";
  mkdirSync(dirname(body), { recursive: true });
  writeFileSync(body, `${shown}\n`);
  const event = readEvent(session, shown);
  event.input.path = body;
  event.details.resolvedPath = body;
  const notices: { message: string; type: string }[] = [];
  const ctx = {
    ...context(session),
    ui: { notify: (message: string, type: string) => notices.push({ message, type }) },
  };
  await handlerOf(real, "tool_result")(event, ctx);
  const stop = handlerOf(real, "session_stop");
  const first = (await stop({ stop_hook_active: false }, ctx)) as { decision: string; reason: string };
  expect(first.decision).toBe("block");
  const receipt = join(home, ".cache/dotfiles-wsl/verification/sessions", session, "conformance/receipt.json");
  expect(existsSync(receipt)).toBe(false);

  expect(await stop({ stop_hook_active: true }, ctx)).toBeUndefined();
  expect(notices).toEqual([{ message: first.reason, type: "warning" }]);
  expect(existsSync(receipt)).toBe(false);
  expect(await stop({ stop_hook_active: false }, ctx)).toMatchObject({ decision: "block" });
}, TEST_TIMEOUT_MS);

test("an aborted stop hook returns after the gate is reaped and its descendants have stopped", async () => {
  const cwd = join(home, "abort");
  mkdirSync(cwd, { recursive: true });
  const controller = new AbortController();
  const pending = handlerOf(hanging, "session_stop")(
    { signal: controller.signal, stop_hook_active: false },
    context("abort", cwd),
  );
  const { gate, descendant } = await hangingGateOf(cwd);
  expect(isRunning(descendant)).toBe(true);
  controller.abort();
  const outcome = await pending;
  // 返却後の待ち直しは返却時点の寿命を検証できないため不可
  const returned = { gateReaped: isReaped(gate), descendantRunning: isRunning(descendant) };
  expect(outcome).toMatchObject({ decision: "block" });
  expect(returned).toEqual({ gateReaped: true, descendantRunning: false });
}, TEST_TIMEOUT_MS);

test("a gate that outlives its deadline blocks the edit and the hook returns after the gate is reaped and its descendants have stopped", async () => {
  const cwd = join(home, "deadline");
  mkdirSync(cwd, { recursive: true });
  const started = performance.now();
  const pending = write(hanging, "deadline", { path: FREE_PATH, content: "x" }, cwd);
  const { gate, descendant } = await hangingGateOf(cwd);
  expect(isRunning(descendant)).toBe(true);
  const outcome = await pending;
  const returned = { gateReaped: isReaped(gate), descendantRunning: isRunning(descendant) };
  expect(outcome).toMatchObject({ block: true });
  expect(returned).toEqual({ gateReaped: true, descendantRunning: false });
  expect(performance.now() - started).toBeGreaterThanOrEqual(19_000);
}, TEST_TIMEOUT_MS);

test("a hook loaded for one generation keeps its own gate after the next generation's hook loads", async () => {
  writeFileSync(skillBody, "# ui-design\nShort discipline.\n");
  const calls = join(home, "next-generation-gate.calls");
  const next = await load(process.env.NEXT_GENERATION_GATE_HOOK as string);
  expect(await write(next, "next-session", { path: GUARDED_PATH, content: "x" })).toBeUndefined();
  const recorded = readFileSync(calls, "utf8");
  expect(recorded).toContain("hook edit");
  await expectBlockedForSkill("older-session");
  expect(readFileSync(calls, "utf8")).toBe(recorded);
}, TEST_TIMEOUT_MS);
