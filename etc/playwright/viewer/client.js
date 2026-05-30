const screencast = document.getElementById("screencast");
const statusBar = document.getElementById("statusBar");
const keyboardCapture = document.getElementById("keyboardCapture");

// 実ページ不在時の初期遷移先
const homeUrl = "https://www.google.com";

let socket = null;
let lastCommandId = 0;
let viewport = { width: 0, height: 0 };

const callCdp = (method, params = {}) => {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ id: ++lastCommandId, method, params }));
  }
};

const isRealPage = page => !/^(about:|chrome:|devtools:)/.test(page.url);

async function activePage() {
  try {
    const targets = await fetch("/json").then(res => res.json());
    const pages = targets.filter(target => target.type === "page");
    return pages.find(isRealPage) || pages[0] || null;
  } catch {
    return null;
  }
}

// リモート viewport とホスト DPI への同期
function syncViewport() {
  callCdp("Emulation.setDeviceMetricsOverride", {
    width: window.innerWidth,
    height: window.innerHeight,
    deviceScaleFactor: window.devicePixelRatio || 1,
    mobile: false,
  });
}

async function connect() {
  const page = await activePage();
  if (!page) {
    statusBar.textContent = "waiting for browser…";
    setTimeout(connect, 1500);
    return;
  }
  socket = new WebSocket(`ws://${location.host}/devtools/page/${page.id}`);
  socket.onopen = () => {
    statusBar.hidden = true;
    callCdp("Page.enable");
    if (!isRealPage(page)) callCdp("Page.navigate", { url: homeUrl });
    syncViewport();
    callCdp("Page.startScreencast", { format: "jpeg", quality: 90, maxWidth: 4096, maxHeight: 4096, everyNthFrame: 1 });
  };
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.method !== "Page.screencastFrame") return;
    const { data: frameBase64, metadata, sessionId } = message.params;
    viewport = { width: metadata.deviceWidth, height: metadata.deviceHeight };
    screencast.src = "data:image/jpeg;base64," + frameBase64;
    callCdp("Page.screencastFrameAck", { sessionId });
  };
  socket.onclose = () => {
    statusBar.hidden = false;
    statusBar.textContent = "reconnecting…";
    setTimeout(connect, 1500);
  };
  socket.onerror = () => socket.close();
}

// 連続発火を間引いたリサイズ追従
let resizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(syncViewport, 200);
});

// 共有ブラウザに残る viewport 上書きの解除
window.addEventListener("beforeunload", () => callCdp("Emulation.clearDeviceMetricsOverride"));

// CDP 入力 API の座標系は viewport の CSS ピクセル
function toViewport(event) {
  const rect = screencast.getBoundingClientRect();
  const aspect = screencast.naturalWidth / screencast.naturalHeight;
  if (!aspect || !viewport.width) return null;
  const shown = rect.width / rect.height > aspect
    ? { width: rect.height * aspect, height: rect.height }
    : { width: rect.width, height: rect.width / aspect };
  const fractionX = (event.clientX - rect.left - (rect.width - shown.width) / 2) / shown.width;
  const fractionY = (event.clientY - rect.top - (rect.height - shown.height) / 2) / shown.height;
  if (fractionX < 0 || fractionY < 0 || fractionX > 1 || fractionY > 1) return null;
  return { x: fractionX * viewport.width, y: fractionY * viewport.height };
}

const mouseButton = event => ["left", "middle", "right"][event.button] || "left";

function sendMouse(type, event) {
  const point = toViewport(event);
  if (!point) return;
  callCdp("Input.dispatchMouseEvent", {
    type, x: point.x, y: point.y,
    button: mouseButton(event), buttons: event.buttons,
    clickCount: type === "mouseMoved" ? 0 : 1,
  });
}

// 既定のフォーカス移動を止め keyboardCapture へ focus を残す
screencast.addEventListener("mousedown", event => { event.preventDefault(); sendMouse("mousePressed", event); keyboardCapture.focus(); });
screencast.addEventListener("mouseup", event => sendMouse("mouseReleased", event));
screencast.addEventListener("mousemove", event => sendMouse("mouseMoved", event));
screencast.addEventListener("contextmenu", event => event.preventDefault());
screencast.addEventListener("wheel", event => {
  const point = toViewport(event);
  if (!point) return;
  callCdp("Input.dispatchMouseEvent", { type: "mouseWheel", x: point.x, y: point.y, deltaX: event.deltaX, deltaY: event.deltaY });
  event.preventDefault();
}, { passive: false });

// CDP 修飾キーは Alt=1 Ctrl=2 Meta=4 Shift=8 のビット和
const modifiers = event =>
  (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);

// IME 制御打鍵は keydown を経ず keyup だけ届くため keydown 送出済みのキーを保持
const sentKeys = new Set();

// IME 変換中の打鍵はリモートへ送らない
keyboardCapture.addEventListener("keydown", event => {
  if (event.isComposing || event.keyCode === 229) return;
  const printable = event.key.length === 1;
  sentKeys.add(event.code);
  callCdp("Input.dispatchKeyEvent", {
    type: printable ? "keyDown" : "rawKeyDown",
    text: printable ? event.key : undefined,
    key: event.key, code: event.code,
    windowsVirtualKeyCode: event.keyCode,
    modifiers: modifiers(event),
  });
  if (!printable) event.preventDefault();
});
keyboardCapture.addEventListener("keyup", event => {
  if (!sentKeys.has(event.code)) return;
  sentKeys.delete(event.code);
  callCdp("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: event.key, code: event.code,
    windowsVirtualKeyCode: event.keyCode,
    modifiers: modifiers(event),
  });
});

// 確定したかな漢字の挿入と捕捉領域の初期化
keyboardCapture.addEventListener("compositionend", event => {
  if (event.data) callCdp("Input.insertText", { text: event.data });
  keyboardCapture.value = "";
});

// 変換を経ない直接入力後の捕捉領域の初期化
keyboardCapture.addEventListener("input", event => {
  if (!event.isComposing) keyboardCapture.value = "";
});

connect();
