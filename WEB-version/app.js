const audio = new Audio();
const playButton = document.querySelector('#play-toggle');
const prevButton = document.querySelector('button[aria-label="Previous"]');
const nextButton = document.querySelector('button[aria-label="Next"]');
const loopButton = document.querySelector('#loop-toggle');
const searchForm = document.querySelector('#search-form');
const searchInput = document.querySelector('#search-input');
const searchStatus = document.querySelector('#search-status');
const results = document.querySelector('#results');

let currentTrack = null;
let searchTracks = [];
let currentQueue = [];
let currentIndex = -1;
let requestId = 0;

function formatTime(seconds) {
  if (!Number.isFinite(seconds)) return '0:00';
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
}

function setPlaying(isPlaying) {
  playButton.setAttribute('aria-label', isPlaying ? 'Pause' : 'Play');
  playButton.querySelector('use').setAttribute('href', isPlaying ? '#i-pause' : '#i-play');
  document.querySelectorAll('[data-preview]').forEach(button => {
    const isCurrent = button.dataset.preview === String(currentTrack?.trackId);
    const buttonPlaying = isCurrent && isPlaying;
    button.querySelector('use').setAttribute('href', buttonPlaying ? '#i-pause' : '#i-play');
    const row = button.closest('.result-row');
    const title = row?.querySelector('.result-info strong')?.textContent
      || currentTrack?.trackName
      || 'track';
    button.setAttribute('aria-label', `${buttonPlaying ? 'Pause' : 'Play'} ${title}`);
  });
}

function updateQueueButtons() {
  const hasQueue = currentQueue.length > 0;
  if (prevButton) prevButton.disabled = !hasQueue;
  if (nextButton) nextButton.disabled = !hasQueue;
}

function pauseAudio() {
  audio.pause();
  setPlaying(false);
}

function playAudio() {
  return audio.play().then(() => setPlaying(true)).catch(() => {
    searchStatus.textContent = 'This preview could not be played. Try another result.';
    setPlaying(false);
  });
}

const DOWNLOAD_ICON =
  '<svg viewBox="0 0 24 24" aria-hidden="true">' +
  '<path d="M12 3v12m0 0 4.5-4.5M12 15 7.5 10.5M5 21h14" ' +
  'fill="none" stroke="currentColor" stroke-width="2" ' +
  'stroke-linecap="round" stroke-linejoin="round"/></svg>';

function setQueue(tracks, index) {
  currentQueue = Array.isArray(tracks) ? tracks.slice() : [];
  currentIndex = index;
  updateQueueButtons();
}

function playIndex(index) {
  if (index < 0 || index >= currentQueue.length) return;
  currentIndex = index;
  startTrack(currentQueue[index]);
}

function playNext() {
  if (currentQueue.length === 0) return;
  playIndex((currentIndex + 1) % currentQueue.length);
}

function playPrev() {
  if (currentQueue.length === 0) return;
  if (audio.currentTime > 3) {
    audio.currentTime = 0;
    return;
  }
  playIndex((currentIndex - 1 + currentQueue.length) % currentQueue.length);
}

function startTrack(track) {
  currentTrack = track;
  audio.src = track.previewUrl;
  document.querySelector('#now-title').textContent = track.trackName;
  document.querySelector('#now-artist').textContent = track.artistName;
  const artwork = document.querySelector('#now-art');
  artwork.src = track.artworkUrl100 || '';
  artwork.hidden = !artwork.src;
  playButton.disabled = false;
  updateQueueButtons();
  setPlaying(true);   // optimistic: icons update immediately
  playAudio();        // real playback; corrects state on failure
}

