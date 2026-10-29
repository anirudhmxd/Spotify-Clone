import 'package:flutter/material.dart';
import '../models/music.dart';
import '../music_controller.dart';
import 'artwork.dart';

Future<void> editPlaylistDialog(
  BuildContext context,
  MusicController c,
  Playlist playlist,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _PlaylistEditor(c: c, playlist: playlist),
  ),
);

class _PlaylistEditor extends StatefulWidget {
  final MusicController c;
  final Playlist playlist;
  const _PlaylistEditor({required this.c, required this.playlist});
  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final name = TextEditingController(text: widget.playlist.name);
  late final description = TextEditingController(
    text: widget.playlist.description,
  );
  late List<Track> tracks = [...widget.playlist.tracks];
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Edit playlist'),
      actions: [
        TextButton(
          onPressed: saving
              ? null
              : () async {
                  if (name.text.trim().isEmpty) return;
                  setState(() => saving = true);
                  final saved = await widget.c.editPlaylist(
                    widget.playlist.copyWith(
                      name: name.text.trim(),
                      description: description.text.trim(),
                      tracks: tracks,
                    ),
                  );
                  if (!context.mounted) return;
                  if (saved) {
                    Navigator.pop(context);
                  } else {
                    setState(() => saving = false);
                  }
                },
          child: Text(saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: description,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(child: Text('Drag to reorder songs')),
                  PopupMenuButton<String>(
                    tooltip: 'Sort songs',
                    onSelected: (value) => setState(() {
                      tracks.sort(
                        (a, b) => value == 'title'
                            ? a.title.toLowerCase().compareTo(
                                b.title.toLowerCase(),
                              )
                            : a.artist.toLowerCase().compareTo(
                                b.artist.toLowerCase(),
                              ),
                      );
                    }),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'title', child: Text('Song title')),
                      PopupMenuItem(value: 'artist', child: Text('Artist')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: tracks.length,
            onReorderItem: saving
                ? (_, _) {}
                : (from, to) => setState(() {
                    tracks.insert(to, tracks.removeAt(from));
                  }),
            itemBuilder: (_, i) => ListTile(
              key: ValueKey(tracks[i].id),
              leading: Artwork(url: tracks[i].artwork, size: 40),
              title: Text(
                tracks[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(tracks[i].artist, maxLines: 1),
              trailing: Padding(
                padding: const EdgeInsets.only(right: 28),
                child: IconButton(
                  tooltip: 'Remove song',
                  onPressed: saving
                      ? null
                      : () => setState(() => tracks.removeAt(i)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
