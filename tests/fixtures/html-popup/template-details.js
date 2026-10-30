// After the template renders an agent message, sends the panel text back.
htmlPopup.onMessage(() => setTimeout(() => {
  const panel = document.getElementById("details");
  htmlPopup.send({ hidden: panel.hidden, text: panel.textContent });
}, 0));
