// Render a built bearings board's shipped inline script under a minimal DOM
// shim, optionally drive it the way the captain would, and print what the
// renderer produced, so board behavior is asserted through the real template
// rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [<steps.json>] [<storage.json>]
// steps.json is a list of interactions, applied in order:
//   {"do":"action","key":<item key>,"value":<action value>,"values":{<input>:<v>},"note":<text>}
//   {"do":"type","key":<key>,"values":{...},"note":<text>}          type without sending
//   {"do":"note","key":<item or card key>,"note":<text>}          Send note
//   {"do":"answer","key":<card key>,"pick":<option value>,"note":<text>}  pick omitted keeps the preset
//   {"do":"take-all"} / {"do":"confirm"}                             Take all recommendations
//   {"do":"toggle","sec":<section key>}                              fold or unfold a section
//   {"do":"tick","key":<item key>,"picks":[<row id>...]}             tick an item's checkboxes
//   {"do":"press","key":<item key>,"label":<button text>}            tap an item's button by its text
// storage.json seeds the viewer's localStorage.
// Prints one JSON document:
//   { headline, inboxCount, fleetSum, sections:[{key,title,count,open,depth,items,rows,empty,headings}],
//     takeAll:{hidden,label,confirm:[...]}, prompts:[{text,line,data}], storage:{...}, error }
// An item is {key,title,ask,against,meta,sent,pill,actions:[{value,label,hint,main}],
//   inputs:[{name,type,value,need}],radios:[{value,label,checked,recommended}],noteNeed}.
// A row is {title,meta,right,steps,pick}.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const steps = process.argv[3] ? JSON.parse(readFileSync(process.argv[3], "utf8")) : [];
const seeded = process.argv[4] ? JSON.parse(readFileSync(process.argv[4], "utf8")) : {};

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.listeners = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.open = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.style = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, on) => {
        if (on === undefined) on = !this.classList.contains(c);
        if (on) this.classList.add(c); else this.classList.remove(c);
      },
    };
  }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) {
    // as in a browser, text set earlier stays as the first child's text
    if (!this.children.length && this._text) {
      const t = new Node("#text");
      t._text = this._text;
      t.parentNode = this;
      this.children.push(t);
      this._text = "";
    }
    n.parentNode = this;
    this.children.push(n);
    return n;
  }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type) {
    // a browser never delivers a tap to an element that is not shown or disabled
    if (this.disabled) return;
    for (let n = this; n; n = n.parentNode) if (n.hidden) return;
    for (const fn of this.listeners[type] || []) fn({ type, target: this, preventDefault() {} });
  }
  focus() { focused = this; }
  has(cls) { return this.classList.contains(cls); }
  all(pred) {
    const out = [];
    const walk = (n) => { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  find(pred) { return this.all(pred)[0] ?? null; }
  querySelectorAll(sel) {
    return sel.startsWith(".") ? this.all((c) => c.has(sel.slice(1))) : this.all((c) => c.tagName === sel);
  }
}

let focused = null;
const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);
const mainNode = new Node("main");

