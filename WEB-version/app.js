const audio = new Audio();
const playButton = document.querySelector('#play-toggle');
const prevButton = document.querySelector('button[aria-label="Previous"]');
const nextButton = document.querySelector('button[aria-label="Next"]');
const loopButton = document.querySelector('#loop-toggle');
const searchForm = document.querySelector('#search-form');
const searchInput = document.querySelector('#search-input');
const searchStatus = document.querySelector('#search-status');
const results = document.querySelector('#results');
const volumeSlider = document.querySelector('#volume-slider');
const muteButton = document.querySelector('#mute-toggle');

const searchPage = document.querySelector('#search-page');
const playlistPage = document.querySelector('#playlist-page');
const playlistResults = document.querySelector('#playlist-results');
const playlistList = document.querySelector('#playlist-list');
const libraryEmpty = document.querySelector('#library-empty');
const searchNavButton = document.querySelector('#search-nav');
const contentArea = document.querySelector('.content');
const toastEl = document.querySelector('#toast');

let currentTrack = null;
let searchTracks = [];
let currentQueue = [];
let currentIndex = -1;
let queueSource = null;        // { type: 'search' } | { type: 'playlist', id }
let requestId = 0;

let playlists = [];
let activePlaylistId = null;

let previousVolume = Number(volumeSlider.value);
let openMenu = null;
let toastTimer = null;

/* ------------------------------------------------------------- formatting */
function formatTime(seconds) {
  if (!Number.isFinite(seconds)) return '0:00';
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
}

/* ---------------------------------------------------------------- toasts */
function showToast(message) {
  if (!toastEl) return;
  toastEl.textContent = message;
  toastEl.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('visible'), 2600);
}

/* ------------------------------------------------------- player / playing */
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
  updatePlaylistPlayButton(isPlaying);
}

function updatePlaylistPlayButton(isPlaying) {
  const button = document.querySelector('#playlist-play');
  if (!button) return;
  const fromPlaylist = isPlaying
    && queueSource?.type === 'playlist'
    && queueSource.id === activePlaylistId
    && currentQueue.length > 0;
  button.querySelector('use').setAttribute('href', fromPlaylist ? '#i-pause' : '#i-play');
  const label = button.querySelector('.play-all-label');
  if (label) label.textContent = fromPlaylist ? 'Pause' : 'Play';
  button.setAttribute('aria-label', fromPlaylist ? 'Pause playlist' : 'Play playlist');
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
    showToast('This preview could not be played. Try another track.');
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
  if (track.artworkUrl100) {
    artwork.src = track.artworkUrl100;
    artwork.hidden = false;
  } else {
    artwork.removeAttribute('src');
    artwork.hidden = true;
  }
  playButton.disabled = false;
  updateQueueButtons();
  setPlaying(true);   // optimistic
  playAudio();        // real playback; corrects state on failure
}

/* --------------------------------------------------------------- playlists */
function findPlaylist(id) {
  return playlists.find(playlist => playlist.id === id) || null;
}

function renderPlaylistList() {
  playlistList.replaceChildren();
  libraryEmpty.hidden = playlists.length > 0;

  playlists.forEach(playlist => {
    const item = document.createElement('li');

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'playlist-item';
    if (playlist.id === activePlaylistId) button.classList.add('active');

    const first = playlist.tracks && playlist.tracks[0];
    let thumb;
    if (first && first.artworkUrl100) {
      thumb = document.createElement('img');
      thumb.className = 'playlist-thumb';
      thumb.src = first.artworkUrl100;
      thumb.alt = '';
    } else {
      thumb = document.createElement('span');
      thumb.className = 'playlist-thumb';
      thumb.innerHTML = '<svg><use href="#i-note"></use></svg>';
    }

    const meta = document.createElement('div');
    meta.className = 'playlist-meta';
    const name = document.createElement('strong');
    name.textContent = playlist.name;
    const count = document.createElement('span');
    const total = playlist.tracks.length;
    count.textContent = `${total} song${total === 1 ? '' : 's'}`;
    meta.append(name, count);

    button.append(thumb, meta);
    button.addEventListener('click', () => openPlaylist(playlist.id));
    item.append(button);
    playlistList.append(item);
  });
}

