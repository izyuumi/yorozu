// The language switcher: remember the visitor's choice so the worker never overrides it, and keep the
// query and #fragment (a pairing or add-a-Mac code) when the same page opens in another language.
for (const link of document.querySelectorAll("a[data-locale]")) {
  link.addEventListener("click", () => {
    document.cookie = `yorozu_lang=${link.dataset.locale}; Path=/; Max-Age=31536000; SameSite=Lax; Secure`;
    link.href = link.href.split(/[?#]/)[0] + location.search + location.hash;
  });
}
