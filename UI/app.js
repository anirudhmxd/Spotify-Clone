const audio = new Audio();
    const playButton = document.querySelector('#play-toggle');
    const searchForm = document.querySelector('#search-form');
    const searchInput = document.querySelector('#search-input');
    const searchStatus = document.querySelector('#search-status');
    const results = document.querySelector('#results');
    let currentTrack = null;
    let searchTracks = [];
    let requestId = 0;

    function formatTime(seconds) {
      if (!Number.isFinite(seconds)) return '0:00';
      return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
    }
    function setPlaying(isPlaying) {
      playButton.setAttribute('aria-label', isPlaying ? 'Pause' : 'Play');
      playButton.querySelector('use').setAttribute('href', isPlaying ? '#i-pause' : '#i-play');
      document.querySelectorAll('[data-preview]').forEach(button => {
        const active = button.dataset.preview === String(currentTrack?.trackId);
        button.querySelector('use').setAttribute('href', active && isPlaying ? '#i-pause' : '#i-play');
        button.setAttribute('aria-label', `${active && isPlaying ? 'Pause' : 'Play'} ${currentTrack?.trackName || 'track'}`);
      });
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
      tracks.forEach(track => {
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
        duration.textContent = formatTime(track.trackTimeMillis / 1000);
        const play = document.createElement('button');
        play.className = 'result-play';
        play.dataset.preview = track.trackId;
        play.setAttribute('aria-label', `Play ${track.trackName}`);
        play.innerHTML = '<svg><use href="#i-play"></use></svg>';
        play.addEventListener('click', () => {
          if (currentTrack?.trackId === track.trackId && !audio.paused) audio.pause();
          else startTrack(track);
        });
        row.append(artwork, info, duration, play);
        list.append(row);
      });
      results.append(heading, list);
      setPlaying(!audio.paused);
    }
    function startTrack(track) {
      currentTrack = track;
      audio.src = track.previewUrl;
      document.querySelector('#now-title').textContent = track.trackName;
      document.querySelector('#now-artist').textContent = track.artistName;
      const artwork = document.querySelector('#now-art');
      artwork.src = track.artworkUrl100?.replace('100x100bb', '200x200bb') || '';
      artwork.hidden = !artwork.src;
      playButton.disabled = false;
      audio.play().then(() => setPlaying(true)).catch(() => {
        searchStatus.textContent = 'This preview could not be played. Try another result.';
        setPlaying(false);
      });
      renderResults(searchTracks);
    }
    searchForm.addEventListener('submit', async event => {
      event.preventDefault();
      const term = searchInput.value.trim();
      if (!term) {
        searchStatus.textContent = 'Enter a song or artist to search.';
        results.replaceChildren();
        return;
      }
      const thisRequest = ++requestId;
      searchStatus.textContent = 'Searching…';
      results.replaceChildren();
      try {
        const response = await fetch(`https://itunes.apple.com/search?${new URLSearchParams({ term, entity: 'song', limit: '25' })}`);
        if (!response.ok) throw new Error('Search failed');
        const data = await response.json();
        if (thisRequest !== requestId) return;
        const tracks = data.results.filter(track => track.previewUrl);
        searchStatus.textContent = tracks.length ? '' : 'No playable previews found. Try another search.';
        renderResults(tracks);
      } catch {
        if (thisRequest === requestId) searchStatus.textContent = 'Search is unavailable right now. Check your connection and try again.';
      }
    });
    playButton.addEventListener('click', () => {
      if (!currentTrack) return;
      if (audio.paused) audio.play().then(() => setPlaying(true));
      else audio.pause();
    });
    const loopButton = document.querySelector('#loop-toggle');
    loopButton.addEventListener('click', () => {
      audio.loop = !audio.loop;
      loopButton.setAttribute('aria-pressed', String(audio.loop));
      loopButton.setAttribute('aria-label', audio.loop ? 'Loop on' : 'Loop off');
    });
    audio.addEventListener('play', () => setPlaying(true));
    audio.addEventListener('pause', () => setPlaying(false));
    audio.addEventListener('ended', () => setPlaying(false));
    audio.addEventListener('timeupdate', () => {
      document.querySelector('#elapsed').textContent = formatTime(audio.currentTime);
      document.querySelector('#progress').style.width = `${audio.duration ? (audio.currentTime / audio.duration) * 100 : 0}%`;
    });
    audio.addEventListener('loadedmetadata', () => document.querySelector('#duration').textContent = formatTime(audio.duration));
    document.querySelector('#seek-bar').addEventListener('click', event => {
      if (!audio.duration) return;
      const bounds = event.currentTarget.getBoundingClientRect();
      audio.currentTime = ((event.clientX - bounds.left) / bounds.width) * audio.duration;
    });
    document.querySelector('#search-nav').addEventListener('click', () => searchInput.focus());
    document.querySelector('#mobile-search-nav').addEventListener('click', () => searchInput.focus());
