// Copy buttons: <button data-copy="ID"> copies the text of #ID and reports in #ID-status.
// The page supplies the translated words in data-copied, data-status and data-failed.
for (const button of document.querySelectorAll("[data-copy]")) {
  const source = document.getElementById(button.dataset.copy);
  if (!source) continue;
  button.hidden = false;
  const label = button.textContent;
  const words = {
    copied: button.dataset.copied || "Copied",
    status: button.dataset.status || "Copied.",
    failed: button.dataset.failed || "Couldn’t copy automatically. The text is selected; use your device’s Copy command.",
  };
  const status = document.getElementById(`${button.dataset.copy}-status`);
  let resetTimer;
  let latestAttempt = 0;
  button.addEventListener("click", async () => {
    const attempt = ++latestAttempt;
    clearTimeout(resetTimer);
    button.textContent = label;
    button.classList.remove("done");
    if (status) status.textContent = "";
    const text = source.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
      if (attempt !== latestAttempt) return;
      button.textContent = words.copied;
      button.classList.add("done");
      if (status) status.textContent = words.status;
      resetTimer = setTimeout(() => {
        button.textContent = label;
        button.classList.remove("done");
      }, 1600);
    } catch {
      if (attempt !== latestAttempt) return;
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      if (status) status.textContent = words.failed;
    }
  });
}
