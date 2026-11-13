import { beforeAll, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Handler = (event: Record<string, unknown>, ctx: unknown) => Promise<unknown>;
type Handlers = Map<string, Handler>;

const TEST_TIMEOUT_MS = 60_000;
const home = process.env.HOME as string;
const workDir = join(home, "work");
const LARGE_WRITE = 3 * 1024 * 1024;
const nextGenerationGateCalls = join(home, "next-generation-gate.calls");
// 以前は Skill の読取を編集の前提にしていた綴り。いまは通常の編集と同じく、検証の状態だけが終了を止める。
const FORMERLY_GUARDED_PATHS = ["surfaces/viewer/App.tsx", "core/domain/Invoice.cs", "core/library.ts"];

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

/**
 * write の成功後に OMP が送る tool_result の呼出し
 * @param session - hook へ渡す session の ID
 * @param input - write の入力
 * @returns hook の完了
 */
const writeSucceeded = (session: string, input: Record<string, unknown>) =>
  handlerOf(real, "tool_result")(
    { toolName: "write", toolCallId: `${session}-write`, input, isError: false },
    context(session),
  );

const verificationRoot = join(home, ".cache/dotfiles-wsl/verification");

function git(repository: string, ...args: string[]): void {
  execFileSync("git", ["-C", repository, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", ...args], {
    stdio: "ignore",
  });
}

/**
 * 宣言した T1 の入口を、いまの木に対してまだ通していない repository の作成
 * @param name - home 直下に置く repository の directory 名
 * @returns 作成した repository の根の絶対 path
 */
function unverifiedT1Repository(name: string): string {
  const repository = join(home, name);
  mkdirSync(repository, { recursive: true });
  git(repository, "init", "-q");
  writeFileSync(join(repository, "devenv.nix"), 'scripts.verify.exec = "true";\n');
  writeFileSync(join(repository, "verification-budget.json"), '{"version":1,"verify":{"seconds":60}}\n');
  writeFileSync(join(repository, "tracked"), "held\n");
  git(repository, "add", "devenv.nix", "verification-budget.json", "tracked");
  git(repository, "commit", "-q", "-m", "initial");
  return repository;
}

/** gate が検証の完了または免除として残した証跡の一覧 */
function settledReceipts(): string[] {
  if (!existsSync(verificationRoot)) return [];
  return readdirSync(verificationRoot, { recursive: true })
    .map(String)
    .filter((name) => name.endsWith(".verified") || name.endsWith(".waived"));
}

/**
 * 再記録用の gate が受けた呼出しの一覧
 * @returns 呼出し 1 回につき hook の引数を並べた 1 行の一覧
 */
function gateCalls(): string[] {
  if (!existsSync(nextGenerationGateCalls)) return [];
  return readFileSync(nextGenerationGateCalls, "utf8").split("\n").filter((line) => line !== "");
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
  mkdirSync(workDir, { recursive: true });
  real = await load(process.env.GATE_HOOK as string);
  hanging = await load(process.env.HANGING_GATE_HOOK as string);
});

test("a write larger than the argv limits still registers the repository it changed", async () => {
  const session = "large-write";
  const repository = unverifiedT1Repository("large-write-t1");
  const tracked = join(repository, "tracked");
  const content = "x".repeat(LARGE_WRITE);
  writeFileSync(tracked, content);
  await writeSucceeded(session, { path: tracked, content });
  const blocked = (await handlerOf(real, "session_stop")({ stop_hook_active: false }, context(session))) as {
    decision: string;
    reason: string;
  };
  expect(blocked.decision).toBe("block");
  expect(blocked.reason).toContain(realpathSync(repository));
}, TEST_TIMEOUT_MS);