async function loadPlaylists() {
  try {
    const response = await fetch('/api/playlists');
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not load playlists');
    playlists = Array.isArray(data.playlists) ? data.playlists : [];
  } catch (err) {
    playlists = [];
    showToast(err.message || 'Could not load playlists.');
  }
  renderPlaylistList();
}

function showSearchView() {
  activePlaylistId = null;
  renderPlaylistList();
  playlistPage.hidden = true;
  searchPage.hidden = false;
  searchNavButton.classList.add('active');
  closePlaylistMenu();
  updatePlaylistPlayButton(!audio.paused);
}

function openPlaylist(id) {
  const playlist = findPlaylist(id);
  if (!playlist) return;

  activePlaylistId = id;
  renderPlaylistList();
  searchNavButton.classList.remove('active');
  closePlaylistMenu();
  searchPage.hidden = true;
  playlistPage.hidden = false;
  if (contentArea) contentArea.scrollTop = 0;

  renderPlaylistPage(playlist);
}

function renderPlaylistPage(playlist) {
  const tracks = Array.isArray(playlist.tracks) ? playlist.tracks : [];

  const art = document.querySelector('#playlist-art');
  const placeholder = document.querySelector('#playlist-art-placeholder');
  const first = tracks[0];
  if (first && first.artworkUrl100) {
    art.src = first.artworkUrl100;
    art.hidden = false;
    placeholder.hidden = true;
  } else {
    art.removeAttribute('src');
    art.hidden = true;
    placeholder.hidden = false;
  }

  document.querySelector('#playlist-name').textContent = playlist.name;

  const totalMillis = tracks.reduce((sum, track) => sum + (track.trackTimeMillis || 0), 0);
  const count = tracks.length;
  document.querySelector('#playlist-meta').textContent =
    `${count} song${count === 1 ? '' : 's'} · ${formatTime(totalMillis / 1000)}`;

  const playButtonEl = document.querySelector('#playlist-play');
  playButtonEl.disabled = count === 0;

  playlistResults.replaceChildren();
  if (count === 0) {
    const empty = document.createElement('p');
    empty.className = 'playlist-empty';
    empty.textContent = 'This playlist is empty. Add songs from your search results.';
    playlistResults.append(empty);
    setPlaying(!audio.paused);
    return;
  }

  const list = document.createElement('div');
  list.className = 'result-list';
  tracks.forEach((track, index) => {
    list.append(createTrackRow(track, {
      queue: tracks,
      index,
      source: { type: 'playlist', id: playlist.id },
      action: {
        icon: '#i-close',
        label: `Remove ${track.trackName} from ${playlist.name}`,
        onClick: () => removeTrackFromPlaylist(playlist.id, track.trackId)
      }
    }));
  });
  playlistResults.append(list);
  setPlaying(!audio.paused);
}

function playPlaylist(id) {
  const playlist = findPlaylist(id);
  if (!playlist || !playlist.tracks.length) return;

  const isCurrent =
    queueSource?.type === 'playlist' && queueSource.id === id && currentQueue.length > 0;

  if (isCurrent && currentTrack && !audio.paused) {
    pauseAudio();
    return;
  }
  if (isCurrent && currentTrack && audio.paused) {
    playAudio();
    return;
  }

  setQueue(playlist.tracks, 0);
  queueSource = { type: 'playlist', id };
  startTrack(playlist.tracks[0]);
}

function replacePlaylist(playlist) {
  const index = playlists.findIndex(item => item.id === playlist.id);
  if (index === -1) playlists.push(playlist);
  else playlists[index] = playlist;

  renderPlaylistList();
  if (activePlaylistId === playlist.id) renderPlaylistPage(playlist);
  syncQueueWithActivePlaylist();
}

function syncQueueWithActivePlaylist() {
  if (queueSource?.type !== 'playlist') return;
  const playlist = findPlaylist(queueSource.id);
  if (!playlist) return;

  const previousId = currentTrack?.trackId || null;
  currentQueue = playlist.tracks.slice();
  currentIndex = previousId
    ? currentQueue.findIndex(track => track.trackId === previousId)
    : -1;
  updateQueueButtons();
}

