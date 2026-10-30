// Moves from the focused peak month (July) to June and chooses it; once the
// agent's details render, sends the panel text back and presses Done.
const key = (k) => document.body.dispatchEvent(
  new KeyboardEvent("keydown", { key: k, bubbles: true }));
htmlPopup.onMessage(() => setTimeout(() => {
  const panel = document.getElementById("details");
  htmlPopup.send({ hidden: panel.hidden, text: panel.textContent });
  document.getElementById("answer").click();
}, 0));
key("ArrowLeft");
key("Enter");
