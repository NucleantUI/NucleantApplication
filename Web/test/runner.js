// Runs NucleantApplication's SwiftPM test product (built for wasm32-wasip1)
// in this page, with the same three hosts an app gets from nucleant-app.js:
// WASI, the WebGPU bridge, and the DOM bridge — so windows are real canvases
// and the frame loop is the page's requestAnimationFrame.
//
// Driven by scripts/run_wasm_tests.py: every output line goes to POST /log,
// the exit status to POST /done; any WebGPU validation error fails the run.
//
// Query: ?wasm=<url of the test product>&args=<JSON array of test arguments>
//        [&resources=<url of a resources.json>&name=<argv[0]>] — resources are
//        mounted and named by NUCLEANT_APP_PATH as for an app (nucleant-app.js)
//        [&zoneinfo=<url of a zoneinfo.bin>] — mounted at /usr/share/zoneinfo,
//        as for an app

import { createNucleantWebGPU } from '../nucleant-webgpu.js';
import { NucleantWASI, WASIExit } from '../nucleant-wasi.js';
import { DOMBridge, loadResources, loadZoneinfo } from '../nucleant-app.js';

const params = new URLSearchParams(location.search);
const output = document.getElementById('output');
let posting = Promise.resolve();

function report(path, body) {
  posting = posting.then(() => fetch(path, { method: 'POST', body }).catch(() => {}));
  return posting;
}

function line(text) {
  output.textContent += text + '\n';
  report('/log', text);
}

async function run() {
  const errors = [];
  const gpu = await createNucleantWebGPU({
    nagaURL: new URL('../naga_webgpu.wasm', import.meta.url),
    onError: (message) => errors.push(message),
  });
  line(`[runner] WebGPU device ready; blocking waits (JSPI): ${gpu.blockingWaits}`);
  const args = JSON.parse(params.get('args') ?? '[]');
  const resources = params.get('resources') ? await loadResources(params.get('resources')) : null;
  const zoneinfo = params.get('zoneinfo') ? await loadZoneinfo(params.get('zoneinfo')) : null;
  const wasi = new NucleantWASI({
    args: [params.get('name') ?? 'NucleantApplicationPackageTests', ...args],
    env: resources ? { NUCLEANT_APP_PATH: resources.root } : {},
    files: { ...resources?.files, ...zoneinfo },
    stdout: line,
    stderr: line,
    jspi: gpu.blockingWaits,
  });
  const dom = new DOMBridge(document.getElementById('windows'));
  const bytes = await (await fetch(params.get('wasm'))).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, { ...wasi.imports, ...gpu.imports, ...dom.imports });
  gpu.attach(instance);
  wasi.attach(instance);
  dom.attach(instance, gpu.blockingWaits);

  let status = 0;
  try {
    // The tests run as one long call; frames and events the page delivers
    // meanwhile go through the DOM bridge's queue while it is suspended in a
    // sleep (JSPI), as they would between an app's calls.
    const start = gpu.blockingWaits ? WebAssembly.promising(instance.exports._start) : instance.exports._start;
    await start();
  } catch (error) {
    if (error instanceof WASIExit) status = error.code;
    else {
      line(`[runner] trapped: ${error?.stack ?? error}`);
      status = 1;
    }
  }
  wasi.flush();
  dom.stopFrames();
  await gpu.device.queue.onSubmittedWorkDone();
  for (const message of errors) line(`[runner] WebGPU error: ${message}`);
  if (errors.length && status === 0) status = 1;
  return status;
}

run()
  .catch((error) => {
    line(`[runner] failed to start: ${error?.stack ?? error}`);
    return 1;
  })
  .then((status) => report('/done', String(status)));
