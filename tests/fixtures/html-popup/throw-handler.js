// A throwing onMessage handler must not stop the handlers after it.
htmlPopup.onMessage(() => { throw new Error("handler failed"); });
htmlPopup.onMessage((value) => htmlPopup.send({ got: value }));