async function createPlaylist(name) {
  try {
    const response = await fetch('/api/playlists', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name })
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not create playlist');

    const playlist = data.playlist;
    playlists.push(playlist);
    renderPlaylistList();
    showToast(`Playlist “${playlist.name}” created.`);
    return playlist;
  } catch (err) {
    showToast(err.message || 'Could not create playlist.');
    return null;
  }
}

async function addTrackToPlaylist(playlistId, track) {
  try {
    const response = await fetch(`/api/playlists/${playlistId}/tracks`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ track })
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not add song');

    replacePlaylist(data.playlist);
    if (data.duplicate) {
      showToast(`“${data.playlist.name}” already contains that song.`);
    } else {
      showToast(`Added to “${data.playlist.name}”.`);
    }
    return true;
  } catch (err) {
    showToast(err.message || 'Could not add song.');
    return false;
  }
}

async function removeTrackFromPlaylist(playlistId, trackId) {
  try {
    const response = await fetch(`/api/playlists/${playlistId}/tracks/${trackId}`, {
      method: 'DELETE'
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not remove song');

    replacePlaylist(data.playlist);
    showToast(`Removed from “${data.playlist.name}”.`);
  } catch (err) {
    showToast(err.message || 'Could not remove song.');
  }
}

async function deletePlaylist(id) {
  const playlist = findPlaylist(id);
  if (!playlist) return;
  if (!window.confirm(`Delete the playlist “${playlist.name}”?`)) return;

  try {
    const response = await fetch(`/api/playlists/${id}`, { method: 'DELETE' });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not delete playlist');

    playlists = playlists.filter(item => item.id !== id);
    if (queueSource?.type === 'playlist' && queueSource.id === id) queueSource = null;
    if (activePlaylistId === id) showSearchView();
    renderPlaylistList();
    showToast(`Deleted “${playlist.name}”.`);
  } catch (err) {
    showToast(err.message || 'Could not delete playlist.');
  }
}

/* ------------------------------------------------- "add to playlist" menu */
function closePlaylistMenu() {
  if (!openMenu) return;
  openMenu.remove();
  openMenu = null;
  document.removeEventListener('click', handleMenuOutsideClick, true);
  document.removeEventListener('keydown', handleMenuKeydown, true);
}

function handleMenuOutsideClick(event) {
  if (openMenu && !openMenu.contains(event.target)) closePlaylistMenu();
}

function handleMenuKeydown(event) {
  if (event.key === 'Escape') closePlaylistMenu();
}

function openAddToPlaylistMenu(anchor, track) {
  closePlaylistMenu();

  const menu = document.createElement('div');
  menu.className = 'playlist-menu';
  menu.setAttribute('role', 'menu');

  const title = document.createElement('div');
  title.className = 'playlist-menu-title';
  title.textContent = 'Add to playlist';
  menu.append(title);

  if (!playlists.length) {
    const empty = document.createElement('p');
    empty.className = 'library-empty';
    empty.textContent = 'No playlists yet.';
    menu.append(empty);
  }

  playlists.forEach(playlist => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'playlist-menu-item';
    item.setAttribute('role', 'menuitem');
    const contains = playlist.tracks.some(t => t.trackId === track.trackId);
    if (contains) item.classList.add('contains');
    item.textContent = contains ? `${playlist.name} ✓` : playlist.name;
    item.addEventListener('click', () => {
      closePlaylistMenu();
      addTrackToPlaylist(playlist.id, track);
    });
    menu.append(item);
  });

  const separator = document.createElement('div');
  separator.className = 'playlist-menu-sep';
  menu.append(separator);

  const create = document.createElement('button');
  create.type = 'button';
  create.className = 'playlist-menu-item';
  create.setAttribute('role', 'menuitem');
  create.textContent = '＋ New playlist…';
  create.addEventListener('click', async () => {
    closePlaylistMenu();
    const name = window.prompt('New playlist name');
    if (!name || !name.trim()) return;
    const playlist = await createPlaylist(name.trim());
    if (playlist) await addTrackToPlaylist(playlist.id, track);
  });
  menu.append(create);

  document.body.append(menu);

  const anchorRect = anchor.getBoundingClientRect();
  const menuRect = menu.getBoundingClientRect();
  let top = anchorRect.bottom + 6;
  if (top + menuRect.height > window.innerHeight - 8) {
    top = Math.max(8, anchorRect.top - menuRect.height - 6);
  }
  let left = anchorRect.right - menuRect.width;
  left = Math.max(8, Math.min(left, window.innerWidth - menuRect.width - 8));
  menu.style.top = `${top}px`;
  menu.style.left = `${left}px`;

  openMenu = menu;
  setTimeout(() => {
    document.addEventListener('click', handleMenuOutsideClick, true);
    document.addEventListener('keydown', handleMenuKeydown, true);
  }, 0);
}

/* -------------------------------------------------------------- list rows */
function createTrackRow(track, { queue, index, source, action }) {
  const row = document.createElement('article');
  row.className = 'result-row';

  const artwork = document.createElement('img');
  if (track.artworkUrl100) artwork.src = track.artworkUrl100;
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

  const actionButton = document.createElement('button');
  actionButton.type = 'button';
  actionButton.className = 'result-action';
  actionButton.setAttribute('aria-label', action.label);
  actionButton.innerHTML = `<svg><use href="${action.icon}"></use></svg>`;
  actionButton.addEventListener('click', event => {
    event.stopPropagation();
    action.onClick(actionButton);
  });

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
    setQueue(queue, index);
    queueSource = source;
    startTrack(track);
  });

  row.append(artwork, info, duration, download, actionButton, play);
  return row;
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
  tracks.forEach((track, index) => {
    list.append(createTrackRow(track, {
      queue: tracks,
      index,
      source: { type: 'search' },
      action: {
        icon: '#i-plus',
        label: `Add ${track.trackName} to playlist`,
        onClick: anchor => openAddToPlaylistMenu(anchor, track)
      }
    }));
  });
  results.append(heading, list);
  setPlaying(!audio.paused);
}

