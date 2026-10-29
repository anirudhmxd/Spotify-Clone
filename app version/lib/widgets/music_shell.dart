import '../brand.dart';
import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/music.dart';
import '../music_controller.dart';
import 'player_bar.dart';
import 'artwork.dart';
import 'experience_pages.dart';
import 'playlist_editor.dart';

class MusicShell extends StatefulWidget {
  final MusicController controller;
  const MusicShell({super.key, required this.controller});
  @override
  State<MusicShell> createState() => _MusicShellState();
}

class _MusicShellState extends State<MusicShell> {
  final _search = TextEditingController();
  MusicController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(_notice);
  }

  void _notice() {
    final text = c.notice;
    if (text == null || !mounted) return;
    c.clearNotice();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    });
  }

  @override
  void dispose() {
    c.removeListener(_notice);
    _search.dispose();
    super.dispose();
  }

  Future<void> _create({Track? track}) async {
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Playlist name',
            hintText: 'My playlist',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(dialogContext, input.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    // Let the dialog's exit animation finish before disposing its text controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (name != null && mounted) await c.createPlaylist(name, track: track);
  }

  Future<void> _add(Track track) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Add to playlist',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            for (final playlist in c.playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                trailing: playlist.tracks.any((t) => t.id == track.id)
                    ? const Icon(Icons.check, color: RhythmBrand.violet)
                    : null,
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New playlist…'),
              onTap: () => Navigator.pop(sheetContext, '__new__'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '__new__') {
      await _create(track: track);
      return;
    }
    for (final playlist in c.playlists) {
      if (playlist.id == selected) {
        await c.addTrack(playlist, track);
        break;
      }
    }
  }

  Future<void> _delete(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('Delete “${playlist.name}”?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await c.deletePlaylist(playlist);
  }

  Future<void> _download(Track track) async {
    final path = await c.download(track);
    if (!mounted || path == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved “${track.title}” on this device.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Save / Share',
          onPressed: () async {
            try {
              final box = context.findRenderObject() as RenderBox?;
              await SharePlus.instance.share(
                ShareParams(
                  files: [XFile(path, mimeType: 'audio/mp4')],
                  title: track.title,
                  sharePositionOrigin: box == null
                      ? null
                      : box.localToGlobal(Offset.zero) & box.size,
                ),
              );
            } catch (_) {
              c.message('The file is saved, but sharing could not be opened.');
            }
          },
        ),
      ),
    );
  }

  void _searchFor(String term) {
    _search.text = term;
    c.navigate(MusicPage.search);
    c.search(term, immediate: true);
  }

  Future<void> _importAudio() async {
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Audio',
            extensions: ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'],
            uniformTypeIdentifiers: ['public.audio'],
          ),
        ],
      );
      for (final file in files) {
        await c.importAudio(file.path, file.name);
      }
      if (files.isNotEmpty) c.navigate(MusicPage.downloads);
    } catch (_) {
      c.message('Could not import the selected audio files.');
    }
  }

  Future<void> _exportLibrary() async {
    try {
      final text = await c.repository.exportLibrary();
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(utf8.encode(text), mimeType: 'application/json'),
          ],
          fileNameOverrides: ['rhythm-library.json'],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      c.message('Could not export your library.');
    }
  }

  Future<void> _importLibrary() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Library',
            extensions: ['json'],
            uniformTypeIdentifiers: ['public.json'],
          ),
        ],
      );
      if (file != null) await c.importLibrary(await file.readAsString());
    } catch (_) {
      c.message('Could not read the library file.');
    }
  }

  Widget _toolbar() => Row(
    children: [
      IconButton(
        tooltip: 'Home',
        onPressed: () => c.navigate(MusicPage.home),
        icon: const RhythmLogo(size: 32),
      ),
      const Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: RhythmWordmark(size: 15),
          ),
        ),
      ),
      if (c.settings.offline) const Chip(label: Text('Offline')),
      IconButton(
        tooltip: 'Listening history',
        onPressed: () => c.navigate(MusicPage.history),
        icon: const Icon(Icons.history),
      ),
      IconButton(
        tooltip: 'Settings',
        onPressed: () => c.navigate(MusicPage.settings),
        icon: const Icon(Icons.settings_outlined),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 800;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(wide ? 8 : 0),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (wide) SizedBox(width: 260, child: _sidebar()),
                        if (wide) const SizedBox(width: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(wide ? 8 : 0),
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    RhythmBrand.pageTop,
                                    RhythmBrand.surface,
                                  ],
                                  stops: [0, .65],
                                ),
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: Column(
                                  children: [
                                    _toolbar(),
                                    Expanded(child: _content(wide)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PlayerBar(controller: c, compact: !wide),
                ],
              ),
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: switch (c.page) {
                    MusicPage.home => 0,
                    MusicPage.search => 1,
                    _ => 2,
                  },
                  onDestinationSelected: (index) => c.navigate(
                    [
                      MusicPage.home,
                      MusicPage.search,
                      MusicPage.library,
                    ][index],
                  ),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: 'Search',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music_outlined),
                      label: 'Library',
                    ),
                  ],
                ),
        );
      },
    ),
  );

  Widget _sidebar() => Material(
    color: RhythmBrand.surface,
    borderRadius: BorderRadius.circular(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 16, 20),
          child: Row(
            children: [
              RhythmLogo(size: 44),
              SizedBox(width: 10),
              RhythmWordmark(size: 20),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.home_outlined),
          title: const Text('Home'),
          selected: c.page == MusicPage.home,
          onTap: () => c.navigate(MusicPage.home),
        ),
        ListTile(
          selected: c.page == MusicPage.search,
          leading: const Icon(Icons.search),
          title: const Text('Search'),
          onTap: () => c.navigate(MusicPage.search),
        ),
        ListTile(
          selected: c.page == MusicPage.songs,
          leading: const Icon(Icons.favorite_outline),
          title: const Text('Songs For You'),
          onTap: () => c.navigate(MusicPage.songs),
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: Colors.white70,
                  ),
                  onPressed: () => c.navigate(MusicPage.library),
                  child: const Text(
                    'Your Library',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Create playlist',
                onPressed: c.mutating ? null : () => _create(),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(child: _library()),
      ],
    ),
  );
  Widget _library() => ListView(
    padding: const EdgeInsets.all(8),
    children: [
      if (c.loadingLibrary) const LinearProgressIndicator(),
      if (c.libraryStatus.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(c.libraryStatus),
        ),
        TextButton(onPressed: c.loadLibrary, child: const Text('Retry')),
      ],
      if (c.playlists.isEmpty && !c.loadingLibrary && c.libraryStatus.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Create a playlist to group songs together.',
            style: TextStyle(color: Colors.white60),
          ),
        ),
      ListTile(
        leading: const Icon(Icons.favorite, color: RhythmBrand.pink),
        title: const Text('Liked Songs'),
        onTap: () => c.navigate(MusicPage.liked),
      ),
      ListTile(
        leading: const Icon(Icons.download_for_offline),
        title: const Text('Downloads'),
        onTap: () => c.navigate(MusicPage.downloads),
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: const Text('Rhythm Replay'),
        onTap: () => c.navigate(MusicPage.wrapped),
      ),
      for (final playlist in c.visiblePlaylists)
        ListTile(
          selected: c.activePlaylistId == playlist.id,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          leading: Artwork(
            url: playlist.tracks.isEmpty ? '' : playlist.tracks.first.artwork,
            size: 44,
          ),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${playlist.pinned ? 'Pinned · ' : ''}${playlist.tracks.length} songs',
          ),
          onTap: () => c.openPlaylist(playlist),
        ),
    ],
  );
  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 24),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: -.7,
      ),
    ),
  );
  Widget _content(bool wide) {
    if ([
      MusicPage.home,
      MusicPage.liked,
      MusicPage.downloads,
      MusicPage.history,
      MusicPage.wrapped,
      MusicPage.settings,
      MusicPage.artist,
    ].contains(c.page)) {
      return ExperiencePages(
        c: c,
        row: (tracks, index) => _track(tracks, index, null, wide),
        search: _searchFor,
        importAudio: _importAudio,
        exportLibrary: _exportLibrary,
        importLibrary: _importLibrary,
      );
    }
    if (c.page == MusicPage.library) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(child: _title('Your Library')),
                IconButton(
                  tooltip: 'Refresh library',
                  onPressed: c.loadLibrary,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Create playlist',
                  onPressed: c.mutating ? null : () => _create(),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: c.setLibraryFilter,
                    decoration: const InputDecoration(
                      hintText: 'Find a playlist',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Sort library',
                  onSelected: c.setLibrarySort,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'recent',
                      child: Text('Recently created'),
                    ),
                    PopupMenuItem(value: 'name', child: Text('Name')),
                    PopupMenuItem(value: 'size', child: Text('Song count')),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: _library()),
        ],
      );
    }
    final playlist = c.activePlaylist;
    List<Track> tracks;
    final headers = <Widget>[];
    if (c.page == MusicPage.search) {
      tracks = c.searchTracks;
      headers.addAll([
        _title('Search'),
        TextField(
          controller: _search,
          onChanged: c.search,
          onSubmitted: (value) => c.search(value, immediate: true),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'What do you want to play?',
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _search.clear();
                      c.search('');
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        if (c.searching) const LinearProgressIndicator(),
        if (c.searchStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(c.searchStatus),
          ),
        if (tracks.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Songs',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
        if (c.query.isEmpty && c.profile.searches.isNotEmpty)
          Wrap(
            spacing: 8,
            children: c.profile.searches
                .map(
                  (s) => ActionChip(
                    label: Text(s),
                    onPressed: () => _searchFor(s),
                  ),
                )
                .toList(),
          ),
        if (tracks.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: c.mutating
                  ? null
                  : () => c.makePlaylist(c.query, tracks),
              icon: const Icon(Icons.playlist_add),
              label: const Text('Save these results as a playlist'),
            ),
          ),
        if (c.query.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text(
              'Find songs, artists, or paste a YouTube playlist URL.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
      ]);
    } else if (c.page == MusicPage.songs) {
      tracks = c.songs;
      headers.addAll([
        Row(
          children: [
            Expanded(child: _title('Songs For You')),
            IconButton(
              tooltip: 'Refresh Songs For You',
              onPressed: c.loadingSongs ? null : c.loadSongs,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (c.loadingSongs) const LinearProgressIndicator(),
        if (c.songsStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(c.songsStatus),
          ),
      ]);
    } else {
      if (playlist == null) {
        return const Center(
          child: Text('Choose a playlist from your library.'),
        );
      }
      tracks = playlist.tracks;
      headers.addAll([
        if (!wide)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Back to library',
              onPressed: () => c.navigate(MusicPage.library),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Artwork(
                url: tracks.isEmpty ? '' : tracks.first.artwork,
                size: wide ? 150 : 90,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PLAYLIST',
                      style: TextStyle(fontSize: 11, letterSpacing: 1.3),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      playlist.name,
                      style: TextStyle(
                        fontSize: wide ? 42 : 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${tracks.length} songs · ${formatTime(Duration(milliseconds: playlist.durationMs))}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (playlist.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(playlist.description),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: tracks.isEmpty ? null : () => c.playPlaylist(playlist),
              icon: Icon(
                c.queuePlaylistId == playlist.id && c.audio.playing
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              label: Text(
                c.queuePlaylistId == playlist.id && c.audio.playing
                    ? 'Pause'
                    : 'Play',
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => editPlaylistDialog(context, c, playlist),
              icon: const Icon(Icons.edit),
              label: const Text('Edit'),
            ),
            OutlinedButton(
              onPressed: c.mutating
                  ? null
                  : () => c.editPlaylist(
                      playlist.copyWith(pinned: !playlist.pinned),
                    ),
              child: Text(playlist.pinned ? 'Unpin' : 'Pin'),
            ),
            OutlinedButton(
              onPressed: c.mutating
                  ? null
                  : () => c.duplicatePlaylist(playlist),
              child: const Text('Duplicate'),
            ),
            OutlinedButton(
              onPressed: tracks.isEmpty
                  ? null
                  : () async {
                      for (final track in tracks) {
                        if (!c.isDownloaded(track)) await c.download(track);
                      }
                    },
              child: const Text('Download all'),
            ),
            OutlinedButton(
              onPressed: c.mutating ? null : () => _delete(playlist),
              child: const Text('Delete playlist'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (tracks.isEmpty)
          const Text(
            'This playlist is empty. Add songs from your search results.',
          ),
      ]);
    }
    return CustomScrollView(
      key: PageStorageKey('${c.page}/${c.activePlaylistId}'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(wide ? 28 : 20, 16, wide ? 28 : 20, 8),
          sliver: SliverList.list(children: headers),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 8),
          sliver: SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) =>
                _track(tracks, index, playlist, wide),
          ),
        ),
        if (c.page == MusicPage.search && c.hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: OutlinedButton(
                  onPressed: c.loadingMore ? null : c.loadMore,
                  child: Text(c.loadingMore ? 'Loading…' : 'Load More'),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _track(List<Track> tracks, int index, Playlist? playlist, bool wide) {
    final track = tracks[index];
    final selected = c.current?.id == track.id;
    return ListTile(
      leading: Artwork(url: track.artwork, size: 48),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: selected ? RhythmBrand.violet : Colors.white),
      ),
      subtitle: Text(
        '${c.page == MusicPage.songs ? '${index + 1} · ' : ''}${track.artist} · ${track.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => c.playTracks(tracks, index, playlistId: playlist?.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide)
            IconButton(
              tooltip: c.isLiked(track) ? 'Unlike' : 'Like',
              onPressed: () => c.toggleLike(track),
              icon: Icon(
                c.isLiked(track) ? Icons.favorite : Icons.favorite_border,
                size: 20,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Song options',
            onSelected: (action) async {
              switch (action) {
                case 'like':
                  await c.toggleLike(track);
                case 'next':
                  c.addToQueue(track, next: true);
                case 'queue':
                  c.addToQueue(track);
                case 'add':
                  await _add(track);
                case 'remove':
                  if (playlist != null) await c.removeTrack(playlist, track);
                case 'download':
                  await _download(track);
                case 'deleteDownload':
                  await c.deleteDownload(track);
                case 'artist':
                  c.openArtist(track.artist);
                case 'share':
                  try {
                    final box = context.findRenderObject() as RenderBox?;
                    await SharePlus.instance.share(
                      ShareParams(
                        text:
                            '${track.title} — ${track.artist}\nhttps://www.youtube.com/watch?v=${track.id}',
                        sharePositionOrigin: box == null
                            ? null
                            : box.localToGlobal(Offset.zero) & box.size,
                      ),
                    );
                  } catch (_) {
                    c.message('Could not open sharing.');
                  }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'like',
                child: Text(
                  c.isLiked(track)
                      ? 'Remove from Liked Songs'
                      : 'Save to Liked Songs',
                ),
              ),
              const PopupMenuItem(value: 'next', child: Text('Play next')),
              const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
              const PopupMenuItem(value: 'add', child: Text('Add to playlist')),
              if (playlist != null)
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from playlist'),
                ),
              if (c.isDownloaded(track))
                const PopupMenuItem(
                  value: 'deleteDownload',
                  child: Text('Remove downloaded file'),
                )
              else
                PopupMenuItem(
                  value: 'download',
                  enabled: !c.downloading.contains(track.id),
                  child: Text(
                    c.downloading.contains(track.id)
                        ? 'Downloading…'
                        : 'Download',
                  ),
                ),
              const PopupMenuItem(value: 'artist', child: Text('View artist')),
              if (!track.id.startsWith('local_'))
                const PopupMenuItem(value: 'share', child: Text('Share song')),
            ],
          ),
          IconButton.filled(
            tooltip: selected && c.audio.playing
                ? 'Pause ${track.title}'
                : 'Play ${track.title}',
            onPressed: () =>
                c.playTracks(tracks, index, playlistId: playlist?.id),
            icon: selected && (c.audio.loading || c.resolvingAudio)
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    selected && c.audio.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
          ),
        ],
      ),
    );
  }
}
