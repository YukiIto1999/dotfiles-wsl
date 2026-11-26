import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const deadlineMs = Number(process.env.MEMLAB_ANALYSIS_TIMEOUT_MS ?? 45000);
if (!Number.isFinite(deadlineMs) || deadlineMs <= 0) {
  throw new Error('MEMLAB_ANALYSIS_TIMEOUT_MS must be a positive finite duration');
}
const child = spawn(process.execPath, [fileURLToPath(new URL('./readonly-server.js', import.meta.url))], {
  stdio: ['pipe', 'pipe', 'pipe', 'ipc'],
});
const deadlines = new Map();
let closing = false;
let failed = false;
let termination;

function clearDeadlines() {
  for (const timer of deadlines.values()) clearTimeout(timer);
  deadlines.clear();
}

function close(signal = 'SIGTERM') {
  if (closing) return;
  closing = true;
  clearDeadlines();
  process.stdin.unpipe(child.stdin);
  child.stdin.end();
  child.kill(signal);
  termination = setTimeout(() => child.kill('SIGKILL'), 2000);
}

child.on('message', message => {
  if (closing) return;
  if (message.operation === 'start') {
    deadlines.set(message.id, setTimeout(() => {
      failed = true;
      process.stderr.write('MemLab analysis exceeded its hard deadline; the session was closed without a complete result.\n');
      close('SIGKILL');
    }, Math.min(deadlineMs, message.deadlineMs)));
  } else if (message.operation === 'finish') {
    clearTimeout(deadlines.get(message.id));
    deadlines.delete(message.id);
  }
});
child.on('error', error => {
  failed = true;
  process.stderr.write(`MemLab process failed: ${error.message}\n`);
  close();
});
child.stdin.on('error', error => {
  if (closing) return;
  failed = true;
  process.stderr.write(`MemLab input failed: ${error.message}\n`);
  close();
});
child.on('close', code => {
  clearDeadlines();
  clearTimeout(termination);
  process.stdin.unpipe(child.stdin);
  process.stdin.destroy();
  process.exitCode = failed ? 1 : closing ? 0 : code ?? 1;
});
process.stdin.on('end', () => close());
process.stdin.on('error', error => {
  failed = true;
  process.stderr.write(`MemLab transport failed: ${error.message}\n`);
  close();
});
process.on('SIGTERM', () => close());
process.on('SIGINT', () => close());
child.stdout.pipe(process.stdout);
child.stderr.pipe(process.stderr);
process.stdin.pipe(child.stdin);
