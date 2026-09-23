// Copy-to-clipboard for any [data-copy="<id>"] button. Buttons ship hidden and are
// revealed here, so a page without JS still shows the selectable text and nothing dead.
for (const button of document.querySelectorAll("[data-copy]")) {
  const source = document.getElementById(button.dataset.copy);
  if (!source) continue;
  button.hidden = false;
  const label = button.textContent;
  button.addEventListener("click", async () => {
    const text = source.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
      button.classList.add("done");
      setTimeout(() => {
        button.textContent = label;
        button.classList.remove("done");
      }, 1600);
    } catch {
      // No clipboard permission: leave the text selected so ⌘C finishes the job.
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
  });
}
