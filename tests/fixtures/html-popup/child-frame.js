// A sandboxed srcdoc iframe posts straight to the native handler; the
// viewer must drop it, so the main page's cancel decides the outcome.
const frame = document.createElement("iframe");
frame.sandbox = "allow-scripts";
frame.srcdoc = "<script>webkit.messageHandlers.htmlPopup.postMessage(" +
  "{ type: 'answer', value: '\"from iframe\"' });</" + "script>";
frame.addEventListener("load", () => setTimeout(() => htmlPopup.cancel(), 500));
document.body.append(frame);
