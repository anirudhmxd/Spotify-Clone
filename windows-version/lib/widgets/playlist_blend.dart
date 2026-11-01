import 'package:flutter/material.dart';
import '../models/music.dart';
import '../music_controller.dart';
import 'artwork.dart';

Future<void> showPlaylistBlend(
  BuildContext context,
  MusicController controller, {
  String? initialPlaylistId,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _PlaylistBlend(
      controller: controller,
      initialPlaylistId: initialPlaylistId,
    ),
  ),
);

class _PlaylistBlend extends StatefulWidget {
  final MusicController controller;
  final String? initialPlaylistId;
  const _PlaylistBlend({required this.controller, this.initialPlaylistId});
  @override
  State<_PlaylistBlend> createState() => _PlaylistBlendState();
}

class _PlaylistBlendState extends State<_PlaylistBlend> {
  final _name = TextEditingController(text: 'My Blend');
  final _selected = <String>{};
  late final List<Playlist> _sources = [...widget.controller.playlists];
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_sources.any((p) => p.id == widget.initialPlaylistId)) {
      _selected.add(widget.initialPlaylistId!);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<Playlist> get _chosen =>
      _sources.where((p) => _selected.contains(p.id)).toList();

  Future<void> _save() async {
    if (_saving || _selected.length < 2 || _name.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.controller.blendPlaylists(
      _name.text.trim(),
      _chosen.map((p) => p.id).toList(),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!saved) {
        _error =
            widget.controller.notice ??
            'Could not create your blend. Please try again.';
      }
    });
    if (saved) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _chosen.expand((p) => p.tracks);
    final songs = tracks.where((t) => t.isSong).map((t) => t.id).toSet();
    final older = tracks.where((t) => !t.isSong).map((t) => t.id).toSet();
    final canSave =
        !_saving &&
        _selected.length >= 2 &&
        _name.text.trim().isNotEmpty &&
        songs.length <= 5000;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('Blend playlists')),
        body: SafeArea(
          top: false,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverList.list(
                  children: [
                    const Text(
                      'Bring your favourites together',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Choose two or more playlists. Songs follow the order below, with duplicates removed. Your original playlists are kept.',
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      key: const ValueKey('blend-name'),
                      controller: _name,
                      enabled: !_saving,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Blend name',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_selected.length} ${_selected.length == 1 ? 'playlist' : 'playlists'} selected · ${songs.length} unique ${songs.length == 1 ? 'song' : 'songs'}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (older.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${older.length} older items are not included. Play them online once to check they are songs.',
                        ),
                      ),
                    if (songs.length > 5000)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Choose fewer playlists. A blend can contain at most 5,000 songs.',
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              SliverList.builder(
                itemCount: _sources.length,
                itemBuilder: (_, index) {
                  final playlist = _sources[index];
                  final count = playlist.tracks.where((t) => t.isSong).length;
                  return CheckboxListTile(
                    key: ValueKey('blend-source-${playlist.id}'),
                    value: _selected.contains(playlist.id),
                    onChanged: _saving
                        ? null
                        : (selected) => setState(() {
                            if (selected == true) {
                              _selected.add(playlist.id);
                            } else {
                              _selected.remove(playlist.id);
                            }
                            _error = null;
                          }),
                    secondary: Artwork(
                      url: playlist.tracks.firstOrNull?.artwork ?? '',
                      size: 44,
                    ),
                    title: Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('$count ${count == 1 ? 'song' : 'songs'}'),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.all(16),
          child: FilledButton.icon(
            key: const ValueKey('create-blend'),
            onPressed: canSave ? _save : null,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.merge_rounded),
            label: Text(_saving ? 'Creating…' : 'Create blend'),
          ),
        ),
      ),
    );
  }
}
