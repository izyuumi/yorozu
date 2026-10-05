// No recording or video poster is downloaded before the visitor opens the demo.
const dialog = document.querySelector('[data-native-demo]');
const button = document.querySelector('[data-demo-play]');
if (dialog && button && typeof dialog.showModal === 'function') {
  const video = dialog.querySelector('[data-demo-player]');
  const poster = dialog.querySelector('[data-demo-poster]');
  const status = dialog.querySelector('[data-demo-status]');
  const webm = video.canPlayType('video/webm; codecs="vp9"');
  const mp4 = video.canPlayType('video/mp4; codecs="avc1.640028"');
  let fallbackUsed = false;
  let generation = 0;
  const fail = () => {
    generation += 1;
    video.pause();
    video.hidden = true;
    poster.hidden = false;
    status.textContent = "The demo couldn't play. Here's a frame from the recording.";
  };
  const retry = () => {
    if (!dialog.open) return;
    if (!fallbackUsed && mp4) {
      fallbackUsed = true;
      start(video.dataset.mp4);
    } else fail();
  };
  const start = (source) => {
    const attempt = ++generation;
    video.src = source;
    video.play()?.catch((error) => {
      if (attempt !== generation || !dialog.open) return;
      if (error.name === 'NotSupportedError') retry();
      else if (error.name === 'NotAllowedError') {
        status.textContent = 'Press Play to start the demo.';
      }
    });
  };
  video.addEventListener('error', () => { if (video.error) retry(); });
  dialog.addEventListener('close', () => {
    generation += 1;
    video.pause();
    video.removeAttribute('src');
    video.load();
  });
  if (webm || mp4) {
    button.hidden = false;
    button.addEventListener('click', () => {
      status.textContent = '';
      poster.src = video.dataset.poster;
      poster.hidden = true;
      video.poster = video.dataset.poster;
      video.hidden = false;
      fallbackUsed = !webm;
      dialog.showModal();
      start(webm ? video.dataset.webm : video.dataset.mp4);
    });
  }
}
