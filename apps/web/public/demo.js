// Native recording is requested only after the visitor presses Watch demo.
const demo = document.querySelector('[data-native-demo]');
if (demo) {
  const poster = demo.querySelector('[data-demo-poster]');
  const video = demo.querySelector('[data-demo-player]');
  const button = demo.querySelector('[data-demo-play]');
  const status = demo.querySelector('[data-demo-status]');
  const webm = video.canPlayType('video/webm; codecs="vp9"');
  const mp4 = video.canPlayType('video/mp4; codecs="avc1.640028"');
  let fallbackUsed = false;
  let generation = 0;
  const restore = () => {
    generation += 1;
    video.pause();
    video.hidden = true;
    poster.hidden = false;
    button.hidden = false;
    status.textContent = "The demo couldn't play. The screenshot remains available.";
  };
  const play = () => {
    const attempt = ++generation;
    const pending = video.play();
    if (pending) pending.catch(() => {
      if (attempt === generation) restore();
    });
  };
  video.addEventListener('error', () => {
    if (!fallbackUsed && mp4) {
      fallbackUsed = true;
      video.src = video.dataset.mp4;
      play();
    } else restore();
  });
  if (webm || mp4) {
    button.hidden = false;
    button.addEventListener('click', () => {
      status.textContent = '';
      video.poster = poster.currentSrc || poster.src;
      video.hidden = false;
      poster.hidden = true;
      button.hidden = true;
      fallbackUsed = !webm;
      video.src = webm ? video.dataset.webm : video.dataset.mp4;
      play();
    });
  }
}
