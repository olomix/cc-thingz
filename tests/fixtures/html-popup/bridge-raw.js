// Posts straight to the message handler, bypassing the bridge helpers;
// only strict one-line JSON values may become events.
const raw = webkit.messageHandlers.htmlPopup;
raw.postMessage({ type: "send", value: "{\n \"a\": 1\n}" });
raw.postMessage({ type: "send", value: "nope" });
raw.postMessage({ type: "send", value: '{"a":1,}' });
raw.postMessage({ type: "send", value: "[1, ]" });
raw.postMessage({ type: "send", value: "\uFEFF1" });
raw.postMessage({ type: "bogus" });
raw.postMessage("not an object");
htmlPopup.send(undefined);
htmlPopup.send(() => 1);
htmlPopup.send({ a: 1 });
raw.postMessage({ type: "send", value: '{"b":"x,}"}' });
htmlPopup.cancel();
