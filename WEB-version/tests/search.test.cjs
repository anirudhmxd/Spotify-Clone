const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../app.js'), 'utf8');
const searchCode = source.slice(source.indexOf('let searchDebounceTimer = null;'), source.indexOf('/* --------------------------------------------------------- player controls */'));

function setup() {
  const timers = new Map();
  const requests = [];
  let timerId = 0;
  const context = vm.createContext({
    AbortController,
    requestId: 0, searchQuery: '', searchPageNumber: 0, searchTracks: [],
    loadMoreButton: null,
    searchInput: { value: '', addEventListener: (_, fn) => { context.input = fn; } },
    searchStatus: { textContent: '' },
    results: {
      busy: 'false', replaceChildren() {}, append() {},
      setAttribute(_, value) { this.busy = value; }
    },
    removeLoadMoreButton() { context.loadMoreButton = null; },
    createLoadMoreButton() { return context.loadMoreButton = { disabled: false }; },
    renderResults(tracks) { context.searchTracks = tracks; },
    setTimeout(fn, ms) { timers.set(++timerId, { fn, ms }); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    // Deliberately allow stale responses after abort to exercise request guards.
    fetch(_, options) {
      return new Promise((resolve, reject) => requests.push({ options, resolve, reject }));
    }
  });
  vm.runInContext(searchCode, context);
  return {
    context, requests,
    input(value) { context.searchInput.value = value; context.input(); },
    runTimer(ms) {
      const [id, timer] = [...timers].find(([, t]) => t.ms === ms);
      timers.delete(id);
      return timer.fn();
    }
  };
}
const response = (tracks = [], hasMore = false) => ({ ok: true, json: async () => ({ tracks, hasMore }) });

test('search stays local and a cleared query rejects stale results', async () => {
  const s = setup();
  s.input('old');
  const pending = s.runTimer(300);
  s.input('');
  assert.equal(s.requests[0].options.signal.aborted, true);
  s.requests[0].resolve(response([{ previewUrl: '/old' }]));
  await pending;
  assert.equal(s.context.searchTracks.length, 0);
  assert.equal(s.context.searchStatus.textContent, '');
  assert.equal(s.context.results.busy, 'false');
});

test('typing invalidates previous search before debounce finishes', async () => {
  const s = setup();
  s.input('old');
  const pending = s.runTimer(300);
  s.input('new');
  s.requests[0].resolve(response([{ previewUrl: '/old' }]));
  await pending;
  assert.equal(s.context.searchTracks.length, 0);
  assert.equal(s.context.results.busy, 'true');
  const latest = s.runTimer(300);
  s.requests[1].resolve(response([{ previewUrl: '/new' }]));
  await latest;
  assert.equal(s.context.searchTracks[0].previewUrl, '/new');
  assert.equal(s.context.results.busy, 'false');
});

test('stalled search times out and releases loading state', async () => {
  const s = setup();
  s.input('slow');
  const pending = s.runTimer(300);
  s.requests[0].options.signal.addEventListener('abort', () => s.requests[0].reject(new Error('aborted')));
  s.runTimer(20000);
  await pending;
  assert.match(s.context.searchStatus.textContent, /took too long/);
  assert.equal(s.context.results.busy, 'false');
});

test('failed pagination retries the same page and prevents duplicate clicks', async () => {
  const s = setup();
  s.context.searchQuery = 'song';
  s.context.loadMoreButton = { disabled: false };
  const pending = s.context.loadMoreResults();
  await s.context.loadMoreResults();
  assert.equal(s.requests.length, 1);
  s.requests[0].reject(new Error('offline'));
  await pending;
  assert.equal(s.context.searchPageNumber, 0);
  assert.equal(s.context.loadMoreButton.disabled, false);
  const retry = s.context.loadMoreResults();
  assert.equal(JSON.parse(s.requests[1].options.body).page, 1);
  s.requests[1].resolve(response([{ previewUrl: '/song' }]));
  await retry;
  assert.equal(s.context.searchPageNumber, 1);
});
