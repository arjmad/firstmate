// Firstmate's local Lavish chrome overlay, head part. bin/fm-lavish-patch.mjs puts this file
// before lavish-axi's own dist/chrome-client.js, so it runs before that script first points the
// artifact iframe at the board. It grants the board fullscreen, so a <video controls> on a board
// can go full screen: Chrome reads an iframe's allow attribute only when the iframe navigates,
// so setting it after the first load does nothing until the board reloads.
(() => {
  const frame = document.getElementById("artifact");
  if (!frame) return;
  const allow = frame.getAttribute("allow") || "";
  if (!/(^|;)\s*fullscreen\b/.test(allow)) frame.setAttribute("allow", allow ? `${allow}; fullscreen` : "fullscreen");
  frame.setAttribute("allowfullscreen", "");
})();
