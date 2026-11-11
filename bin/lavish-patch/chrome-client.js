// Firstmate's local Lavish chrome overlay. bin/fm-lavish-patch.mjs appends this file to
// lavish-axi's dist/chrome-client.js and owns when it is applied and removed.
// Desktop Conversation panel drag-to-resize, adapted from kunchenguid/lavish-axi PR #429 (a resize
// handle on the panel's inner edge with a stored width). The storage key is the one that PR uses,
// so a viewer's width carries over when upstream ships its own, and this part stands down once
// the page has that PR's own handle (id="panelResizer"). Above the phone breakpoint only; the
// phone sheet is untouched. Hiding the panel is Lavish's own bar toggle, which takes this handle
// away with the panel.
(() => {
  const panel = document.getElementById("panel");
  if (!panel || document.getElementById("panelResizer") || panel.querySelector(".fm-panel-resizer")) return;

  const WIDTH_KEY = "lavish-axi:panel-width";
  const MIN_PANEL = 280;
  const MAX_PANEL = 1200;
  const MIN_FRAME = 280;
  const STEP = 16;
  const DRAG_THRESHOLD = 4;
  const root = document.documentElement;
  const phone = typeof window.matchMedia === "function" ? window.matchMedia("(max-width: 860px)") : null;
  const isPhone = () => Boolean(phone && phone.matches);

  function readStored(key) {
    try {
      return window.localStorage.getItem(key);
    } catch {
      return null;
    }
  }
  function writeStored(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch {
      // Storage refused only means the choice does not survive a reload.
    }
  }

  const defaultWidth = Number.parseInt(getComputedStyle(root).getPropertyValue("--panel-w"), 10) || 360;
  let preferredWidth = Number.parseInt(readStored(WIDTH_KEY) || "", 10);
  if (!Number.isFinite(preferredWidth)) preferredWidth = defaultWidth;
  let currentWidth = preferredWidth;

  const resizer = document.createElement("div");
  resizer.className = "fm-panel-resizer";
  resizer.setAttribute("role", "separator");
  resizer.setAttribute("aria-orientation", "vertical");
  resizer.setAttribute("aria-controls", "panel");
  resizer.setAttribute("aria-label", "Resize conversation");
  resizer.title = "Drag to resize the conversation, double-click to reset";
  resizer.tabIndex = 0;
  panel.insertBefore(resizer, panel.firstChild);

  const maxWidth = () => Math.max(MIN_PANEL, Math.min(MAX_PANEL, (window.innerWidth || 1200) - MIN_FRAME));
  const clampWidth = (width) => Math.min(Math.max(MIN_PANEL, Math.round(Number(width) || defaultWidth)), maxWidth());

  // The rendered width is the stored preference clamped to this viewport; a narrower window never
  // overwrites the preference, so widening it again restores the chosen width.
  function applyWidth(width) {
    if (isPhone()) {
      root.style.removeProperty("--panel-w");
      return;
    }
    currentWidth = clampWidth(width);
    root.style.setProperty("--panel-w", currentWidth + "px");
    resizer.setAttribute("aria-valuemin", String(MIN_PANEL));
    resizer.setAttribute("aria-valuemax", String(maxWidth()));
    resizer.setAttribute("aria-valuenow", String(currentWidth));
  }

  function keepWidth(width) {
    applyWidth(width);
    preferredWidth = currentWidth;
    writeStored(WIDTH_KEY, String(preferredWidth));
  }

  /** @type {{ pointerId: number, startX: number, startWidth: number, dragged: boolean } | null} */
  let drag = null;
  function endDrag(event) {
    if (!drag || (event && event.pointerId !== drag.pointerId)) return;
    const dragged = drag.dragged;
    try {
      resizer.releasePointerCapture(drag.pointerId);
    } catch {
      // The capture is already gone.
    }
    drag = null;
    document.body.classList.remove("fm-panel-resizing");
    if (dragged) keepWidth(currentWidth);
  }
  resizer.addEventListener("pointerdown", (event) => {
    if (isPhone() || event.button !== 0) return;
    event.preventDefault();
    resizer.focus();
    drag = { pointerId: event.pointerId, startX: event.clientX, startWidth: currentWidth, dragged: false };
    try {
      resizer.setPointerCapture(event.pointerId);
    } catch {
      // Without capture the window listeners below still end the drag.
    }
  });
  resizer.addEventListener("pointermove", (event) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const delta = event.clientX - drag.startX;
    if (!drag.dragged && Math.abs(delta) < DRAG_THRESHOLD) return;
    drag.dragged = true;
    document.body.classList.add("fm-panel-resizing");
    // The panel sits on the right, so moving left widens it.
    applyWidth(drag.startWidth - delta);
  });
  resizer.addEventListener("pointerup", endDrag);
  resizer.addEventListener("pointercancel", endDrag);
  window.addEventListener("pointerup", endDrag);
  resizer.addEventListener("dblclick", () => keepWidth(defaultWidth));
  resizer.addEventListener("keydown", (event) => {
    if (isPhone()) return;
    let next = null;
    if (event.key === "ArrowLeft") next = currentWidth + STEP;
    else if (event.key === "ArrowRight") next = currentWidth - STEP;
    else if (event.key === "Home") next = MIN_PANEL;
    else if (event.key === "End") next = maxWidth();
    if (next === null) return;
    event.preventDefault();
    keepWidth(next);
  });

  const syncWidth = () => applyWidth(preferredWidth);
  window.addEventListener("resize", syncWidth);
  if (phone && typeof phone.addEventListener === "function") phone.addEventListener("change", syncWidth);
  syncWidth();
})();

