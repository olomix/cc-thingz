// Esc with no editable element focused closes the window.
document.activeElement && document.activeElement.blur();
document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
