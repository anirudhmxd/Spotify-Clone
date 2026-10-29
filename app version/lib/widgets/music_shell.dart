import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/music.dart';
import '../music_controller.dart';
import 'player_bar.dart';
import 'artwork.dart';

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
                    ? const Icon(Icons.check, color: Color(0xff1ed760))
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
    try {
      if (!await launchUrl(
        c.api.download(track),
        mode: LaunchMode.externalApplication,
      )) {
        c.message('Could not open the download.');
      }
    } catch (_) {
      c.message('Could not open the download.');
    }
  }

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
                                    Color(0xff283b3e),
                                    Color(0xff121212),
                                  ],
                                  stops: [0, .65],
                                ),
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: _content(wide),
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
                    MusicPage.search => 0,
                    MusicPage.songs => 1,
                    _ => 2,
                  },
                  onDestinationSelected: (index) => c.navigate(
                    [
                      MusicPage.search,
                      MusicPage.songs,
                      MusicPage.library,
                    ][index],
                  ),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: 'Search',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.favorite_outline),
                      label: 'For You',
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
    color: const Color(0xff121212),
    borderRadius: BorderRadius.circular(8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 16, 20),
          child: Row(
            children: [
              Icon(Icons.graphic_eq, color: Color(0xff1ed760), size: 30),
              SizedBox(width: 10),
              Text(
                'Spotify',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
              ),
            ],
          ),
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
              const Expanded(
                child: Text(
                  'Your Library',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
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
      for (final playlist in c.playlists)
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
          subtitle: Text('${playlist.tracks.length} songs'),
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
        style: TextStyle(
          color: selected ? const Color(0xff1ed760) : Colors.white,
        ),
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
          if (wide) ...[
            Text(
              formatTime(Duration(milliseconds: track.durationMs)),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            IconButton(
              tooltip: 'Download ${track.title}',
              onPressed: () => _download(track),
              icon: const Icon(Icons.download_outlined, size: 20),
            ),
            IconButton(
              tooltip: playlist == null
                  ? 'Add to playlist'
                  : 'Remove from playlist',
              onPressed: c.mutating
                  ? null
                  : () => playlist == null
                        ? _add(track)
                        : c.removeTrack(playlist, track),
              icon: Icon(playlist == null ? Icons.add : Icons.close, size: 20),
            ),
          ] else
            PopupMenuButton<String>(
              tooltip: 'Song options',
              onSelected: (action) {
                if (action == 'download') {
                  unawaited(_download(track));
                } else if (playlist != null) {
                  unawaited(c.removeTrack(playlist, track));
                } else {
                  unawaited(_add(track));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'download', child: Text('Download')),
                PopupMenuItem(
                  value: 'playlist',
                  enabled: !c.mutating,
                  child: Text(
                    playlist == null
                        ? 'Add to playlist'
                        : 'Remove from playlist',
                  ),
                ),
              ],
            ),
          IconButton.filled(
            tooltip: selected && c.audio.playing
                ? 'Pause ${track.title}'
                : 'Play ${track.title}',
            onPressed: () =>
                c.playTracks(tracks, index, playlistId: playlist?.id),
            icon: selected && c.audio.loading
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
