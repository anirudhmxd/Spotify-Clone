import 'package:flutter/material.dart';
import '../music_controller.dart';
import '../services/youtube_importer.dart';

class YoutubeImportCard extends StatefulWidget {
  const YoutubeImportCard({super.key, required this.controller});
  final MusicController controller;
  @override
  State<YoutubeImportCard> createState() => _YoutubeImportCardState();
}

class _YoutubeImportCardState extends State<YoutubeImportCard> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.controller.importingYoutube) return;
    try {
      YoutubeImporter.videoId(_input.text);
    } on ArgumentError {
      setState(() => _error = 'Enter a valid YouTube video link.');
      return;
    }
    setState(() => _error = null);
    final success = await widget.controller.importYoutube(_input.text.trim());
    if (mounted && success) _input.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final busy = widget.controller.importingYoutube;
      final offline = widget.controller.settings.offline;
      return SizedBox(
        width: double.infinity,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Import from YouTube',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  offline
                      ? 'Turn off offline mode to import from YouTube.'
                      : 'Paste a video link to save its audio as an MP3 in Downloads.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _input,
                  enabled: !busy && !offline,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'YouTube video link',
                    hintText: 'https://www.youtube.com/watch?v=…',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy || offline ? null : _submit,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(
                    busy ? 'Downloading and converting…' : 'Download MP3',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
