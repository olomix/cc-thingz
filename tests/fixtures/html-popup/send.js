// Sends an object, a string and a float, then cancels.
htmlPopup.send({ action: "select", month: 7, nested: { list: [1, "two"] } });
htmlPopup.send("plain text");
htmlPopup.send(0.1 + 0.2);
htmlPopup.cancel();
