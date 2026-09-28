// The pairing QR's page, for a phone that opened it in the browser rather than in Yorozu.
// The pairing is in the fragment, which never leaves this device: it is only ever handed to
// the app, through the "Open in Yorozu" link, and never sent anywhere or stored.
const pairing = location.hash.slice(1);
const open = document.getElementById("open-in-app");
if (open && pairing) {
  open.href = `yorozu://pair?${pairing}`;
  open.hidden = false;
}
