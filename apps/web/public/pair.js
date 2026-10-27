const pairing = location.hash.slice(1);
const open = document.getElementById("open-in-app");
if (open && pairing) {
  open.href = `yorozu://pair?${pairing}`;
  open.hidden = false;
}
