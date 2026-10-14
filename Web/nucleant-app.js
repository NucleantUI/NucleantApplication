// nucleant-app.js — runs a NucleantApplication app built for WebAssembly in
// a browser page.
//
// Three hosts meet in the module's imports: WASI (nucleant-wasi.js) for the
// Swift runtime, the WebGPU bridge (nucleant-webgpu.js) that NucleantVulkan's
// Vulkan implementation runs on, and the DOM bridge here — the "nucleant_dom"
// module Platform_Wasm imports, which turns windows into <canvas> elements,
// web pages shown in them into <iframe>s laid over those (BrowserFrame), and
// page events into calls of the module's exports.
//
//   import { runNucleantApp } from './nucleant-app.js';
//   await runNucleantApp({ wasm: 'MyApp.wasm', container: document.getElementById('app') });
//
// The module is built as a WASI *reactor* (scripts/build_wasm_app.py):
// `_initialize` runs its constructors, `__main_argc_argv` runs the app's
// `main` — setup(), run(), onStart() — which returns, leaving the windows on
// the page. From then on the module runs only when the page calls in: once
// per display refresh (`nucleant_frame`) and for each input event.
//
// Work the module queues for later — `DispatchQueue.main.async`,
// `asyncAfter`, a `Task` — runs on a main queue turn the module asks for
// (`mainQueueWake`), by a call of `nucleant_main_queue_run` straight after
// the current call or once a delay has passed.
//
// Every call into the module goes through one queue, one at a time. Under
// JSPI a call may suspend in the middle (a Vulkan fence wait); the next one
// must not start until it finishes, because both would share the module's
// one shadow stack.

import { createNucleantWebGPU } from './nucleant-webgpu.js';
import { NucleantWASI, WASIExit } from './nucleant-wasi.js';

