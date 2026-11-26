import path from 'node:path';
import { getSnapshotByHandle, listSnapshots } from './heap-state.js';

function requireLocalPath(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value)) {
    throw new Error('This environment accepts only authorized absolute local snapshot paths.');
  }
}

function requireResident(value) {
  if (getSnapshotByHandle(value)) return;
  if (typeof value === 'string' && path.isAbsolute(value)
      && listSnapshots().some(snapshot => snapshot.filePath === path.resolve(value))) return;
  throw new Error('Load every comparison snapshot through memlab_load_snapshot first; fresh-file comparison bypasses load admission.');
}

function admit(name, params) {
  if (params.force === true) throw new Error('Force-loading is not available in this environment.');
  if (params.timeout_ms != null && (params.timeout_ms <= 0 || params.timeout_ms > 45000)) {
    throw new Error('The analysis budget cannot be disabled or raised beyond 45000 ms.');
  }
  if (name === 'memlab_load_snapshot' || name === 'memlab_snapshot_header') {
    requireLocalPath(params.file_path);
  }
  if (name === 'memlab_diff_snapshots') {
    for (const key of ['before_path', 'after_path', 'before', 'after', 'baseline', 'target']) {
      if (params[key] != null) requireResident(params[key]);
    }
  }
  if (name === 'memlab_sequence_analysis') {
    for (const value of params.paths) {
      requireLocalPath(value);
      requireResident(value);
    }
  }
}

export function installAdmission(server) {
  const register = server.tool.bind(server);
  let sequence = 0;
  server.tool = (...registration) => {
    const name = registration[0];
    const callbackIndex = registration.length - 1;
    const callback = registration[callbackIndex];
    if (name === 'memlab_diff_snapshots' || name === 'memlab_sequence_analysis') {
      registration[1] += ' In this environment every input must already be resident after guarded memlab_load_snapshot; fresh-file parsing is refused.';
    }
    registration[callbackIndex] = async (...args) => {
      const params = args[0] ?? {};
      admit(name, params);
      const id = ++sequence;
      if (process.connected) process.send({ operation: 'start', id, deadlineMs: params.timeout_ms ?? 45000 });
      try {
        return await callback(...args);
      } finally {
        if (process.connected) process.send({ operation: 'finish', id });
      }
    };
    return register(...registration);
  };
}