test("an edit is never held for an unread Skill, and only the unverified tree holds the stop", async () => {
  const session = "mechanical-edits";
  const repository = unverifiedT1Repository("mechanical-edits-t1");
  const files = FORMERLY_GUARDED_PATHS.map((path) => join(repository, path));
  for (const file of files) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, "held\n");
  }
  git(repository, "add", ...FORMERLY_GUARDED_PATHS);
  git(repository, "commit", "-q", "-m", "formerly guarded paths");
  for (const file of files) {
    writeFileSync(file, "edited\n");
    const input = { path: file, content: "edited\n" };
    expect(await write(hanging, session, input)).toBeUndefined();
    expect(await write(real, session, input)).toBeUndefined();
    await writeSucceeded(session, input);
  }
  const blocked = (await handlerOf(real, "session_stop")({ stop_hook_active: false }, context(session))) as {
    decision: string;
    reason: string;
  };
  expect(blocked.decision).toBe("block");
  expect(blocked.reason).toContain(realpathSync(repository));
  expect(blocked.reason).toContain("dotfiles-agent-verify -- devenv shell -- verify");
}, TEST_TIMEOUT_MS);

test("an unverified T1 stop returns control on the repeated request without settling it and blocks a fresh stop again", async () => {
  const session = "unverified-t1-feedback";
  const repository = unverifiedT1Repository("unverified-t1");
  const tracked = join(repository, "tracked");
  writeFileSync(tracked, "edited\n");
  const notices: { message: string; type: string }[] = [];
  const ctx = {
    ...context(session),
    ui: { notify: (message: string, type: string) => notices.push({ message, type }) },
  };
  await handlerOf(real, "tool_result")(
    { toolName: "write", toolCallId: `${session}-write`, input: { path: tracked }, isError: false },
    ctx,
  );
  const stop = handlerOf(real, "session_stop");
  const first = (await stop({ stop_hook_active: false }, ctx)) as { decision: string; reason: string };
  expect(first.decision).toBe("block");
  expect(first.reason).toContain(realpathSync(repository));
  expect(first.reason).toContain("dotfiles-agent-verify -- devenv shell -- verify");
  expect(settledReceipts()).toEqual([]);

  expect(await stop({ stop_hook_active: true }, ctx)).toBeUndefined();
  expect(notices).toEqual([{ message: first.reason, type: "warning" }]);
  expect(settledReceipts()).toEqual([]);
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

test("a gate that outlives its deadline blocks the stop and the hook returns after the gate is reaped and its descendants have stopped", async () => {
  const cwd = join(home, "deadline");
  mkdirSync(cwd, { recursive: true });
  const started = performance.now();
  const pending = handlerOf(hanging, "session_stop")({ stop_hook_active: false }, context("deadline", cwd));
  const { gate, descendant } = await hangingGateOf(cwd);
  expect(isRunning(descendant)).toBe(true);
  const outcome = await pending;
  const returned = { gateReaped: isReaped(gate), descendantRunning: isRunning(descendant) };
  expect(outcome).toMatchObject({ decision: "block" });
  expect(returned).toEqual({ gateReaped: true, descendantRunning: false });
  expect(performance.now() - started).toBeGreaterThanOrEqual(19_000);
}, TEST_TIMEOUT_MS);

test("a hook loaded for one generation keeps its own gate after the next generation's hook loads", async () => {
  const repository = unverifiedT1Repository("generation-t1");
  const tracked = join(repository, "tracked");
  writeFileSync(tracked, "edited\n");
  const next = await load(process.env.NEXT_GENERATION_GATE_HOOK as string);
  await handlerOf(next, "tool_result")(
    { toolName: "write", toolCallId: "next-session-write", input: { path: tracked }, isError: false },
    context("next-session"),
  );
  const recorded = readFileSync(nextGenerationGateCalls, "utf8");
  expect(recorded).toContain("hook arm");
  await writeSucceeded("older-session", { path: tracked });
  expect(await handlerOf(real, "session_stop")({ stop_hook_active: false }, context("older-session"))).toMatchObject({
    decision: "block",
  });
  expect(readFileSync(nextGenerationGateCalls, "utf8")).toBe(recorded);
}, TEST_TIMEOUT_MS);

const finished = { role: "assistant", content: [{ type: "text", text: "done" }], stopReason: "stop" };
const failed = { role: "assistant", content: [], stopReason: "error", errorMessage: "usage limit reached" };
const interrupted = { role: "assistant", content: [], stopReason: "aborted" };

test("a provider failure stop returns control without consulting the gate or settling, and a normal stop still blocks", async () => {
  const session = "provider-failure";
  const repository = unverifiedT1Repository("provider-failure-t1");
  const tracked = join(repository, "tracked");
  writeFileSync(tracked, "edited\n");
  const notices: { message: string; type: string }[] = [];
  const ctx = {
    ...context(session),
    ui: { notify: (message: string, type: string) => notices.push({ message, type }) },
  };
  await handlerOf(real, "tool_result")(
    { toolName: "write", toolCallId: `${session}-write`, input: { path: tracked }, isError: false },
    ctx,
  );
  const stop = handlerOf(real, "session_stop");
  const recording = handlerOf(await load(process.env.NEXT_GENERATION_GATE_HOOK as string), "session_stop");
  const before = gateCalls();

  for (const last_assistant_message of [failed, interrupted]) {
    for (const stop_hook_active of [false, true]) {
      expect(await stop({ stop_hook_active, last_assistant_message }, ctx)).toBeUndefined();
      expect(await recording({ stop_hook_active, last_assistant_message }, ctx)).toBeUndefined();
    }
  }
  expect(gateCalls()).toEqual(before);
  expect(notices).toEqual([]);
  expect(settledReceipts()).toEqual([]);

  const blocked = (await stop({ stop_hook_active: false, last_assistant_message: finished }, ctx)) as {
    decision: string;
    reason: string;
  };
  expect(blocked.decision).toBe("block");
  expect(blocked.reason).toContain(realpathSync(repository));
  expect(settledReceipts()).toEqual([]);
  await recording({ stop_hook_active: false, last_assistant_message: finished }, ctx);
  expect(gateCalls()).toEqual([...before, "hook stop"]);
}, TEST_TIMEOUT_MS);

test("a block is not repeated for the same request once omp has reset its guard, and a new user request blocks again", async () => {
  const session = "guard-reset";
  const repository = unverifiedT1Repository("guard-reset-t1");
  const tracked = join(repository, "tracked");
  writeFileSync(tracked, "edited\n");
  const notices: { message: string; type: string }[] = [];
  const ctx = {
    ...context(session),
    ui: { notify: (message: string, type: string) => notices.push({ message, type }) },
  };
  await handlerOf(real, "tool_result")(
    { toolName: "write", toolCallId: `${session}-write`, input: { path: tracked }, isError: false },
    ctx,
  );
  const stop = handlerOf(real, "session_stop");
  const request = { role: "user", content: [{ type: "text", text: "change the viewer" }], attribution: "user" };
  const first = (await stop(
    { stop_hook_active: false, last_assistant_message: finished, messages: [request, finished] },
    ctx,
  )) as { decision: string; reason: string };
  expect(first.decision).toBe("block");

  const continuation = {
    role: "custom",
    customType: "session-stop-continuation",
    content: first.reason,
    display: false,
    attribution: "agent",
  };
  const history = [request, finished, continuation];
  expect(
    await stop({ stop_hook_active: false, last_assistant_message: failed, messages: [...history, failed] }, ctx),
  ).toBeUndefined();
  expect(notices).toEqual([]);

  const sameRequest = [
    { role: "custom", customType: "memory-recall-changes", content: "recalled", display: false, attribution: "agent" },
    { role: "user", content: "note", synthetic: true },
    { role: "user", content: "note", attribution: "agent" },
  ];
  for (const extra of sameRequest) {
    const messages = [...history, extra, finished];
    expect(await stop({ stop_hook_active: false, last_assistant_message: finished, messages }, ctx)).toBeUndefined();
  }
  expect(notices).toEqual(sameRequest.map(() => ({ message: first.reason, type: "warning" })));
  expect(settledReceipts()).toEqual([]);

  const newRequests = [
    { role: "user", content: [{ type: "text", text: "another change" }], attribution: "user" },
    { role: "custom", customType: "skill-prompt", content: "run the skill", attribution: "user" },
  ];
  for (const next of newRequests) {
    const messages = [...history, finished, next, finished];
    expect(await stop({ stop_hook_active: false, last_assistant_message: finished, messages }, ctx)).toMatchObject({
      decision: "block",
    });
  }
}, TEST_TIMEOUT_MS);

