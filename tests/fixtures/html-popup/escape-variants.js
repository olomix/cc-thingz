// Esc must not close the window inside editable elements, with
// closeOnEscape off, or when a page listener on document (added after the
// bridge's) calls preventDefault(). Sends a marker after each case.
const esc = (target) => target.dispatchEvent(new KeyboardEvent("keydown",
  { key: "Escape", bubbles: true, cancelable: true }));
const pause = () => new Promise((resolve) => setTimeout(resolve, 100));
(async () => {
  for (const html of ["<textarea></textarea>",
    "<select><option>a</option></select>",
    '<div contenteditable="true">x</div>']) {
    const holder = document.createElement("div");
    holder.innerHTML = html;
    document.body.append(holder);
    const el = holder.firstChild;
    el.focus();
    esc(el);
    await pause();
    htmlPopup.send(el.tagName.toLowerCase());
    el.blur();
  }
  htmlPopup.closeOnEscape = false;
  esc(document.body);
  await pause();
  htmlPopup.send("closeOnEscape off");
  htmlPopup.closeOnEscape = true;

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") e.preventDefault();
  });
  esc(document.body);
  await pause();
  htmlPopup.send("prevented");
  htmlPopup.cancel();
})();