function renderResults(tracks = []) {
  searchTracks = tracks;
  results.replaceChildren();
  if (!tracks.length) return;
  const heading = document.createElement('h2');
  heading.className = 'results-heading';
  heading.textContent = 'Songs';
  const list = document.createElement('div');
  list.className = 'result-list';
  tracks.forEach((track, idx) => {
    const row = document.createElement('article');
    row.className = 'result-row';

    const artwork = document.createElement('img');
    artwork.src = track.artworkUrl100 || '';
    artwork.alt = '';

    const info = document.createElement('div');
    info.className = 'result-info';
    const title = document.createElement('strong');
    title.textContent = track.trackName;
    const artist = document.createElement('span');
    artist.textContent = `${track.artistName} · ${track.collectionName || 'Single'}`;
    info.append(title, artist);

    const duration = document.createElement('span');
    duration.className = 'result-duration';
    duration.textContent = formatTime((track.trackTimeMillis || 0) / 1000);

    const download = document.createElement('a');
    download.className = 'result-download';
    download.href = `/api/download/${track.trackId}?name=${encodeURIComponent(track.trackName)}`;
    download.setAttribute('download', '');
    download.setAttribute('aria-label', `Download ${track.trackName}`);
    download.innerHTML = DOWNLOAD_ICON;

    const play = document.createElement('button');
    play.className = 'result-play';
    play.dataset.preview = track.trackId;
    play.setAttribute('aria-label', `Play ${track.trackName}`);
    play.innerHTML = '<svg><use href="#i-play"></use></svg>';
    play.addEventListener('click', () => {
      if (currentTrack?.trackId === track.trackId && !audio.paused) {
        pauseAudio();
        return;
      }
      setQueue(searchTracks, idx);
      startTrack(track);
    });

    row.append(artwork, info, duration, download, play);
    list.append(row);
  });
  results.append(heading, list);
  setPlaying(!audio.paused);
}

searchForm.addEventListener('submit', async event => {
  event.preventDefault();
  const term = searchInput.value.trim();
  if (!term) {
    searchStatus.textContent = 'Enter a song, artist, or playlist URL.';
    results.replaceChildren();
    return;
  }
  const thisRequest = ++requestId;
  searchStatus.textContent = 'Searching…';
  results.replaceChildren();
  try {
    const response = await fetch('/api/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: term })
    });
    const data = await response.json().catch(() => ({}));
    if (thisRequest !== requestId) return;
    if (!response.ok) throw new Error(data.error || 'Search failed');
    const tracks = (data.tracks || []).filter(track => track.previewUrl);
    searchStatus.textContent = tracks.length ? '' : 'No playable results found. Try another search.';
    renderResults(tracks);
  } catch (err) {
    if (thisRequest === requestId) {
      searchStatus.textContent = err.message || 'Search is unavailable right now.';
    }
  }
});

playButton.addEventListener('click', () => {
  if (!currentTrack) return;
  if (audio.paused) playAudio();
  else pauseAudio();
});

if (prevButton) prevButton.addEventListener('click', playPrev);
if (nextButton) nextButton.addEventListener('click', playNext);

loopButton.addEventListener('click', () => {
  audio.loop = !audio.loop;
  loopButton.setAttribute('aria-pressed', String(audio.loop));
  loopButton.setAttribute('aria-label', audio.loop ? 'Loop on' : 'Loop off');
});

audio.addEventListener('play', () => setPlaying(true));
audio.addEventListener('ended', () => {
  if (currentQueue.length === 0) {
    setPlaying(false);
    return;
  }
  playIndex((currentIndex + 1) % currentQueue.length);
});
audio.addEventListener('timeupdate', () => {
  document.querySelector('#elapsed').textContent = formatTime(audio.currentTime);
  document.querySelector('#progress').style.width = `${audio.duration ? (audio.currentTime / audio.duration) * 100 : 0}%`;
});
audio.addEventListener('loadedmetadata', () => {
  document.querySelector('#duration').textContent = formatTime(audio.duration);
});

document.querySelector('#seek-bar').addEventListener('click', event => {
  if (!audio.duration) return;
  const bounds = event.currentTarget.getBoundingClientRect();
  audio.currentTime = ((event.clientX - bounds.left) / bounds.width) * audio.duration;
});
document.querySelector('#search-nav').addEventListener('click', () => searchInput.focus());
document.querySelector('#mobile-search-nav').addEventListener('click', () => searchInput.focus());