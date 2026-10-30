/* Rhythm browser UI. All catalog, library, settings, and file endpoints are Python. */
'use strict';
const $=selector=>document.querySelector(selector);
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icon=name=>`<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
const logo='/assets/rhythm-icon.png';
const defaults={displayName:'Your music',autoplay:true,offline:false,privateSession:false,speed:1,volume:.7,equalizer:'flat',streamingQuality:'high',downloadQuality:'high'};
let profile={settings:{...defaults},playlists:[],liked:[],recent:[],listening:[],searches:[],downloads:[],songs:[]};
let ready=false,profileError='',page='home',pageId='',libraryFilter='',librarySort='recent',replayYear=new Date().getFullYear();
const audio=new Audio();audio.preload='metadata';
const queue=new Rhythm.Queue(),listening=new Rhythm.Listening();
let currentTrack=null,playToken=0,buffering=false,playbackError=false,previousVolume=.7,sleepTimer=null,sleepUntil=null,sleepAfterTrack=false;
let toastTimer,volumeTimer,loadTimer,settingsWrites=Promise.resolve(),listeningWrites=Promise.resolve(),settingsVersion=0;
let audioContext=null,filters=[],jobs=[],pollTimer=null,dialogMode=null,editor=null,dragIndex=null;
let listeningDay=localDay(),listeningOutbox=[];
try{listeningOutbox=JSON.parse(localStorage.getItem('rhythm-listening-outbox')||'[]');if(!Array.isArray(listeningOutbox))listeningOutbox=[];}catch{}
let requestId=0,searchQuery='',searchPageNumber=0,searchTracks=[],loadMoreButton=null;
const searchInput=$('#search-input'),searchStatus=$('#search-status'),results=$('#results');
const modal=$('#modal');
function formatTime(seconds){if(!Number.isFinite(seconds)||seconds<0)return '0:00';return `${Math.floor(seconds/60)}:${String(Math.floor(seconds%60)).padStart(2,'0')}`;}
function localDay(){const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;}
function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),4500);}
async function api(path,{method='GET',body,timeout=20000,keepalive=false}={}){
  const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),timeout);
  try{
    const response=await fetch(path,{method,signal:abort.signal,keepalive,headers:body instanceof FormData?{}:body?{'Content-Type':'application/json'}:{},body:body instanceof FormData?body:body?JSON.stringify(body):undefined});
    const data=await response.json().catch(()=>({}));
    if(!response.ok)throw new Error(data.error||'That change could not be saved.');return data;
  }catch(error){if(error.name==='AbortError')throw new Error('The request took too long. Please retry.');throw error;}
  finally{clearTimeout(timer);}
}
function allTracks(){return [...searchTracks,...queue.tracks,...profile.liked,...profile.recent,...profile.songs,...profile.downloads.map(r=>r.track),...profile.playlists.flatMap(p=>p.tracks)];}
function trackById(id){
  if(!id)return undefined;
  for(const tracks of [searchTracks,queue.tracks,profile.liked,profile.recent,profile.songs]){
    const match=tracks.find(t=>t.trackId===id);if(match)return match;
  }
  const saved=profile.downloads.find(r=>r.track.trackId===id);if(saved)return saved.track;
  for(const playlist of profile.playlists){const match=playlist.tracks.find(t=>t.trackId===id);if(match)return match;}
}
function isLiked(track){return profile.liked.some(t=>t.trackId===track.trackId);}
function isSaved(track){return profile.downloads.some(r=>r.track.trackId===track.trackId);}
function art(track){return esc(track?.artworkUrl100||logo);}
function title(text,subtitle=''){return `<h1>${esc(text)}</h1>${subtitle?`<p class="subtitle">${esc(subtitle)}</p>`:''}`;}
function empty(text){return `<div class="empty">${esc(text)}</div>`;}
function button(text,action,extra='',ghost=true){return `<button class="pill${ghost?' ghost':''}" data-action="${action}" ${extra}>${text}</button>`;}
function rows(tracks,{playlistId='',rank=true}={}){
  if(!tracks.length)return '';
  const liked=new Set(profile.liked.map(t=>t.trackId));
  const saved=new Set(profile.downloads.map(r=>r.track.trackId));
  return `<div class="row-header"><span>#</span><span></span><span>TITLE / ARTIST</span><span>TIME</span><span></span></div><div class="result-list">`+tracks.map((t,i)=>`<article class="result-row${currentTrack?.trackId===t.trackId?' current':''}" data-track="${esc(t.trackId)}">
    <span class="track-rank">${rank?i+1:''}</span><img src="${art(t)}" alt="" loading="lazy"><div class="result-info"><button class="track-title" data-action="play-row" data-index="${i}" data-id="${esc(t.trackId)}">${esc(t.trackName)}</button><button class="track-artist" data-action="artist" data-id="${esc(t.trackId)}">${esc(t.artistName)}${saved.has(t.trackId)?' · Downloaded':''}</button></div>
    <span class="track-duration">${formatTime(t.trackTimeMillis/1000)}</span><button class="icon-button like-button${liked.has(t.trackId)?' liked':''}" data-action="like" data-id="${esc(t.trackId)}" aria-label="${liked.has(t.trackId)?'Unlike':'Like'} ${esc(t.trackName)}" aria-pressed="${liked.has(t.trackId)}">${icon('heart')}</button><button class="icon-button" data-action="song-menu" data-id="${esc(t.trackId)}" data-playlist="${esc(playlistId)}" aria-label="Options for ${esc(t.trackName)}">${icon('more')}</button><button class="icon-button track-play" data-action="play-row" data-index="${i}" data-id="${esc(t.trackId)}" aria-label="Play ${esc(t.trackName)}">${icon(currentTrack?.trackId===t.trackId&&!audio.paused?'pause':'play')}</button></article>`).join('')+'</div>';
}
function visiblePlaylists(){return profile.playlists.filter(p=>p.name.toLowerCase().includes(libraryFilter.toLowerCase())).sort((a,b)=>Number(b.pinned)-Number(a.pinned)||(librarySort==='name'?a.name.localeCompare(b.name):librarySort==='size'?b.tracks.length-a.tracks.length:(b.createdAt||0)-(a.createdAt||0)));}
function playlistCards(lists){return `<div class="playlist-grid">${lists.map(p=>`<button class="playlist-card" data-page="playlist" data-id="${esc(p.id)}"><img src="${art(p.tracks[0])}" alt="" loading="lazy"><strong>${esc(p.name)}</strong><small>${p.pinned?'Pinned · ':''}${p.tracks.length} songs</small></button>`).join('')}</div>`;}
function renderSidebar(){
  $('#sidebar-playlists').innerHTML=profile.playlists.length?visiblePlaylists().map(p=>`<button class="sidebar-playlist" data-page="playlist" data-id="${esc(p.id)}"><img src="${art(p.tracks[0])}" alt=""><span><strong>${esc(p.name)}</strong><small>${p.pinned?'Pinned · ':''}${p.tracks.length} songs</small></span></button>`).join(''):'<p class="muted">Make room for your favourites.</p>';
  $('#offline-badge').hidden=!profile.settings.offline;
}
async function refresh({render=true}={}){
  try{const data=await api('/api/profile');profile=data;profile.settings={...defaults,...data.settings};ready=true;profileError='';renderSidebar();renderRecentSearches();if(render)renderPage();updatePlayer();}
  catch(error){profileError=error.message;if(render)renderPage();throw error;}
}
function navigate(target,id=''){
  const hash='#'+target+(id?'/'+encodeURIComponent(id):'');if(location.hash===hash)route();else location.hash=hash;
}
function route(){
  const [target,...rest]=(location.hash.slice(1)||'home').split('/');page=target;pageId=decodeURIComponent(rest.join('/'));
  if(!['home','search','library','liked','downloads','history','songs','playlist','artist','replay','settings'].includes(page))page='home';
  $('#search-page').hidden=page!=='search';$('#view').hidden=page==='search';
  document.querySelectorAll('[data-page]').forEach(el=>el.classList.toggle('active',el.dataset.page===page));
  $('#main-content').scrollTop=0;renderPage();document.title=`Rhythm — ${page==='home'?'Your music':page==='replay'?'Your Replay':page[0].toUpperCase()+page.slice(1)}`;
  if(ready&&page!=='search'){flushListening();listeningWrites.then(()=>refresh({render:true})).catch(()=>{});if(page==='downloads')pollJobs();}
}
function currentCollection(){
  switch(page){case 'search':return searchTracks;case 'liked':return profile.liked;case 'history':return profile.recent;case 'downloads':return profile.downloads.map(r=>r.track);case 'songs':return profile.songs;case 'playlist':return profile.playlists.find(p=>p.id===pageId)?.tracks||[];case 'artist':return [...new Map(allTracks().filter(t=>t.artistName===pageId).map(t=>[t.trackId,t])).values()];case 'replay':return Rhythm.replay(profile.listening,replayYear).songs.map(s=>s.track);default:return profile.recent;}
}
function renderPage(){
  if(page==='search')return;
  if(!ready){$('#view').innerHTML=title('Welcome to Rhythm')+empty(profileError||'Opening your library…')+(profileError?`<div class="actions">${button('Retry','refresh')}</div>`:'');return;}
  const view=$('#view');
  if(page==='home'){
    const name=profile.settings.displayName==='Your music'?'you':profile.settings.displayName;
    view.innerHTML=`<div class="hero"><div><p class="eyebrow">YOUR MUSIC. YOUR SPACE.</p><h1>Find your rhythm.</h1><p class="subtitle">A little louder. A little more you.<br>Your favourites and your next discovery, together.</p><div class="actions">${button(`${icon('search')} Explore music`,'explore','',false)}${button('Import your music','import-audio')}</div></div><img class="hero-logo" src="${logo}" alt="Rhythm"></div>
      <div class="shortcut-grid"><button class="shortcut" data-page="liked">${icon('heart')}<strong>Liked Songs</strong><small>${profile.liked.length} saved favourites</small></button><button class="shortcut" data-page="replay">${icon('spark')}<strong>Rhythm Replay</strong><small>Your year, in music</small></button><button class="shortcut" data-page="downloads">${icon('download')}<strong>Downloads</strong><small>${profile.downloads.length} songs on this computer</small></button></div>
      ${profile.recent.length?`<div class="section-head"><h2>Jump back in</h2><button class="text-button" data-page="history">See all</button></div>${rows(profile.recent.slice(0,5))}`:''}
      <div class="section-head"><h2>Made for ${esc(name)}</h2><button class="text-button" data-page="library">Your library ${icon('chevron-right')}</button></div>${profile.playlists.length?playlistCards(visiblePlaylists().slice(0,5)):empty('Every great collection starts with one song. Search for a favourite, or import your own audio.')}
      <h2>A sound for every mood</h2><div class="chips">${['Pop','Hip hop','Rock','Jazz','Classical','Bollywood','Indie','Electronic','Focus','Workout'].map(g=>`<button class="chip" data-action="genre" data-query="${g} music">${g}</button>`).join('')}</div>`;
  }else if(page==='library'){
    view.innerHTML=`${title('Your Library','Everything you have made yours.')}<div class="actions">${button(`${icon('plus')} New playlist`,'new-playlist','',false)}${button('Merge playlists','merge-playlists',profile.playlists.length<2?'disabled':'')}${button('Liked Songs','go-liked')}${button('Downloads','go-downloads')}${button('Rhythm Replay','go-replay')}${button('Songs For You','go-songs')}${button('Import audio','import-audio')}</div><div class="filterbar"><input id="library-filter" type="search" value="${esc(libraryFilter)}" placeholder="Find a playlist" aria-label="Find a playlist"><select id="library-sort" aria-label="Sort playlists">${[['recent','Recently created'],['name','Name'],['size','Song count']].map(([v,l])=>`<option value="${v}"${v===librarySort?' selected':''}>${l}</option>`).join('')}</select></div><div id="library-cards">${visiblePlaylists().length?playlistCards(visiblePlaylists()):empty('No playlists here yet. Create one to start collecting songs.')}</div>`;
  }else if(page==='playlist'){
    const p=profile.playlists.find(p=>p.id===pageId);if(!p){view.innerHTML=empty('This playlist is no longer available.');return;}
    view.innerHTML=`<div class="playlist-hero"><img src="${art(p.tracks[0])}" alt=""><div><p class="eyebrow">${p.pinned?'PINNED PLAYLIST':'YOUR PLAYLIST'}</p><h1>${esc(p.name)}</h1><p class="subtitle">${p.tracks.length} songs · ${formatTime(p.tracks.reduce((n,t)=>n+t.trackTimeMillis/1000,0))}</p></div></div>${p.description?`<p class="subtitle">${esc(p.description)}</p>`:''}<div class="actions">${button(`${icon('play')} Play`,'play-all',p.tracks.length?'':'disabled',false)}${button('Edit','edit-playlist')}${button(p.pinned?'Unpin':'Pin','pin')}${button('Duplicate','duplicate')}${button('Merge playlists','merge-playlists',profile.playlists.length<2?'disabled':'')}${button('Download all','download-all',p.tracks.length?'':'disabled')}${button('Delete','delete-playlist')}</div>${p.tracks.length?rows(p.tracks,{playlistId:p.id}):empty('Add songs from search results or your liked songs.')}`;
  }else if(page==='settings')renderSettings();
  else if(page==='replay')renderReplay();
  else{
    const tracks=currentCollection(),labels={liked:['Liked Songs','The songs you keep coming back to.'],history:['Recently played','Your listening, remembered.'],downloads:['Downloads & local files','Saved on the computer running Rhythm.'],songs:['Songs For You','Ranked by full listens in this library.'],artist:[pageId,'Songs you have discovered or saved.']};
    const [heading,sub]=labels[page]||['Your music',''];
    view.innerHTML=title(heading,sub)+`<div class="actions">${button(`${icon('play')} Play`,'play-all',tracks.length?'':'disabled',false)}${page==='liked'?button('Make a playlist','save-collection',tracks.length?'':'disabled'):''}${page==='downloads'?button('Import audio','import-audio')+`<span class="muted">${(profile.downloads.reduce((n,r)=>n+r.bytes,0)/1048576).toFixed(1)} MB</span>`:''}${page==='artist'?button('Find more songs','artist-search'):''}</div>${page==='downloads'?'<div id="download-jobs"></div>':''}${tracks.length?rows(tracks):empty(page==='history'?'Start listening and your history will appear here.':page==='downloads'?'Save a song for later, or import an audio file.':page==='songs'?'Songs you listen to at least 85% of will appear here.':'Find a song you love and save it here.')}`;
    if(page==='downloads')renderJobs();
  }
}
function renderSettings(){
  const s=profile.settings;
  const toggle=(key,label,description)=>`<label class="setting"><span><strong>${label}</strong><small>${description}</small></span><input type="checkbox" data-setting="${key}" ${s[key]?'checked':''}></label>`;
  const select=(key,label,options,description='')=>`<label class="setting"><span><strong>${label}</strong>${description?`<small>${description}</small>`:''}</span><select data-setting="${key}">${options.map(([v,l])=>`<option value="${v}"${String(s[key])===String(v)?' selected':''}>${l}</option>`).join('')}</select></label>`;
  $('#view').innerHTML=`<div class="settings">${title('Settings','Make listening feel right for you.')}<div class="setting"><span><strong>${esc(s.displayName)}</strong><small>Your local Rhythm profile</small></span>${button('Edit name','profile-name')}</div><h2>Playback</h2>${toggle('autoplay','Autoplay','Continue with songs from your listening history when the queue ends.')}${toggle('offline','Downloaded-only mode','Search your library and play saved audio. The Python app must still be running.')}${select('speed','Playback speed',[.5,.75,1,1.25,1.5,1.75,2].map(v=>[v,`${v}×`]))}<label class="setting"><span><strong>Volume</strong></span><input type="range" min="0" max="1" step=".01" value="${s.volume}" data-setting="volume" aria-label="Settings volume"></label>${select('equalizer','Equalizer',[['flat','Flat'],['bass','Bass boost'],['vocal','Vocals'],['treble','Treble']],'Processed in your browser. Some mobile browsers limit audio effects.')}<div class="setting"><span><strong>Sleep timer</strong><small id="settings-sleep">${sleepLabel()}</small></span>${button('Set timer','sleep')}</div><h2>Audio quality</h2>${select('streamingQuality','Streaming quality',[['dataSaver','Data saver'],['balanced','Balanced'],['high','High']])}${select('downloadQuality','Download quality',[['dataSaver','Data saver'],['balanced','Balanced'],['high','High']])}<p class="muted">Applies to new streams and downloads. Available quality depends on the source.</p><h2>Privacy & your library</h2>${toggle('privateSession','Private session','Exclude new listening and searches from history and Rhythm Replay.')}<div class="actions"><a class="pill ghost" href="/api/library/export" download>Export library</a>${button('Import library','import-library')}${button('Clear listening history','clear-history')}</div><p class="muted">Library backups contain playlists and likes, not audio files. Importing merges collections. Local files need to be imported separately.</p><h2>About Rhythm</h2><img class="about-logo" src="/assets/rhythm-original.png" alt="Rhythm"><p class="muted">Your music, your space. Independent music discovery through YouTube, with a Python backend and a library saved on this computer.</p></div>`;
}
function renderReplay(){
  const summary=Rhythm.replay(profile.listening,replayYear),years=[...new Set([new Date().getFullYear(),...profile.listening.map(e=>Number(e.day.slice(0,4)))])].sort((a,b)=>b-a);
  $('#view').innerHTML=`<div class="section-head"><h1>Rhythm Replay</h1><select id="replay-year" aria-label="Replay year">${years.map(y=>`<option${y===replayYear?' selected':''}>${y}</option>`).join('')}</select></div>`+(summary.uniqueSongs?`<div class="replay-hero"><p class="eyebrow">${replayYear} WAS YOUR YEAR</p><div class="replay-minutes">${summary.minutes.toLocaleString()}</div><h2>minutes of music</h2><div class="stats">${[[summary.plays,'plays'],[summary.uniqueSongs,'songs'],[summary.uniqueArtists,'artists'],[summary.days,'listening days']].map(([n,l])=>`<span><strong>${n}</strong>${l}</span>`).join('')}</div></div><h2>Your top artists</h2>${summary.artists.slice(0,5).map(([name,ms],i)=>`<button class="rank-row" style="width:100%;text-align:left" data-page="artist" data-id="${esc(name)}"><span class="rank">${i+1}</span><strong>${esc(name)}</strong><small>${Math.floor(ms/60000)} minutes</small></button>`).join('')}<h2>Your top songs</h2>${rows(summary.songs.slice(0,5).map(s=>s.track))}<h2>Your listening through the year</h2><div class="chart">${summary.months.map((n,i)=>`<div title="${i+1}: ${n} minutes"><i style="height:${Math.max(2,n/Math.max(1,...summary.months)*110)}px"></i>${'JFMAMJJASOND'[i]}</div>`).join('')}</div><div class="actions">${button('Save top songs playlist','replay-save','',false)}${button(`${icon('share')} Share Replay`,'replay-share')}</div><p class="muted">Based only on listening recorded in this Rhythm library. Seeking, pauses, buffering and private sessions do not add listening time.</p>`:empty('Your story starts with a song. Listen to music in Rhythm to build your Replay.'));
}
function renderRecentSearches(){$('#recent-searches').innerHTML=profile.searches.map(q=>`<button class="chip" data-action="genre" data-query="${esc(q)}">${esc(q)}</button>`).join('');}
function renderResults(tracks=[]){
  searchTracks=[...new Map(tracks.map(t=>[t.trackId||t.previewUrl,t])).values()];
  results.innerHTML=searchTracks.length?`<div class="section-head"><h2>Songs</h2>${button('Save these results','save-search')}</div>${rows(searchTracks)}`:'';
}
function createLoadMoreButton(){if(loadMoreButton)loadMoreButton.remove();loadMoreButton=document.createElement('button');loadMoreButton.className='pill ghost';loadMoreButton.type='button';loadMoreButton.textContent='Load more';loadMoreButton.addEventListener('click',loadMoreResults);return loadMoreButton;}
function removeLoadMoreButton(){if(loadMoreButton){loadMoreButton.remove();loadMoreButton=null;}}
function searchFor(term){navigate('search');searchInput.value=term;searchInput.dispatchEvent(new Event('input'));}
$('#search-form').addEventListener('submit',event=>{event.preventDefault();searchInput.dispatchEvent(new Event('input'));});
let searchDebounceTimer = null;
let searchController = null;
const SEARCH_TIMEOUT_MS = 20000;

async function fetchSearchPage(query, page, thisRequest) {
  const controller = new AbortController();
  searchController = controller;
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, SEARCH_TIMEOUT_MS);
  try {
    const response = await fetch('/api/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, page }),
      signal: controller.signal
    });
    const data = await response.json();
    if (thisRequest !== requestId) return null;
    if (!response.ok) throw new Error(data.error || 'Search failed');
    return data;
  } catch (err) {
    if (thisRequest !== requestId) return null;
    if (timedOut) throw new Error('Search took too long. Please try again.');
    throw err;
  } finally {
    clearTimeout(timeout);
    if (searchController === controller) searchController = null;
  }
}

searchInput.addEventListener('input', () => {
  const term = searchInput.value.trim();
  clearTimeout(searchDebounceTimer);
  // Invalidate immediately, including when the input is cleared or debouncing.
  const thisRequest = ++requestId;
  if (searchController) searchController.abort();
  searchQuery = term;
  searchPageNumber = 0;
  searchTracks = [];
  results.replaceChildren();
  removeLoadMoreButton();
  searchStatus.textContent = term ? 'Searching…' : '';
  results.setAttribute('aria-busy', String(Boolean(term)));
  if (!term) return;

  searchDebounceTimer = setTimeout(async () => {
    try {
      const data = await fetchSearchPage(term, 0, thisRequest);
      if (!data) return;
      const tracks = (data.tracks || []).filter(track => track.previewUrl);
      searchStatus.textContent = tracks.length ? '' : 'No playable results found. Try another search.';
      renderResults(tracks);
      if (data.hasMore) results.append(createLoadMoreButton());
    } catch (err) {
      if (thisRequest === requestId) {
        searchStatus.textContent = err.message || 'Search is unavailable right now.';
      }
    } finally {
      if (thisRequest === requestId) results.setAttribute('aria-busy', 'false');
    }
  }, 300);
});

/* ---------------------------------------------------------- load more */
async function loadMoreResults() {
  if (!searchQuery || !loadMoreButton || loadMoreButton.disabled) return;
  const nextPage = searchPageNumber + 1;
  const thisRequest = ++requestId;
  const btn = loadMoreButton;
  btn.disabled = true;
  btn.textContent = 'Loading…';
  results.setAttribute('aria-busy', 'true');
  try {
    const data = await fetchSearchPage(searchQuery, nextPage, thisRequest);
    if (!data) return;
    const tracks = (data.tracks || []).filter(track => track.previewUrl);
    // Commit pagination only after success so a failed page can be retried.
    searchPageNumber = nextPage;
    searchStatus.textContent = '';
    renderResults(searchTracks.concat(tracks));
    if (data.hasMore && tracks.length) results.append(btn);
    else removeLoadMoreButton();
  } catch (err) {
    if (thisRequest === requestId) {
      searchStatus.textContent = err.message || 'Could not load more results.';
    }
  } finally {
    if (thisRequest === requestId) {
      btn.disabled = false;
      btn.textContent = 'Load More';
      results.setAttribute('aria-busy', 'false');
    }
  }
}

/* --------------------------------------------------------- player controls */
function persistOutbox(){try{localStorage.setItem('rhythm-listening-outbox',JSON.stringify(listeningOutbox));}catch{}}
function flushListening(){
  const event=listening.take();if(event&&currentTrack){listeningOutbox.push({...event,track:currentTrack,day:listeningDay,eventId:crypto.randomUUID()});persistOutbox();}
  listeningWrites=listeningWrites.then(async()=>{
    while(listeningOutbox.length){const item=listeningOutbox[0];try{await api('/api/listening',{method:'POST',body:item,keepalive:true});}catch{break;}listeningOutbox.shift();persistOutbox();}
  });return listeningWrites;
}
function sample(){
  if(listeningDay!==localDay()){flushListening();listeningDay=localDay();}
  listening.sample(audio.currentTime,{playing:!audio.paused&&!audio.seeking,speed:audio.playbackRate,duration:audio.duration,privateSession:profile.settings.privateSession,buffering});
  if(listening.amount>=15000)flushListening();
}
function setAudioEffects(){
  if(!audioContext)return;
  const gains={flat:[0,0,0],bass:[5,0,-1],vocal:[-1,3,-1],treble:[0,0,4]}[profile.settings.equalizer]||[0,0,0];
  filters.forEach((filter,i)=>filter.gain.setTargetAtTime(gains[i],audioContext.currentTime,.05));
}
function enableAudioEffects(){
  if(profile.settings.equalizer==='flat'&&!audioContext)return;
  const AudioContext=window.AudioContext||window.webkitAudioContext;
  if(!AudioContext){toast('Audio effects are not supported by this browser.');return;}
  try{
    if(!audioContext){audioContext=new AudioContext();const source=audioContext.createMediaElementSource(audio);filters=[80,1400,6000].map((hz,i)=>{const f=audioContext.createBiquadFilter();f.type=i===0?'lowshelf':i===2?'highshelf':'peaking';f.frequency.value=hz;f.Q.value=.7;return f;});source.connect(filters[0]);filters[0].connect(filters[1]);filters[1].connect(filters[2]);filters[2].connect(audioContext.destination);}
    audioContext.resume().catch(()=>toast('Tap play to enable audio effects.'));setAudioEffects();
  }catch{toast('This browser could not enable the equalizer.');}
}
function startTrack(track){
  flushListening();const token=++playToken;audio.pause();currentTrack=track;listening.reset();listeningDay=localDay();playbackError=false;buffering=true;
  clearTimeout(loadTimer);loadTimer=setTimeout(()=>{if(token===playToken&&buffering){pause();playbackError=true;toast('Audio loading took too long. Try again.');}},30000);
  audio.src=`/api/stream/${encodeURIComponent(track.trackId)}`;audio.playbackRate=profile.settings.speed;audio.volume=profile.settings.volume;enableAudioEffects();updatePlayer();
  audio.play().then(()=>{if(token===playToken){buffering=false;updatePlayer();}}).catch(error=>{if(token===playToken&&error.name!=='AbortError'){buffering=false;playbackError=true;toast('This song could not be played. It may be unavailable or require a download in downloaded-only mode.');updatePlayer();}});
  updateMediaSession();if(dialogMode?.type==='queue')renderQueue();
}
function playTracks(tracks,index){
  if(!tracks[index])return;
  if(currentTrack?.trackId===tracks[index].trackId&&queue.tracks.length===tracks.length&&queue.tracks.every((t,i)=>t.trackId===tracks[i].trackId)){togglePlay();return;}
  queue.set(tracks,index);startTrack(queue.tracks[queue.index]);
}
function pause(){++playToken;clearTimeout(loadTimer);audio.pause();buffering=false;flushListening();updatePlayer();}
function togglePlay(){
  if(!currentTrack)return;if(!audio.paused||buffering){pause();return;}
  if(audio.ended||playbackError){startTrack(currentTrack);return;}
  const token=++playToken;enableAudioEffects();audio.play().catch(error=>{if(token===playToken&&error.name!=='AbortError'){toast('Playback could not start. Try another song.');updatePlayer();}});
}
async function next(automatic=false){
  if(!queue.items.length)return;
  if(automatic&&sleepAfterTrack){sleepAfterTrack=false;pause();return;}
  if(automatic&&queue.repeat==='one'){startTrack(currentTrack);return;}
  const token=playToken;let index=queue.index+1;
  if(automatic&&index>=queue.items.length&&queue.repeat!=='all'&&profile.settings.autoplay){
    try{const exclude=queue.tracks.map(t=>'exclude='+encodeURIComponent(t.trackId)).join('&');const data=await api('/api/liked-songs/recommend?'+exclude);if(token!==playToken)return;data.songs.forEach(t=>{if(!queue.tracks.some(q=>q.trackId===t.trackId))queue.add(t);});}catch{}
  }
  if(token!==playToken)return;
  if(index>=queue.items.length){if(automatic&&queue.repeat==='off'){pause();return;}index=0;}
  queue.index=index;startTrack(queue.tracks[index]);
}
function previous(){if(!queue.items.length)return;if(audio.currentTime>3){seekTo(0);return;}queue.index=(queue.index-1+queue.items.length)%queue.items.length;startTrack(queue.tracks[queue.index]);}
function seekTo(value){if(!Number.isFinite(audio.duration))return;const target=Math.max(0,Math.min(audio.duration,value));listening.seek(target);audio.currentTime=target;updateProgress();}
function toggleRepeat(){queue.repeat={off:'all',all:'one',one:'off'}[queue.repeat];updatePlayer();}
function toggleShuffle(){queue.toggleShuffle();updatePlayer();if(dialogMode?.type==='queue')renderQueue();}
function updatePlayer({rebuildDialog=true}={}){
  $('#play-toggle').disabled=!currentTrack;$('#previous').disabled=$('#next').disabled=!queue.items.length;
  $('#play-toggle').innerHTML=icon(audio.paused?'play':'pause');$('#play-toggle').setAttribute('aria-label',audio.paused?'Play':'Pause');$('#play-toggle').classList.toggle('busy',buffering);
  $('#now-title').textContent=currentTrack?.trackName||'Choose a song';$('#now-artist').textContent=currentTrack?.artistName||'Find your rhythm';$('#now-art').src=currentTrack?.artworkUrl100||logo;
  $('#now-like').disabled=!currentTrack;$('#now-like').classList.toggle('liked',Boolean(currentTrack&&isLiked(currentTrack)));$('#now-like').setAttribute('aria-label',currentTrack&&isLiked(currentTrack)?'Unlike song':'Like song');
  $('#repeat').setAttribute('aria-pressed',String(queue.repeat!=='off'));$('#repeat').setAttribute('aria-label',`Repeat ${queue.repeat}`);$('#repeat-one').hidden=queue.repeat!=='one';
  $('#shuffle').setAttribute('aria-pressed',String(queue.shuffle));$('#shuffle').setAttribute('aria-label',`Shuffle ${queue.shuffle?'on':'off'}`);
  $('#volume').value=profile.settings.volume;$('#mute').innerHTML=icon(profile.settings.volume===0?'volume-muted':'volume');$('#mute').setAttribute('aria-label',profile.settings.volume===0?'Unmute':'Mute');
  $('#sleep').setAttribute('aria-pressed',String(Boolean(sleepUntil||sleepAfterTrack)));
  document.querySelectorAll('.result-row').forEach(row=>{const current=row.dataset.track===currentTrack?.trackId;row.classList.toggle('current',current);const play=row.querySelector('.track-play');if(play){play.innerHTML=icon(current&&!audio.paused?'pause':'play');play.setAttribute('aria-label',`${current&&!audio.paused?'Pause':'Play'} ${row.querySelector('.track-title').textContent}`);}});
  if(rebuildDialog&&dialogMode?.type==='now')renderNowPlaying();
  if('mediaSession' in navigator)navigator.mediaSession.playbackState=audio.paused?'paused':'playing';updateProgress();
}
function updateProgress(){
  const duration=Number.isFinite(audio.duration)?audio.duration:0;
  $('#elapsed').textContent=formatTime(audio.currentTime);$('#duration').textContent=formatTime(duration);$('#seek').max=duration||1;$('#seek').value=audio.currentTime||0;$('#seek').disabled=!duration;
  if(dialogMode?.type==='now'){const seek=$('#full-seek');if(seek){seek.max=duration||1;seek.value=audio.currentTime||0;seek.disabled=!duration;$('#full-elapsed').textContent=formatTime(audio.currentTime);$('#full-duration').textContent=formatTime(duration);}}
  if(duration&&'mediaSession' in navigator&&navigator.mediaSession.setPositionState)try{navigator.mediaSession.setPositionState({duration,position:Math.min(duration,audio.currentTime),playbackRate:audio.playbackRate});}catch{}
}
function updateMediaSession(){
  if(!('mediaSession' in navigator)||!currentTrack)return;
  if('MediaMetadata' in window)navigator.mediaSession.metadata=new MediaMetadata({title:currentTrack.trackName,artist:currentTrack.artistName,album:'Rhythm',artwork:[{src:new URL(currentTrack.artworkUrl100||logo,location.origin).href}]});
}
async function changeSettings(patch){
  await flushListening();const previous={...profile.settings};const version=++settingsVersion;Object.assign(profile.settings,patch);
  if(patch.offline!==undefined){searchInput.value='';searchInput.dispatchEvent(new Event('input'));}
  audio.volume=profile.settings.volume;audio.playbackRate=profile.settings.speed;
  if(patch.equalizer!==undefined)enableAudioEffects();renderSidebar();updatePlayer();
  settingsWrites=settingsWrites.then(async()=>{try{const data=await api('/api/settings',{method:'PATCH',body:patch});if(version===settingsVersion)profile.settings=data.settings;}
    catch(error){if(version===settingsVersion){profile.settings=previous;audio.volume=previous.volume;audio.playbackRate=previous.speed;setAudioEffects();updatePlayer();renderPage();}toast(error.message);}});
  return settingsWrites;
}
function setVolume(value){value=Number(value);if(value>0)previousVolume=value;audio.volume=value;profile.settings.volume=value;updatePlayer({rebuildDialog:false});clearTimeout(volumeTimer);volumeTimer=setTimeout(()=>changeSettings({volume:value}),350);}
function mute(){setVolume(profile.settings.volume===0?previousVolume:0);}
function sleepLabel(){return sleepAfterTrack?'At the end of this song':sleepUntil?`Ends at ${new Date(sleepUntil).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}`:'Off';}
function setSleep(value){clearTimeout(sleepTimer);sleepUntil=null;sleepAfterTrack=value==='track';if(Number(value)>0){sleepUntil=Date.now()+Number(value)*60000;sleepTimer=setTimeout(()=>{sleepUntil=null;pause();toast('Sleep timer finished.');},Number(value)*60000);}updatePlayer();if(page==='settings')renderSettings();}
function openDialog(name,html,mode){$('#dialog-title').textContent=name;$('#dialog-content').innerHTML=html;dialogMode=mode;if(!modal.open)modal.showModal();}
function closeDialog(){modal.close();dialogMode=null;editor=null;}
function newPlaylist(track=null,collection=null,name=''){
  editor={type:'new',tracks:collection|| (track?[track]:[])};
  openDialog('New playlist',`<label>Playlist name<input id="playlist-name-input" maxlength="80" value="${esc(name)}" placeholder="My playlist" autofocus></label><div class="actions">${button('Cancel','close')}${button('Create','playlist-save','',false)}</div>`,{type:'editor'});$('#playlist-name-input').focus();
}
function mergePicker(){
  openDialog('Merge playlists',`<p class="muted">Create a new playlist from two or more collections. Songs follow the order shown below, with duplicates removed. Original playlists are kept.</p><label>New playlist name<input id="merge-name" maxlength="80" value="Merged playlist"></label><div>${profile.playlists.map(p=>`<label class="setting"><span>${esc(p.name)} · ${p.tracks.length} songs</span><input type="checkbox" name="merge-source" value="${esc(p.id)}"${p.id===pageId?' checked':''}></label>`).join('')}</div><div class="actions">${button('Cancel','close')}${button('Create merged playlist','merge-save','',false)}</div>`,{type:'merge'});
}
async function saveMerge(){
  const name=$('#merge-name').value.trim();
  const playlistIds=[...modal.querySelectorAll('input[name="merge-source"]:checked')].map(input=>input.value);
  if(!name||playlistIds.length<2){toast('Enter a name and choose at least two playlists.');return;}
  const result=await api('/api/playlists/merge',{method:'POST',body:{name,playlistIds}});
  closeDialog();await refresh({render:false});navigate('playlist',result.playlist.id);toast('Playlists merged.');
}
function editPlaylist(){const p=profile.playlists.find(p=>p.id===pageId);if(!p)return;editor={type:'edit',id:p.id,name:p.name,description:p.description,tracks:[...p.tracks]};renderEditor();}
function renderEditor(){
  openDialog('Edit playlist',`<label>Playlist name<input id="playlist-name-input" maxlength="80" value="${esc(editor.name)}"></label><label>Description<textarea id="playlist-description" maxlength="500">${esc(editor.description)}</textarea></label><div class="section-head"><p class="muted">Drag songs, or use the arrows.</p><select id="editor-sort" aria-label="Sort playlist songs"><option value="">Sort songs</option><option value="title">Song title</option><option value="artist">Artist</option></select></div><div>${editor.tracks.map((t,i)=>`<div class="edit-row" draggable="true" data-edit-index="${i}"><img src="${art(t)}" alt=""><span class="result-info"><strong class="track-title">${esc(t.trackName)}</strong><span class="track-artist">${esc(t.artistName)}</span></span><button class="icon-button" data-action="edit-up" data-index="${i}" aria-label="Move ${esc(t.trackName)} up" ${i===0?'disabled':''}>↑</button><button class="icon-button" data-action="edit-down" data-index="${i}" aria-label="Move ${esc(t.trackName)} down" ${i===editor.tracks.length-1?'disabled':''}>↓</button><button class="icon-button" data-action="edit-remove" data-index="${i}" aria-label="Remove ${esc(t.trackName)}">${icon('close')}</button></div>`).join('')}</div><div class="actions">${button('Cancel','close')}${button('Save','playlist-save','',false)}</div>`,{type:'editor'});
}
function captureEditor(){if(editor?.type==='edit'){editor.name=$('#playlist-name-input').value;editor.description=$('#playlist-description').value;}}
async function savePlaylist(){
  if(!editor)return;const name=$('#playlist-name-input').value.trim();if(!name){$('#playlist-name-input').focus();return;}
  const data={name,tracks:editor.tracks,description:$('#playlist-description')?.value||''};
  const result=await api(editor.type==='new'?'/api/playlists':`/api/playlists/${editor.id}`,{method:editor.type==='new'?'POST':'PATCH',body:data});closeDialog();await refresh({render:false});navigate('playlist',result.playlist.id);toast('Playlist saved.');
}
function confirmAction(name,text,action,id=''){openDialog(name,`<p class="subtitle">${esc(text)}</p><div class="actions">${button('Cancel','close')}${button('Confirm',action,`data-id="${esc(id)}"`,false)}</div>`,{type:'confirm'});}
function songMenu(track,pid=''){
  if(!track)return;
  const item=(text,action,symbol,extra='')=>`<button class="menu-item" data-action="${action}" data-id="${esc(track.trackId)}" ${extra}>${icon(symbol)}${text}</button>`;
  openDialog(track.trackName,item(isLiked(track)?'Remove from Liked Songs':'Save to Liked Songs','like','heart')+item('Play next','queue-next','next')+item('Add to queue','queue-add','queue')+item('Add to playlist','add-picker','plus')+(pid?item('Remove from playlist','remove-track','close',`data-playlist="${esc(pid)}"`):'')+(isSaved(track)?`<a class="menu-item" href="/api/download/${esc(track.trackId)}?name=${encodeURIComponent(track.trackName)}" download>${icon('share')}Export audio file</a>`+item('Remove downloaded file','remove-download','download'):item('Download','download','download'))+item('View artist','artist','note')+(!track.trackId.startsWith('local_')?item('Share song','share','share'):''),{type:'song',track,pid});
}
function addPicker(track){openDialog('Add to playlist',profile.playlists.map(p=>`<button class="menu-item" data-action="add-to-playlist" data-id="${esc(track.trackId)}" data-playlist="${esc(p.id)}">${icon('library')}${esc(p.name)}${p.tracks.some(t=>t.trackId===track.trackId)?' ✓':''}</button>`).join('')+`<button class="menu-item" data-action="new-with-track" data-id="${esc(track.trackId)}">${icon('plus')}New playlist</button>`,{type:'picker'});}
function renderQueue(){
  openDialog('Play queue',`<div class="section-head"><span class="muted">${queue.items.length} songs · drag to reorder</span>${button('Clear upcoming','queue-clear')}</div>${queue.items.length?queue.items.map((item,i)=>`<div class="queue-row${i===queue.index?' current':''}" draggable="true" data-queue-index="${i}"><img src="${art(item.track)}" alt=""><div class="result-info"><button class="track-title" data-action="queue-play" data-index="${i}">${esc(item.track.trackName)}</button><span class="track-artist">${i===queue.index?'Now playing':esc(item.track.artistName)}</span></div><button class="icon-button" data-action="queue-up" data-index="${i}" aria-label="Move ${esc(item.track.trackName)} up" ${i===0?'disabled':''}>↑</button><button class="icon-button" data-action="queue-down" data-index="${i}" aria-label="Move ${esc(item.track.trackName)} down" ${i===queue.items.length-1?'disabled':''}>↓</button><button class="icon-button" data-action="queue-remove" data-index="${i}" aria-label="Remove ${esc(item.track.trackName)} from queue" ${i===queue.index?'disabled':''}>${icon('close')}</button></div>`).join(''):empty('Add songs from their options menu to build a queue.')}`,{type:'queue'});
}
function renderNowPlaying(){
  const track=currentTrack;
  openDialog('Now playing',`<img class="full-art" src="${art(track)}" alt=""><h2 class="full-title">${esc(track?.trackName||'Choose a song')}</h2><button class="full-artist" data-action="artist" data-id="${esc(track?.trackId||'')}">${esc(track?.artistName||'Find your rhythm')}</button><div class="full-controls"><div class="timeline"><span id="full-elapsed">${formatTime(audio.currentTime)}</span><input id="full-seek" type="range" min="0" max="${Number.isFinite(audio.duration)?audio.duration:1}" value="${audio.currentTime||0}" step=".1" aria-label="Full player playback position"><span id="full-duration">${formatTime(audio.duration)}</span></div><div class="control-row"><button class="control" data-action="shuffle" aria-label="Shuffle" aria-pressed="${queue.shuffle}">${icon('shuffle')}</button><button class="control" data-action="previous" aria-label="Previous song">${icon('prev')}</button><button class="control play${buffering?' busy':''}" data-action="toggle-play" aria-label="${audio.paused?'Play':'Pause'}" ${track?'':'disabled'}>${icon(audio.paused?'play':'pause')}</button><button class="control" data-action="next" aria-label="Next song">${icon('next')}</button><button class="control" data-action="repeat" aria-label="Repeat ${queue.repeat}" aria-pressed="${queue.repeat!=='off'}">${icon('repeat')}${queue.repeat==='one'?'1':''}</button></div></div><div class="actions">${button(`${icon('heart')} ${track&&isLiked(track)?'Liked':'Like'}`,'like',`data-id="${esc(track?.trackId||'')}" ${track?'':'disabled'}`)}${button('Queue','queue')}${button('Sleep timer','sleep')}</div><label class="setting"><span>Volume</span><input type="range" data-player-volume min="0" max="1" step=".01" value="${profile.settings.volume}" aria-label="Full player volume"></label>`,{type:'now'});
}
function sleepDialog(){openDialog('Sleep timer',`<p class="muted">${sleepLabel()}</p>`+[5,15,30,45,60].map(n=>`<button class="menu-item" data-action="set-sleep" data-value="${n}">${n} minutes</button>`).join('')+`<button class="menu-item" data-action="set-sleep" data-value="track" ${currentTrack?'':'disabled'}>End of this song</button><button class="menu-item" data-action="set-sleep" data-value="off">Turn off timer</button>`,{type:'sleep'});}
async function toggleLike(track){if(!track)return;await api('/api/likes',{method:'POST',body:{track,liked:!isLiked(track)}});await refresh();if(dialogMode?.type==='song')songMenu(track,dialogMode.pid);}
async function share(text){if(navigator.share){try{await navigator.share({title:'Rhythm',text});return;}catch(e){if(e.name==='AbortError')return;}}if(navigator.clipboard){await navigator.clipboard.writeText(text);toast('Copied to clipboard.');}else{openDialog('Share',`<textarea readonly aria-label="Share text">${esc(text)}</textarea>`,{type:'share'});}}
async function download(track){if(!track)return;await api('/api/downloads',{method:'POST',body:{track}});await refresh();toast(`Saving “${track.trackName}”…`);closeDialog();await pollJobs();}
function renderJobs(){const container=$('#download-jobs');if(!container)return;container.innerHTML=jobs.filter(j=>j.status!=='complete').map(j=>`<div class="download-job"><strong>${esc(j.track.trackName)}</strong><span>${esc(j.status==='failed'?j.error:j.status)}</span></div>`).join('');}
async function pollJobs(){
  clearTimeout(pollTimer);
  try{const old=jobs;({jobs}=await api('/api/downloads/jobs'));if(jobs.some(j=>j.status==='complete'&&!old.some(o=>o.id===j.id&&o.status==='complete')))await refresh();renderJobs();}
  catch(error){toast(error.message);pollTimer=setTimeout(pollJobs,8000);return;}
  if(jobs.some(j=>['queued','downloading'].includes(j.status)))pollTimer=setTimeout(pollJobs,2500);
}
async function action(name,element){
  const id=element.dataset.id,track=trackById(id),index=Number(element.dataset.index),p=profile.playlists.find(p=>p.id===pageId);
  switch(name){
    case 'refresh':await refresh();break;
    case 'explore':navigate('search');searchInput.focus();break;
    case 'genre':searchFor(element.dataset.query);break;
    case 'artist-search':searchFor(pageId);break;
    case 'go-liked':navigate('liked');break;
    case 'go-downloads':navigate('downloads');break;
    case 'go-replay':navigate('replay');break;
    case 'go-songs':navigate('songs');break;
    case 'play-row':{const collection=currentCollection();const found=collection.findIndex(t=>t.trackId===id);if(currentTrack?.trackId===id&&!audio.paused)pause();else if(found>=0)playTracks(collection,found);break;}
    case 'play-all':playTracks(currentCollection(),0);break;
    case 'new-playlist':newPlaylist();break;
    case 'new-with-track':newPlaylist(track);break;
    case 'save-search':newPlaylist(null,searchTracks,searchQuery);break;
    case 'save-collection':newPlaylist(null,currentCollection(),'My liked songs');break;
    case 'merge-playlists':mergePicker();break;
    case 'merge-save':await saveMerge();break;
    case 'edit-playlist':editPlaylist();break;
    case 'playlist-save':await savePlaylist();break;
    case 'pin':await api('/api/playlists/'+p.id,{method:'PATCH',body:{pinned:!p.pinned}});await refresh();break;
    case 'duplicate':{const data=await api('/api/playlists',{method:'POST',body:{name:p.name+' (copy)',description:p.description,tracks:p.tracks}});await refresh({render:false});navigate('playlist',data.playlist.id);break;}
    case 'delete-playlist':confirmAction('Delete playlist?',`Delete “${p.name}”? Your audio files and liked songs will be kept.`,'confirm-delete',p.id);break;
    case 'confirm-delete':await api('/api/playlists/'+id,{method:'DELETE'});closeDialog();await refresh({render:false});navigate('library');break;
    case 'song-menu':songMenu(track,element.dataset.playlist);break;
    case 'like':await toggleLike(track);break;
    case 'artist':if(track){closeDialog();navigate('artist',track.artistName);}break;
    case 'add-picker':addPicker(track);break;
    case 'add-to-playlist':await api(`/api/playlists/${element.dataset.playlist}/tracks`,{method:'POST',body:{track}});closeDialog();await refresh();toast('Song saved to your playlist.');break;
    case 'remove-track':await api(`/api/playlists/${element.dataset.playlist}/tracks/${id}`,{method:'DELETE'});closeDialog();await refresh();break;
    case 'share':if(track)await share(`${track.trackName} — ${track.artistName}\nhttps://www.youtube.com/watch?v=${track.trackId}`);break;
    case 'download':await download(track);break;
    case 'download-all':{const tracks=p.tracks.filter(t=>!isSaved(t));let added=0;try{for(const t of tracks){await api('/api/downloads',{method:'POST',body:{track:t}});added++;}toast('Playlist added to downloads.');}catch(error){toast(`${added} songs queued. ${error.message}`);}await pollJobs();break;}
    case 'remove-download':if(track)confirmAction('Remove downloaded audio?',`Remove the saved file for “${track.trackName}”? Imported files need to be imported again to play.`,'confirm-remove-download',id);break;
    case 'confirm-remove-download':if(currentTrack?.trackId===id){pause();audio.removeAttribute('src');audio.load();playbackError=true;}await api('/api/downloads/'+id,{method:'DELETE'});closeDialog();await refresh();break;
    case 'import-audio':$('#audio-input').click();break;
    case 'import-library':$('#library-input').click();break;
    case 'queue-next':case 'queue-add':if(track){queue.add(track,name==='queue-next');closeDialog();updatePlayer();toast(name==='queue-next'?'Added to play next.':'Added to queue.');}break;
    case 'queue':renderQueue();break;
    case 'queue-play':queue.index=index;startTrack(queue.tracks[index]);renderQueue();break;
    case 'queue-remove':queue.remove(index);renderQueue();updatePlayer();break;
    case 'queue-up':queue.move(index,index-1);renderQueue();break;
    case 'queue-down':queue.move(index,index+1);renderQueue();break;
    case 'queue-clear':queue.clearUpcoming();renderQueue();break;
    case 'edit-remove':captureEditor();editor.tracks.splice(index,1);renderEditor();break;
    case 'edit-up':case 'edit-down':{captureEditor();const to=index+(name==='edit-up'?-1:1);if(to>=0&&to<editor.tracks.length)editor.tracks.splice(to,0,editor.tracks.splice(index,1)[0]);renderEditor();break;}
    case 'toggle-play':togglePlay();break;
    case 'previous':previous();break;
    case 'next':await next();break;
    case 'repeat':toggleRepeat();break;
    case 'shuffle':toggleShuffle();break;
    case 'sleep':sleepDialog();break;
    case 'set-sleep':setSleep(element.dataset.value);closeDialog();toast(`Sleep timer: ${sleepLabel()}`);break;
    case 'profile-name':openDialog('Your name',`<label>Profile name<input id="profile-name-input" maxlength="50" value="${esc(profile.settings.displayName)}" autofocus></label><div class="actions">${button('Cancel','close')}${button('Save','save-name','',false)}</div>`,{type:'name'});$('#profile-name-input').focus();break;
    case 'save-name':await changeSettings({displayName:$('#profile-name-input').value});closeDialog();renderSettings();break;
    case 'clear-history':confirmAction('Clear listening history?','This resets Replay, Songs For You, recently played and recent searches. Playlists, likes and audio files are kept.','confirm-clear');break;
    case 'confirm-clear':await flushListening();await api('/api/history',{method:'DELETE'});listening.reset();listening.seek(audio.currentTime);closeDialog();await refresh();toast('Listening history cleared.');break;
    case 'replay-save':newPlaylist(null,Rhythm.replay(profile.listening,replayYear).songs.slice(0,100).map(s=>s.track),`My ${replayYear} Replay`);break;
    case 'replay-share':{const r=Rhythm.replay(profile.listening,replayYear);await share(`${replayYear} · My Rhythm Replay\n${r.minutes} minutes · ${r.plays} plays · ${r.uniqueSongs} songs\nTop artist: ${r.artists[0]?.[0]||'—'}\nTop song: ${r.songs[0]?.track.trackName||'—'}\nBased on listening in my Rhythm library.`);break;}
    case 'close':closeDialog();break;
  }
}
document.addEventListener('click',async event=>{
  const nav=event.target.closest('[data-page]');if(nav){closeDialog();navigate(nav.dataset.page,nav.dataset.id||'');return;}
  const element=event.target.closest('[data-action]');if(!element||element.disabled)return;
  const name=element.dataset.action;
  const saveAction=['merge-save','playlist-save','confirm-delete','confirm-clear','confirm-remove-download','download-all','add-to-playlist','save-name'].includes(name);
  if(saveAction)element.disabled=true;
  try{await action(name,element);}catch(error){toast(error.message||'Something went wrong. Please retry.');}
  finally{if(saveAction)element.disabled=false;}
});
document.addEventListener('input',event=>{
  const target=event.target;
  if(target.id==='library-filter'){libraryFilter=target.value;$('#library-cards').innerHTML=visiblePlaylists().length?playlistCards(visiblePlaylists()):empty('No playlists match your search.');}
  if(target.id==='full-seek')seekTo(Number(target.value));
  if(target.hasAttribute('data-player-volume'))setVolume(target.value);
});
document.addEventListener('change',async event=>{
  const target=event.target;
  try{
    if(target.dataset.setting){const key=target.dataset.setting;const value=target.type==='checkbox'?target.checked:['speed','volume'].includes(key)?Number(target.value):target.value;await changeSettings({[key]:value});}
    if(target.id==='library-sort'){librarySort=target.value;renderPage();}
    if(target.id==='replay-year'){replayYear=Number(target.value);renderReplay();}
    if(target.id==='editor-sort'&&target.value){captureEditor();editor.tracks.sort((a,b)=>target.value==='title'?a.trackName.localeCompare(b.trackName):a.artistName.localeCompare(b.artistName));renderEditor();}
  }catch(error){toast(error.message);}
});
document.addEventListener('dragstart',event=>{const row=event.target.closest('[data-queue-index],[data-edit-index]');if(!row)return;dragIndex=Number(row.dataset.queueIndex??row.dataset.editIndex);event.dataTransfer.setData('text/plain',String(dragIndex));event.dataTransfer.effectAllowed='move';});
document.addEventListener('dragover',event=>{if(event.target.closest('[data-queue-index],[data-edit-index]'))event.preventDefault();});
document.addEventListener('drop',event=>{
  const row=event.target.closest('[data-queue-index],[data-edit-index]');if(!row||dragIndex===null)return;event.preventDefault();
  if(row.dataset.queueIndex!==undefined){queue.move(dragIndex,Number(row.dataset.queueIndex));renderQueue();}
  else if(editor){captureEditor();editor.tracks.splice(Number(row.dataset.editIndex),0,editor.tracks.splice(dragIndex,1)[0]);renderEditor();}dragIndex=null;
});
document.addEventListener('dragend',()=>dragIndex=null);
$('#close-modal').addEventListener('click',closeDialog);modal.addEventListener('close',()=>{dialogMode=null;editor=null;});
modal.addEventListener('click',event=>{if(event.target===modal){const r=modal.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)closeDialog();}});
$('#create-playlist').addEventListener('click',()=>newPlaylist());$('#back').addEventListener('click',()=>history.back());$('#forward').addEventListener('click',()=>history.forward());
$('#play-toggle').addEventListener('click',togglePlay);$('#previous').addEventListener('click',previous);$('#next').addEventListener('click',()=>next());$('#repeat').addEventListener('click',toggleRepeat);$('#shuffle').addEventListener('click',toggleShuffle);
$('#queue').addEventListener('click',renderQueue);$('#mobile-queue').addEventListener('click',renderQueue);$('#sleep').addEventListener('click',sleepDialog);$('#open-player').addEventListener('click',renderNowPlaying);
$('#now-like').addEventListener('click',()=>toggleLike(currentTrack).catch(error=>toast(error.message)));$('#volume').addEventListener('input',event=>setVolume(event.target.value));$('#mute').addEventListener('click',mute);$('#seek').addEventListener('input',event=>seekTo(Number(event.target.value)));
$('#audio-input').addEventListener('change',async event=>{
  const input=event.target,files=[...input.files];input.value='';let imported=0;
  for(const file of files){try{if(file.size>200*1024*1024)throw new Error('Audio files must be smaller than 200 MB.');toast(`Importing “${file.name}”…`);const body=new FormData();body.append('file',file);await api('/api/import-audio',{method:'POST',body,timeout:120000});imported++;}catch(error){toast(error.message);}}
  if(imported){await refresh({render:false}).catch(error=>toast(error.message));navigate('downloads');toast(`Imported ${imported} audio file${imported===1?'':'s'}.`);}
});
$('#library-input').addEventListener('change',async event=>{
  const file=event.target.files[0];event.target.value='';if(!file)return;
  try{if(file.size>10*1024*1024)throw new Error('This library file is too large.');const body=JSON.parse(await file.text());await api('/api/library/import',{method:'POST',body});await refresh({render:false});navigate('library');toast('Library imported.');}catch(error){toast(error.message||'Could not import this file.');}
});
audio.addEventListener('play',()=>updatePlayer());audio.addEventListener('pause',()=>{flushListening();updatePlayer();});audio.addEventListener('timeupdate',()=>{sample();updateProgress();});
audio.addEventListener('seeking',()=>listening.seek(audio.currentTime));audio.addEventListener('seeked',()=>listening.seek(audio.currentTime));
audio.addEventListener('waiting',()=>{buffering=true;updatePlayer();});audio.addEventListener('playing',()=>{clearTimeout(loadTimer);buffering=false;playbackError=false;updatePlayer();});audio.addEventListener('loadedmetadata',()=>{updateProgress();updateMediaSession();});
audio.addEventListener('ended',()=>{sample();flushListening();next(true);});audio.addEventListener('error',()=>{if(!currentTrack||!audio.getAttribute('src'))return;buffering=false;playbackError=true;flushListening();updatePlayer();toast('Audio could not load. Check the connection or try a different song.');});
document.addEventListener('visibilitychange',()=>{if(document.hidden)flushListening();});window.addEventListener('pagehide',()=>{flushListening();if(volumeTimer)navigator.sendBeacon('/api/settings',new Blob([JSON.stringify({volume:profile.settings.volume})],{type:'application/json'}));});
window.addEventListener('hashchange',route);
if('mediaSession' in navigator){for(const [name,handler] of Object.entries({play:()=>{if(audio.paused)togglePlay();},pause,previoustrack:previous,nexttrack:()=>next(),seekto:details=>seekTo(details.seekTime),seekbackward:details=>seekTo(audio.currentTime-(details.seekOffset||10)),seekforward:details=>seekTo(audio.currentTime+(details.seekOffset||10))})){try{navigator.mediaSession.setActionHandler(name,handler);}catch{}}}
document.addEventListener('keydown',event=>{if(event.code==='Space'&&!modal.open&&!event.target.closest('input,textarea,select,button,a')){event.preventDefault();togglePlay();}});
document.addEventListener('error',event=>{if(event.target.tagName==='IMG'&&!event.target.src.endsWith(logo))event.target.src=logo;},true);
route();refresh().then(()=>{audio.volume=profile.settings.volume;audio.playbackRate=profile.settings.speed;flushListening();pollJobs();}).catch(error=>toast(error.message));