/* ---------------------------------------------------------- search submit */
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

/* --------------------------------------------------------- player controls */
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
  document.querySelector('#progress').style.width =
    `${audio.duration ? (audio.currentTime / audio.duration) * 100 : 0}%`;
});
audio.addEventListener('loadedmetadata', () => {
  document.querySelector('#duration').textContent = formatTime(audio.duration);
});

document.querySelector('#seek-bar').addEventListener('click', event => {
  if (!audio.duration) return;
  const bounds = event.currentTarget.getBoundingClientRect();
  audio.currentTime = ((event.clientX - bounds.left) / bounds.width) * audio.duration;
});

/* -------------------------------------------------- navigation & playlists */
document.querySelector('#search-nav').addEventListener('click', () => {
  showSearchView();
  searchInput.focus();
});
document.querySelector('#mobile-search-nav').addEventListener('click', () => {
  showSearchView();
  searchInput.focus();
});

document.querySelector('#new-playlist-button').addEventListener('click', async () => {
  const name = window.prompt('Playlist name');
  if (!name || !name.trim()) return;
  const playlist = await createPlaylist(name.trim());
  if (playlist) openPlaylist(playlist.id);
});

document.querySelector('#playlist-play').addEventListener('click', () => {
  if (activePlaylistId) playPlaylist(activePlaylistId);
});
document.querySelector('#playlist-delete').addEventListener('click', () => {
  if (activePlaylistId) deletePlaylist(activePlaylistId);
});

/* ------------------------------------------------------------------ volume */
function updateVolumeControl() {
  const value = Number(volumeSlider.value);
  audio.volume = value;
  volumeSlider.style.setProperty('--volume-level', `${value * 100}%`);
  const muted = value === 0;
  muteButton.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
  muteButton.querySelector('use').setAttribute('href', muted ? '#i-volume-muted' : '#i-volume');
}

volumeSlider.addEventListener('input', () => {
  if (Number(volumeSlider.value) > 0) previousVolume = Number(volumeSlider.value);
  updateVolumeControl();
});
muteButton.addEventListener('click', () => {
  if (Number(volumeSlider.value) > 0) {
    previousVolume = Number(volumeSlider.value);
    volumeSlider.value = '0';
  } else {
    volumeSlider.value = String(previousVolume || 0.7);
  }
  updateVolumeControl();
});

/* ------------------------------------------------------------------- init */
updateVolumeControl();
loadPlaylists();
setPlaying(false);