const POINTER_PHASE = { pointerdown: 0, pointerup: 1, pointermove: 2, pointercancel: 3 };
const POINTER_TYPE = { mouse: 0, touch: 1, pen: 2 };
// Keys whose browser default (scrolling, focus moves, history) would fight
// the app — taken over while a window has focus, unless a shortcut modifier
// is held, so the browser's own shortcuts keep working.
const CAPTURED_KEYS = new Set(['Tab', 'Space', 'Backspace', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Home', 'End']);

/**
 * Loads and starts the app.
 *
 * @param {object} options
 * @param {string|URL} options.wasm          the app's .wasm — or, with `app`, the shared module
 *   the app is linked against. A URL ending in .gz is inflated in the browser.
 * @param {string|URL} [options.app]         the app as a side module (`wasm-ld -shared`), loaded
 *   into `wasm` once its constructors have run, whose `main` runs instead (see loadSideModule)
 * @param {HTMLElement} [options.container]  where windows (canvases) go; default document.body
 * @param {string[]} [options.args]          CommandLine.arguments after the program name
 * @param {Object<string,string>} [options.env]
 * @param {string|URL} [options.resources]   resources.json (scripts/build_wasm_app.py): the
 *   products' resource bundles, mounted read-only in the module's file system
 *   at the manifest's root, which NUCLEANT_APP_PATH then names
 * @param {string|URL} [options.zoneinfo]    zoneinfo.bin (scripts/build_wasm_app.py): the time
 *   zone database, mounted at /usr/share/zoneinfo, where Foundation reads named zones
 * @param {string|URL} [options.nagaURL]     naga_webgpu.wasm; default next to this file
 * @param {boolean} [options.jspi]           false to run as on a browser without JSPI
 * @param {(message: string) => void} [options.onError]  every WebGPU / translation error
 * @returns {Promise<{ instance: WebAssembly.Instance, dom: DOMBridge, gpu: object }>}
 */
export async function runNucleantApp(options) {
  const gpu = await createNucleantWebGPU({
    nagaURL: options.nagaURL ?? new URL('naga_webgpu.wasm', import.meta.url),
    jspi: options.jspi,
    onError: options.onError,
  });
  const name = String(options.app ?? options.wasm).split('/').pop().replace(/\.wasm(\.gz)?$/, '');
  const resources = options.resources ? await loadResources(options.resources) : null;
  const zoneinfo = options.zoneinfo ? await loadZoneinfo(options.zoneinfo) : null;
  const env = { ...(resources ? { NUCLEANT_APP_PATH: resources.root } : {}), ...(options.env ?? {}) };
  const wasi = new NucleantWASI({ args: [name, ...(options.args ?? [])], env, jspi: gpu.blockingWaits, files: { ...resources?.files, ...zoneinfo } });
  const dom = new DOMBridge(options.container ?? document.body);
  dom.resources = resources;
  const { instance } = await WebAssembly.instantiate(await fetchModule(options.wasm), { ...wasi.imports, ...gpu.imports, ...dom.imports });
  gpu.attach(instance);
  wasi.attach(instance);
  dom.attach(instance, gpu.blockingWaits);
  const initialized = dom.call('_initialize');
  if (options.app) {
    // After _initialize: the app's constructors register its Swift
    // metadata with the shared module's runtime.
    await initialized;
    const app = await loadSideModule(instance, options.app);
    const main = app.exports.__main_argc_argv;
    dom.exports.__main_argc_argv = gpu.blockingWaits ? WebAssembly.promising(main) : main;
  }
  await dom.call('__main_argc_argv', 0, 0);
  return { instance, dom, gpu };
}

/** A module's bytes; a URL ending in .gz is inflated (GitHub Pages serves .wasm uncompressed). */
async function fetchModule(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`cannot load ${url} (${response.status})`);
  if (!String(url).endsWith('.gz')) return response.arrayBuffer();
  return new Response(response.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
}

/**
 * Loads an app built as a side module — `wasm-ld -shared`, position
 * independent, with a `dylink.0` section — into `main`, the module it was
 * linked against, which exports everything the app imports from it: its
 * functions by name, its data (GOT.mem) as globals holding addresses, and
 * its table, stack pointer and `__global_base`.
 *
 * The app's data goes at address 0, below main's own (which starts at
 * `__global_base`): wasm-ld adds `__memory_base` to an already-correct
 * relative pointer when relocating a side module (R_WASM_MEMORY_ADDR_LOCREL_I32),
 * which is right only when that base is 0. Its functions go at the end of
 * main's table. A function either module takes the address of (GOT.func)
 * gets a table slot.
 */
export async function loadSideModule(main, url) {
  const module = await WebAssembly.compile(await fetchModule(url));
  const exports = main.exports;
  const { memorySize, tableSize } = dylinkInfo(module, url);
  if (memorySize > exports.__global_base.value) {
    throw new Error(`${url} needs ${memorySize} bytes of data; the shared module leaves ${exports.__global_base.value}`);
  }
  const table = exports.__indirect_function_table;
  const tableBase = table.grow(tableSize);
  const slots = new Map();
  const slotOf = (fn) => {
    if (!slots.has(fn)) slots.set(fn, table.grow(1, fn));
    return slots.get(fn);
  };
  const imports = { env: {}, 'GOT.mem': {}, 'GOT.func': {} };
  const ownEntries = [];
  for (const { module: from, name, kind } of WebAssembly.Module.imports(module)) {
    if (from === 'env') {
      if (name === 'memory') imports.env.memory = exports.memory;
      else if (name === '__indirect_function_table') imports.env[name] = table;
      else if (name === '__stack_pointer') imports.env[name] = exports.__stack_pointer;
      else if (name === '__memory_base') imports.env[name] = new WebAssembly.Global({ value: 'i32' }, 0);
      else if (name === '__table_base') imports.env[name] = new WebAssembly.Global({ value: 'i32' }, tableBase);
      else if (kind === 'function') {
        if (typeof exports[name] !== 'function') throw new Error(`${url} imports ${name}, which the shared module does not export`);
        imports.env[name] = exports[name];
      }
    } else if (from === 'GOT.mem' || from === 'GOT.func') {
      const found = exports[name];
      const address = from === 'GOT.mem'
        ? (found instanceof WebAssembly.Global ? found.value : 0)
        : (typeof found === 'function' ? slotOf(found) : 0);
      const entry = new WebAssembly.Global({ value: 'i32', mutable: true }, address);
      imports[from][name] = entry;
      // Not in main: one of the app's own symbols, filled in below.
      if (found === undefined) ownEntries.push({ from, name, entry });
    }
  }
  const app = await WebAssembly.instantiate(module, imports);
  for (const { from, name, entry } of ownEntries) {
    const own = app.exports[name];
    if (from === 'GOT.mem' && own instanceof WebAssembly.Global) entry.value = own.value;
    else if (from === 'GOT.func' && typeof own === 'function') entry.value = slotOf(own);
    else throw new Error(`${url} needs ${name}, which neither module defines`);
  }
  app.exports.__wasm_apply_data_relocs?.();
  app.exports.__wasm_call_ctors?.();
  return app;
}

/** A side module's memory and table needs, from its dylink.0 section. */
function dylinkInfo(module, url) {
  const section = WebAssembly.Module.customSections(module, 'dylink.0')[0];
  if (!section) throw new Error(`${url} is not a side module (no dylink.0 section)`);
  const bytes = new Uint8Array(section);
  let at = 0;
  const leb = () => {
    let result = 0, shift = 0, byte;
    do { byte = bytes[at++]; result |= (byte & 0x7f) << shift; shift += 7; } while (byte & 0x80);
    return result >>> 0;
  };
  const info = { memorySize: 0, tableSize: 0 };
  while (at < bytes.length) {
    const type = bytes[at++];
    const end = leb() + at;
    // WASM_DYLINK_MEM_INFO: memory size, alignment, table size, alignment.
    if (type === 1) { info.memorySize = leb(); leb(); info.tableSize = leb(); }
    at = end;
  }
  return info;
}

/**
 * The files a resources.json lists, fetched: `{ root, buildRoot, base, files }`
 * with `files` keyed by their absolute path under `root`, as NucleantWASI
 * takes them — and under the manifest's `buildRoot` too, the directory the
 * bundles were built in: SwiftPM's generated `Bundle.module` accessor for
 * wasm looks for its bundle only there (or at another path on the machine
 * that built it). `base` is the URL the files are served under, for the
 * module to hand a page in a frame (the `resourceURL` import).
 */
export async function loadResources(manifestURL) {
  const manifestBase = new URL(manifestURL, location.href);
  const response = await fetch(manifestBase);
  if (!response.ok) throw new Error(`cannot load ${manifestURL} (${response.status})`);
  const manifest = await response.json();
  const base = new URL(manifest.base ?? '', manifestBase);
  const root = manifest.root.replace(/\/$/, '');
  const buildRoot = manifest.buildRoot?.replace(/\/$/, '');
  const entries = await Promise.all(manifest.files.map(async (path) => {
    const file = await fetch(new URL(path.split('/').map(encodeURIComponent).join('/'), base));
    if (!file.ok) throw new Error(`cannot load resource ${path} (${file.status})`);
    const bytes = new Uint8Array(await file.arrayBuffer());
    return [[`${root}/${path}`, bytes], ...(buildRoot ? [[`${buildRoot}/${path}`, bytes]] : [])];
  }));
  return { root, buildRoot, base: base.href, files: Object.fromEntries(entries.flat()) };
}

/**
 * The time zone database a zoneinfo.bin packs (scripts/build_wasm_app.py),
 * keyed by its path under /usr/share/zoneinfo: Foundation reads a named zone
 * ("Europe/Lisbon") from there, and without it formatting a date in any
 * named zone but UTC traps. One record per file, little-endian: u16 path
 * length, the path, u32 size, the bytes. A missing file is a warning, not a
 * failure — the build skips it on a machine with no zoneinfo of its own.
 */
export async function loadZoneinfo(url) {
  const response = await fetch(new URL(url, location.href));
  if (!response.ok) {
    console.warn(`[NucleantApplication] no time zone database at ${url} (${response.status}); named time zones will trap`);
    return {};
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  const view = new DataView(bytes.buffer);
  const decoder = new TextDecoder();
  const files = {};
  for (let at = 0; at < bytes.length;) {
    const pathLength = view.getUint16(at, true);
    const path = decoder.decode(bytes.subarray(at + 2, at + 2 + pathLength));
    at += 2 + pathLength;
    const size = view.getUint32(at, true);
    files[`/usr/share/zoneinfo/${path}`] = bytes.subarray(at + 4, at + 4 + size);
    at += 4 + size;
  }
  return files;
}

/** The "nucleant_dom" imports, and the queue every call into the module goes through. */
export class DOMBridge {
  constructor(container) {
    this.container = container;
    this.windows = new Map();
    this.nextWindow = 1;
    this.memory = null;
    this.exports = {};
    this.queue = [];
    this.busy = false;
    this.dead = false;
    this.eventStrings = ['', ''];
    this.frameRequest = 0;
    this.framePending = false;
    this.mainQueueWake = null;
    // Pages laid over the windows (<iframe>s), by id.
    this.frames = new Map();
    this.nextFrame = 1;
    // What loadResources found — where `resourceURL` maps a mounted file to.
    this.resources = null;
    // The page's light/dark preference — the OS setting, or the browser's
    // own theme setting where that overrides it.
    this.darkScheme = globalThis.matchMedia?.('(prefers-color-scheme: dark)') ?? null;
    this.imports = { nucleant_dom: this.makeImports() };
  }

  attach(instance, jspi) {
    this.memory = instance.exports.memory;
    for (const [name, value] of Object.entries(instance.exports)) {
      if (typeof value !== 'function') continue;
      this.exports[name] = jspi ? WebAssembly.promising(value) : value;
    }
    this.darkScheme?.addEventListener('change', (event) => this.call('nucleant_color_scheme_changed', event.matches ? 1 : 0));
  }

  // MARK: - Calling into the module

  /**
   * Queues a call of export `name`; resolves when it has run. `before` runs
   * right before the call (to stage what it will read back).
   */
  call(name, ...args) {
    return this.enqueue({ name, args });
  }

  enqueue(job) {
    if (this.dead || !this.exports[job.name]) return Promise.resolve();
    return new Promise((resolve) => {
      job.resolve = resolve;
      this.queue.push(job);
      this.pump();
    });
  }

  async pump() {
    if (this.busy) return;
    this.busy = true;
    while (this.queue.length && !this.dead) {
      const job = this.queue.shift();
      job.before?.();
      try {
        await this.exports[job.name](...job.args);
      } catch (error) {
        this.fail(job.name, error);
      }
      job.after?.();
      job.resolve();
    }
    this.busy = false;
  }

  fail(name, error) {
    if (error instanceof WASIExit) {
      console.info(`[NucleantApplication] the app exited with status ${error.code}`);
    } else {
      // A trap leaves Swift state undefined; calling in again would only
      // trap again, so the module stops here.
      console.error(`[NucleantApplication] ${name} trapped:`, error);
    }
    this.dead = true;
    this.stopFrames();
  }

  // MARK: - Imports

  makeImports() {
    const string = (ptr, length) => new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, length));
    // `text` into the module's buffer, as much as fits; its full UTF-8 length.
    const copyOut = (text, buffer, capacity) => {
      const bytes = new TextEncoder().encode(text);
      new Uint8Array(this.memory.buffer, buffer, capacity).set(bytes.subarray(0, capacity));
      return bytes.length;
    };
    return {
      windowCreate: (titlePtr, titleLength, width, height) => this.createWindow(string(titlePtr, titleLength), width, height),
      windowDestroy: (id) => this.destroyWindow(id),
      windowSetTitle: (id, ptr, length) => {
        const window = this.windows.get(id);
        if (!window) return;
        window.title = string(ptr, length);
        window.canvas.title = window.title;
        if (this.mainWindow() === window) document.title = window.title;
      },
      windowGetMetrics: (id, out) => {
        const window = this.windows.get(id);
        const metrics = new Float64Array(this.memory.buffer, out, 5);
        if (!window) {
          metrics.fill(0);
          return;
        }
        metrics[0] = window.cssWidth;
        metrics[1] = window.cssHeight;
        metrics[2] = globalThis.devicePixelRatio || 1;
        metrics[3] = window.canvas.width;
        metrics[4] = window.canvas.height;
      },
      windowSetFullscreen: (id, fullscreen) => {
        const window = this.windows.get(id);
        if (!window) return;
        if (fullscreen) window.canvas.requestFullscreen?.().catch((error) => console.warn('[NucleantApplication] fullscreen refused:', error.message));
        else if (document.fullscreenElement === window.canvas) document.exitFullscreen();
      },
      windowFocus: (id) => this.windows.get(id)?.canvas.focus(),
      windowSetLayout: (id, fills, minWidth, minHeight, maxWidth, maxHeight) =>
        this.layoutWindow(id, fills !== 0, minWidth, minHeight, maxWidth, maxHeight),
      eventString: (which, buffer, capacity) => copyOut(this.eventStrings[which] ?? '', buffer, capacity),
      frameLoopStart: () => this.startFrames(),
      frameLoopStop: () => this.stopFrames(),
      colorSchemeIsDark: () => (this.darkScheme?.matches ? 1 : 0),
      mainQueueWake: (delay) => this.wakeMainQueue(delay),
      resourceURL: (ptr, length, buffer, capacity) => copyOut(this.resourceURL(string(ptr, length)), buffer, capacity),
      frameCreate: (background, namePtr, nameLength) => this.createFrame(background, string(namePtr, nameLength)),
      frameDestroy: (id) => this.destroyFrame(id),
      frameSetGeometry: (id, window, ptr) => {
        const frame = this.frames.get(id);
        if (!frame) return;
        frame.window = window;
        frame.geometry = Array.from(new Float64Array(this.memory.buffer, ptr, 8));
        this.placeFrame(frame);
      },
      frameSetHidden: (id, hidden) => {
        const frame = this.frames.get(id);
        if (!frame) return;
        frame.hidden = hidden !== 0;
        this.placeFrame(frame);
      },
      frameLoad: (id, ptr, length) => this.loadFrame(id, string(ptr, length)),
      frameEvaluate: (id, ptr, length) => this.evaluateInFrame(id, string(ptr, length)),
      frameNavigate: (id, action) => this.navigateFrame(id, action),
      frameSetZoom: (id, factor) => {
        const frame = this.frames.get(id);
        if (!frame) return;
        frame.zoom = factor;
        this.applyZoom(frame);
      },
      frameQueryAnswer: (id, query, success, code, ptr, length) => this.answerQuery(id, query, success !== 0, code, string(ptr, length)),
    };
  }

  /** The URL a file mounted from resources.json is served at; '' for any other path. */
  resourceURL(path) {
    const resources = this.resources;
    if (!resources) return '';
    for (const prefix of [resources.root, resources.buildRoot]) {
      if (!prefix || !path.startsWith(`${prefix}/`)) continue;
      const relative = path.slice(prefix.length + 1).split('/').map(encodeURIComponent).join('/');
      return new URL(relative, resources.base).href;
    }
    return '';
  }

  // MARK: - Main queue

  /**
   * Calls `nucleant_main_queue_run` in `delay` ms. 0 is a message-channel
   * task — next, after the current call and whatever the page already has
   * queued, without the 4 ms clamp nested timeouts get. One wake is pending
   * at a time: an earlier request replaces it, a later one is dropped (the
   * module asks again after each turn for whatever is left).
   */
  wakeMainQueue(delay) {
    const at = performance.now() + delay;
    if (this.mainQueueWake && this.mainQueueWake.at <= at) return;
    this.mainQueueWake?.cancel();
    const wake = { at, cancelled: false, cancel: null };
    const fire = () => {
      if (wake.cancelled) return;
      this.mainQueueWake = null;
      this.call('nucleant_main_queue_run');
    };
    if (delay > 0) {
      const timer = setTimeout(fire, delay);
      wake.cancel = () => { wake.cancelled = true; clearTimeout(timer); };
    } else {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        fire();
      };
      channel.port2.postMessage(null);
      wake.cancel = () => { wake.cancelled = true; channel.port1.close(); };
    }
    this.mainQueueWake = wake;
  }

  // MARK: - Frames

  startFrames() {
    if (this.frameRequest) return;
    const tick = (timestamp) => {
      this.frameRequest = requestAnimationFrame(tick);
      // A canvas the page's layout moved takes its frames along.
      for (const frame of this.frames.values()) this.placeFrame(frame);
      // A frame still running (waiting on the GPU) absorbs this refresh, as a
      // display link skips a frame the app is late for.
      if (this.framePending) return;
      this.framePending = true;
      this.enqueue({ name: 'nucleant_frame', args: [timestamp], after: () => { this.framePending = false; } });
    };
    this.frameRequest = requestAnimationFrame(tick);
  }

  stopFrames() {
    if (this.frameRequest) cancelAnimationFrame(this.frameRequest);
    this.frameRequest = 0;
  }

  // MARK: - Windows

  mainWindow() {
    return this.windows.values().next().value;
  }

  createWindow(title, width, height) {
    const id = this.nextWindow++;
    const canvas = document.createElement('canvas');
    canvas.id = `nucleant-window-${id}`;
    canvas.className = 'nucleant-window';
    canvas.tabIndex = 0;
    canvas.title = title;
    Object.assign(canvas.style, { width: `${width}px`, height: `${height}px`, display: 'block', touchAction: 'none', outline: 'none' });
    const window = { id, canvas, title, width, height, cssWidth: width, cssHeight: height, observer: null };
    this.resizeCanvas(window, width, height, null);
    this.container.appendChild(canvas);
    this.windows.set(id, window);
    if (this.windows.size === 1) document.title = title;

    window.observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const box = entry.contentBoxSize?.[0];
        const pixels = entry.devicePixelContentBoxSize?.[0];
        const cssWidth = box ? box.inlineSize : entry.contentRect.width;
        const cssHeight = box ? box.blockSize : entry.contentRect.height;
        this.resizeCanvas(window, cssWidth, cssHeight, pixels);
        this.call('nucleant_window_resized', id);
      }
    });
    try {
      window.observer.observe(canvas, { box: 'device-pixel-content-box' });
    } catch {
      window.observer.observe(canvas);
    }
    this.listen(window);
    return id;
  }

  /**
   * Sizes the canvas: at the size it was created at, or filling its container
   * and following it, and either way kept within the limits — CSS pixels,
   * 0 and Infinity for none. A filling canvas takes its height from the
   * container, so the container needs one of its own (index.html gives the
   * page's); `contain: size` keeps the canvas's own drawing buffer, which
   * follows its displayed size, from feeding back into that size.
   */
  layoutWindow(id, fills, minWidth, minHeight, maxWidth, maxHeight) {
    const window = this.windows.get(id);
    if (!window) return;
    const limit = (value, none) => (value > 0 && Number.isFinite(value) ? `${value}px` : none);
    Object.assign(window.canvas.style, {
      width: fills ? '100%' : `${window.width}px`,
      height: fills ? '100%' : `${window.height}px`,
      contain: fills ? 'size' : '',
      minWidth: limit(minWidth, '0'),
      minHeight: limit(minHeight, '0'),
      maxWidth: limit(maxWidth, 'none'),
      maxHeight: limit(maxHeight, 'none'),
    });
    window.canvas.classList.toggle('nucleant-window-fills', fills);
    // A filling canvas held to a maximum doesn't reach the container's edges:
    // the page can set it off the way it would a window.
    window.canvas.classList.toggle('nucleant-window-bounded', Number.isFinite(maxWidth) || Number.isFinite(maxHeight));
  }

  /** Keeps the canvas's drawing buffer at its displayed size in device pixels. */
  resizeCanvas(window, cssWidth, cssHeight, pixels) {
    const ratio = globalThis.devicePixelRatio || 1;
    window.cssWidth = cssWidth;
    window.cssHeight = cssHeight;
    window.canvas.width = Math.max(1, pixels ? pixels.inlineSize : Math.round(cssWidth * ratio));
    window.canvas.height = Math.max(1, pixels ? pixels.blockSize : Math.round(cssHeight * ratio));
  }

  destroyWindow(id) {
    const window = this.windows.get(id);
    if (!window) return;
    window.observer?.disconnect();
    window.canvas.remove();
    this.windows.delete(id);
    for (const frame of this.frames.values()) {
      if (frame.window === id) this.placeFrame(frame);
    }
  }

  // MARK: - Frames
  //
  // An <iframe> per BrowserFrame, positioned over its window's canvas. Each
  // is a child of <body>, absolutely positioned in document coordinates, so
  // it never takes part in the page's layout and scrolls with the canvas;
  // the frame loop re-places it in case the layout moved the canvas.

  createFrame(background, queryName) {
    const id = this.nextFrame++;
    const element = document.createElement('iframe');
    element.className = 'nucleant-frame';
    element.allow = 'clipboard-read; clipboard-write; fullscreen';
    const alpha = ((background >>> 24) & 0xff) / 255;
    Object.assign(element.style, {
      position: 'absolute', left: '0px', top: '0px', width: '0px', height: '0px',
      border: '0', margin: '0', padding: '0', zIndex: '1', visibility: 'hidden',
      background: `rgba(${(background >>> 16) & 0xff}, ${(background >>> 8) & 0xff}, ${background & 0xff}, ${alpha})`,
      colorScheme: 'normal',
    });
    const frame = {
      id, element, queryName,
      window: 0, geometry: null, hidden: true, placed: '',
      url: '', zoom: 1,
      // The document the query function and console hooks went into.
      prepared: null, watch: 0,
      queries: new Map(), nextQuery: 1,
    };
    element.addEventListener('load', () => this.frameLoaded(frame));
    document.body.appendChild(element);
    this.frames.set(id, frame);
    return id;
  }

  destroyFrame(id) {
    const frame = this.frames.get(id);
    if (!frame) return;
    clearTimeout(frame.watch);
    frame.queries.clear();
    frame.element.remove();
    this.frames.delete(id);
  }

  /** Over the canvas at the geometry the module gave, cut to its visible part. */
  placeFrame(frame) {
    const { element, geometry: g } = frame;
    const window = this.windows.get(frame.window);
    if (!window || !g || frame.hidden || g[6] <= 0 || g[7] <= 0) {
      if (frame.placed !== 'hidden') {
        element.style.visibility = 'hidden';
        frame.placed = 'hidden';
      }
      return;
    }
    const canvas = window.canvas.getBoundingClientRect();
    const left = canvas.left + window.canvas.clientLeft + globalThis.scrollX + g[0];
    const top = canvas.top + window.canvas.clientTop + globalThis.scrollY + g[1];
    const inset = [g[5] - g[1], g[0] + g[2] - (g[4] + g[6]), g[1] + g[3] - (g[5] + g[7]), g[4] - g[0]].map((value) => Math.max(0, value));
    const placed = `${left} ${top} ${g[2]} ${g[3]} ${inset.join(' ')}`;
    if (placed === frame.placed) return;
    frame.placed = placed;
    Object.assign(element.style, {
      left: `${left}px`, top: `${top}px`, width: `${g[2]}px`, height: `${g[3]}px`,
      clipPath: inset.some((value) => value > 0) ? `inset(${inset.map((value) => `${value}px`).join(' ')})` : '',
      visibility: 'visible',
    });
  }

  loadFrame(id, url) {
    const frame = this.frames.get(id);
    if (!frame) return;
    frame.url = url;
    frame.element.src = url;
    this.watchFrame(frame);
  }

  /** The frame's window and document, when the page is the app's own origin. */
  frameDocument(frame) {
    try {
      const window = frame.element.contentWindow;
      return window ? { window, document: window.document } : null;
    } catch {
      return null;
    }
  }

  /**
   * Prepares the document a navigation brings the moment it exists: the
   * page's own scripts may call the query function long before 'load'
   * (Monaco's does, once its module is fetched), so this does not wait for
   * it — it polls from the navigation until the document has been replaced.
   * 'load' catches any navigation the page made itself.
   */
  watchFrame(frame) {
    clearTimeout(frame.watch);
    const previous = this.frameDocument(frame)?.document ?? null;
    const started = performance.now();
    const check = () => {
      frame.watch = 0;
      const current = this.frameDocument(frame)?.document ?? null;
      if (current !== previous && this.prepareFrame(frame)) return;
      if (performance.now() - started > 30000) return;
      frame.watch = setTimeout(check, 0);
    };
    check();
  }

  /** True once the current document has its query function and console hooks, or never can. */
  prepareFrame(frame) {
    let target;
    try {
      target = frame.element.contentWindow;
      void target?.document;
    } catch {
      return true; // another origin: out of reach
    }
    if (!target) return false;
    const document = target.document;
    // The about:blank document an iframe starts with, before the navigation replaces it.
    if (document.URL === 'about:blank' && frame.url !== 'about:blank') return false;
    if (frame.prepared === document) return true;
    frame.prepared = document;
    if (frame.queryName) {
      target[frame.queryName] = (options) => this.frameQuery(frame, document, options ?? {});
      target[`${frame.queryName}Cancel`] = (query) => this.cancelQuery(frame, query);
    }
    const format = (value) => {
      if (typeof value === 'string') return value;
      if (value instanceof target.Error) return value.stack ?? String(value);
      try {
        return typeof value === 'object' && value !== null ? JSON.stringify(value) : String(value);
      } catch {
        return String(value);
      }
    };
    for (const [method, level] of [['debug', 1], ['log', 2], ['info', 2], ['warn', 3], ['error', 4]]) {
      const original = target.console[method];
      target.console[method] = (...args) => {
        original.apply(target.console, args);
        this.frameConsole(frame, level, args.map(format).join(' '), '', 0);
      };
    }
    target.addEventListener('error', (event) => this.frameConsole(frame, 4, `Uncaught ${event.message}`, event.filename ?? '', event.lineno ?? 0));
    this.applyZoom(frame);
    return true;
  }

  frameLoaded(frame) {
    const current = this.frameDocument(frame)?.document ?? null;
    // The about:blank an iframe reports as it goes on the page, before its first navigation.
    if (current?.URL === 'about:blank' && frame.url !== 'about:blank') return;
    clearTimeout(frame.watch);
    frame.watch = 0;
    // Queries from a document that has gone go with it.
    for (const [query, pending] of frame.queries) {
      if (pending.document === current) continue;
      frame.queries.delete(query);
      this.call('nucleant_browser_frame_query_canceled', frame.id, query);
    }
    this.prepareFrame(frame);
    const url = current?.URL ?? frame.element.src;
    const title = current?.title ?? '';
    this.enqueue({ name: 'nucleant_browser_frame_loaded', args: [frame.id], before: () => { this.eventStrings = [url, title]; } });
  }

  frameConsole(frame, level, message, source, line) {
    if (!this.frames.has(frame.id)) return;
    this.enqueue({ name: 'nucleant_browser_frame_console', args: [frame.id, level, line >>> 0], before: () => { this.eventStrings = [message, source]; } });
  }

  frameQuery(frame, document, { request, persistent = false, onSuccess, onFailure }) {
    const query = frame.nextQuery++;
    frame.queries.set(query, { document, persistent: Boolean(persistent), onSuccess, onFailure });
    const strings = [String(request ?? ''), document.URL];
    this.enqueue({ name: 'nucleant_browser_frame_query', args: [frame.id, query, persistent ? 1 : 0], before: () => { this.eventStrings = strings; } });
    return query;
  }

  cancelQuery(frame, query) {
    if (frame.queries.delete(query)) this.call('nucleant_browser_frame_query_canceled', frame.id, query);
  }

  answerQuery(id, query, success, code, text) {
    const frame = this.frames.get(id);
    const pending = frame?.queries.get(query);
    if (!pending) return;
    if (!success || !pending.persistent) frame.queries.delete(query);
    // Off the module's stack: the page's callback may well call in again.
    queueMicrotask(() => {
      try {
        if (success) pending.onSuccess?.(text);
        else pending.onFailure?.(code, text);
      } catch (error) {
        console.error('[NucleantApplication] a frame\'s query callback threw:', error);
      }
    });
  }

  evaluateInFrame(id, script) {
    const frame = this.frames.get(id);
    if (!frame) return;
    queueMicrotask(() => {
      const page = this.frameDocument(frame);
      if (!page) {
        console.warn('[NucleantApplication] a frame from another origin cannot be scripted');
        return;
      }
      try {
        // Indirect: in the page's global scope, as CEF runs it.
        page.window.eval(script);
      } catch (error) {
        console.error('[NucleantApplication] a script in a frame threw:', error);
      }
    });
  }

  navigateFrame(id, action) {
    const frame = this.frames.get(id);
    if (!frame) return;
    const page = this.frameDocument(frame);
    if (page) {
      const { window } = page;
      if (action === 0) window.history.back();
      else if (action === 1) window.history.forward();
      else if (action === 2 || action === 3) window.location.reload();
      else window.stop();
    } else if (action === 2 || action === 3) {
      // Another origin's document is out of reach; load its address again.
      frame.element.src = frame.element.src;
    }
    if (action !== 4) this.watchFrame(frame);
  }

  applyZoom(frame) {
    const root = this.frameDocument(frame)?.document.documentElement;
    if (root) root.style.zoom = frame.zoom === 1 ? '' : String(frame.zoom);
  }

  listen(window) {
    const { id, canvas } = window;
    const pointer = (event) => {
      const phase = POINTER_PHASE[event.type];
      if (event.type === 'pointerdown') {
        canvas.focus();
        canvas.setPointerCapture?.(event.pointerId);
      }
      const rect = canvas.getBoundingClientRect();
      this.call('nucleant_pointer', id, phase, event.clientX - rect.left, event.clientY - rect.top,
                Math.max(event.button, 0), event.buttons, event.pointerId, POINTER_TYPE[event.pointerType] ?? 0);
      if (event.type !== 'pointermove') event.preventDefault();
    };
    for (const type of Object.keys(POINTER_PHASE)) canvas.addEventListener(type, pointer);
    canvas.addEventListener('contextmenu', (event) => event.preventDefault());
    canvas.addEventListener('wheel', (event) => {
      event.preventDefault();
      const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.cssHeight : 1;
      this.call('nucleant_wheel', id, -event.deltaX * scale, -event.deltaY * scale);
    }, { passive: false });
    const key = (event) => {
      if (CAPTURED_KEYS.has(event.code === 'Space' ? 'Space' : event.key) && !event.metaKey && !event.ctrlKey) event.preventDefault();
      const strings = [event.code, event.key];
      this.enqueue({ name: 'nucleant_key', args: [id, event.type === 'keydown' ? 1 : 0], before: () => { this.eventStrings = strings; } });
    };
    canvas.addEventListener('keydown', key);
    canvas.addEventListener('keyup', key);
  }
}
