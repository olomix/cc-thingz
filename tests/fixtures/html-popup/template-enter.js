// Return must not answer from a contenteditable element or when a page
// listener calls preventDefault(); plain Return on the page still answers.
const enter = (target) => target.dispatchEvent(new KeyboardEvent("keydown",
  { key: "Enter", bubbles: true, cancelable: true }));
const pause = () => new Promise((resolve) => setTimeout(resolve, 100));
(async () => {
  const editor = document.createElement("div");
  editor.contentEditable = "true";
  editor.textContent = "x";
  document.body.append(editor);
  editor.focus();
  enter(editor);
  await pause();
  htmlPopup.send("contenteditable");
  editor.blur();

  const block = (e) => e.preventDefault();
  document.addEventListener("keydown", block);
  enter(document.body);
  await pause();
  htmlPopup.send("prevented");
  document.removeEventListener("keydown", block);

  enter(document.body);
})();