// Bearings board receipts. A board answer arrives as a user bubble whose words end in the
// "Context data:" JSON Lavish appends for firstmate; when that JSON is a bearings answer
// (fm-bearings-answer.v1, or the board's dispatch order) carrying a receipt, the bubble shows one
// line instead - "Item → action · values (note)", or "Item → “words”" for a note sent alone - and
// hides its element anchor. Only the display changes: the words and the JSON still travel to
// firstmate. Queued bubbles are re-rendered from their prompts, so every render is re-read.
(() => {
  const logs = ["chatLog", "queuedLog"].map((id) => document.getElementById(id)).filter(Boolean);
  if (!logs.length) return;
  const MARK = "\n\nContext data:\n";

  function receiptOf(text) {
    const at = text.lastIndexOf(MARK);
    if (at < 0) return null;
    let data;
    try {
      data = JSON.parse(text.slice(at + MARK.length));
    } catch {
      return null;
    }
    if (!data || typeof data !== "object") return null;
    if (data.schema !== "fm-bearings-answer.v1" && data.question !== "dispatch.charted") return null;
    const r = data.receipt;
    if (!r || typeof r !== "object" || typeof r.item !== "string" || !r.item) return null;
    const str = (v) => (typeof v === "string" ? v : "");
    return { item: r.item, action: str(r.action), detail: str(r.detail), note: str(r.note) };
  }

  function span(cls, text) {
    const s = document.createElement("span");
    s.className = cls;
    s.textContent = text;
    return s;
  }

  // Every bubble is read once: a checked node carries its verdict, so a busy
  // log's mutations rescan nothing they already looked at.
  function render(node) {
    if (node.dataset.fmReceipt) return;
    const receipt = receiptOf(node.textContent || "");
    node.dataset.fmReceipt = receipt ? "1" : "0";
    if (!receipt) return;
    node.textContent = "";
    node.appendChild(span("fm-receipt-item", receipt.item));
    node.appendChild(span("fm-receipt-arrow", " → "));
    if (receipt.action) {
      node.appendChild(span("fm-receipt-action", receipt.action));
      if (receipt.detail) node.appendChild(span("fm-receipt-detail", " · " + receipt.detail));
      if (receipt.note) node.appendChild(span("fm-receipt-note", " (" + receipt.note + ")"));
    } else {
      node.appendChild(span("fm-receipt-words", "“" + receipt.note + "”"));
    }
    const bubble = node.closest(".bubble");
    if (bubble) bubble.classList.add("fm-receipt");
  }

  function scan() {
    for (const log of logs) for (const node of log.querySelectorAll(".bubble.user .bubble-text")) render(node);
  }

  if (typeof MutationObserver === "function") {
    const observer = new MutationObserver(scan);
    for (const log of logs) observer.observe(log, { childList: true, subtree: true });
  }
  scan();
})();