globalThis.document = {
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
  querySelector: () => mainNode,
};
const store = new Map(Object.entries(seeded));
const prompts = [];
globalThis.window = {
  localStorage: {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
  },
  lavish: { queuePrompt: (text, opts) => prompts.push({ text, line: opts.text, data: opts.data }) },
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.lastIndexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const inbox = document.getElementById("bb-inbox");
const fleet = document.getElementById("bb-fleet");
const roots = [inbox, fleet];
const allSections = () => roots.flatMap((r) => r.all((n) => n.tagName === "details"));
const itemByKey = (key) => roots.flatMap((r) => r.all((n) => n.has("bb-item") && n.getAttribute("data-key") === key))[0];

for (const step of steps) {
  if (step.do === "toggle") {
    const d = allSections().find((s) => s.getAttribute("data-sec") === step.sec);
    d.open = !d.open;
    d.fire("toggle");
    continue;
  }
  if (step.do === "take-all") {
    inbox.find((n) => n.tagName === "button" && n.textContent.startsWith("Take all")).fire("click");
    continue;
  }
  if (step.do === "confirm") {
    inbox.find((n) => n.has("bb-confirm")).find((n) => n.has("fm-btn--primary")).fire("click");
    continue;
  }
  const item = itemByKey(step.key);
  if (!item) throw new Error("no item " + step.key);
  for (const [name, v] of Object.entries(step.values || {})) {
    item.find((n) => n.tagName === "input" && n.name === name).value = v;
  }
  if (step.note !== undefined) item.find((n) => n.has("bb-note__in")).value = step.note;
  if (step.do === "tick") {
    for (const box of item.all((n) => n.has("bb-pick"))) {
      if (step.picks.includes(box.value)) { box.checked = true; box.fire("change"); }
    }
  } else if (step.do === "press") {
    item.find((n) => n.tagName === "button" && n.has("fm-btn") && n.textContent === step.label).fire("click");
  } else if (step.do === "action") {
    item.find((n) => n.tagName === "button" && n.getAttribute("data-action") === step.value).fire("click");
  } else if (step.do === "note") {
    item.find((n) => n.has("bb-send")).fire("click");
  } else if (step.do === "answer") {
    if (step.pick !== undefined) {
      for (const r of item.all((n) => n.type === "radio")) r.checked = r.value === step.pick;
    }
    item.find((n) => n.has("bb-cardacts")).find((n) => n.tagName === "button").fire("click");
  }
}

const text = (n, cls) => n.find((c) => c.has(cls))?.textContent ?? null;
function itemOf(n) {
  return {
    key: n.getAttribute("data-key"),
    title: text(n, "bb-item__title"),
    ask: text(n, "bb-item__ask"),
    against: text(n, "bb-against"),
    meta: text(n, "bb-item__meta"),
    sent: n.has("is-sent"),
    pill: n.find((c) => c.has("bb-sent") && !c.hidden)?.textContent ?? null,
    actions: n.all((c) => c.has("bb-act")).map((b) => ({
      value: b.getAttribute("data-action"), label: text(b, "bb-act__l"), hint: text(b, "bb-act__h"),
      main: b.has("bb-act--main"),
    })),
    inputs: n.all((c) => c.has("bb-f")).map((f) => {
      const i = f.find((c) => c.tagName === "input");
      return { name: i.name, type: i.type, value: i.value, need: f.has("is-need") };
    }),
    radios: n.all((c) => c.type === "radio").map((r) => {
      const lab = r.parentNode;
      return { value: r.value, label: text(lab, "fm-opt__label"), checked: r.checked, recommended: lab.find((c) => c.has("fm-rec")) !== null };
    }),
    noteNeed: n.find((c) => c.has("bb-note"))?.has("is-need") ?? false,
  };
}
function rowOf(n) {
  const bar = n.find((c) => c.has("bb-steps"));
  return {
    title: text(n, "bb-row__t"),
    meta: text(n, "bb-row__m"),
    right: text(n, "bb-row__r"),
    steps: bar ? text(bar, "bb-steps__n") : null,
    pick: n.find((c) => c.has("bb-pick")) !== null,
  };
}
const depthOf = (d) => { let k = 0; for (let p = d.parentNode; p; p = p.parentNode) if (p.tagName === "details") k++; return k; };
const ownBody = (d) => d.children.find((c) => c.has("bb-sec__b"));
function shallow(d, pred) {
  // the section's own content, not that of a section folded inside it
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (c.tagName === "details") continue; if (pred(c)) out.push(c); walk(c); } };
  walk(ownBody(d));
  return out;
}
const sections = allSections().map((d) => {
  const summary = d.children.find((c) => c.tagName === "summary");
  return {
    key: d.getAttribute("data-sec"),
    title: text(summary, "bb-sec__t"),
    count: text(summary, "bb-sec__n"),
    open: d.open,
    depth: depthOf(d),
    items: shallow(d, (c) => c.has("bb-item")).map(itemOf),
    rows: shallow(d, (c) => c.has("bb-row")).map(rowOf),
    empty: shallow(d, (c) => c.has("bb-empty")).map((c) => c.textContent),
    headings: shallow(d, (c) => c.has("bb-h4")).map((c) => c.textContent),
    asides: shallow(d, (c) => c.has("bb-aside")).map((c) => c.textContent),
  };
});
const takeAllNode = inbox.find((n) => n.has("bb-takeall"));
const confirmNode = takeAllNode?.find((n) => n.has("bb-confirm"));

process.stdout.write(JSON.stringify({
  headline: document.getElementById("bb-headline").textContent,
  inboxCount: document.getElementById("bb-inbox-count").textContent,
  fleetSum: document.getElementById("bb-fleet-sum").textContent,
  sections,
  takeAll: takeAllNode ? {
    hidden: takeAllNode.hidden,
    label: takeAllNode.find((n) => n.tagName === "button")?.textContent,
    confirm: confirmNode && !confirmNode.hidden
      ? confirmNode.find((n) => n.has("bb-confirm__list")).children.map((c) => c.textContent) : null,
  } : null,
  prompts,
  storage: Object.fromEntries(store),
  focused: focused ? (focused.name || focused.className) : null,
  error: mainNode.textContent,
}) + "\n");
