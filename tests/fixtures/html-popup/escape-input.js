// Esc while an input has focus must not close the window.
const input = document.getElementById("name");
input.focus();
input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
setTimeout(() => {
  htmlPopup.send("still open");
  htmlPopup.cancel();
}, 300);
