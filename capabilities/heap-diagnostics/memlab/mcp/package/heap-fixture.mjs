import { writeHeapSnapshot } from 'node:v8';

class RetainedHeapRecord {
  constructor(id) {
    this.id = id;
    this.payload = Array.from({ length: 64 }, (_, index) => id + index);
  }
}

globalThis.heapCheckRoots = [];
globalThis.heapRegexTarget = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!';
function capture(name) {
  globalThis.gc();
  writeHeapSnapshot(`${name}.heapsnapshot`);
}

capture('baseline');
for (let id = 0; id < 40; id++) {
  globalThis.heapCheckRoots.push(new RetainedHeapRecord(id));
}
capture('grown');
globalThis.heapCheckRoots.length = 0;
capture('released');
