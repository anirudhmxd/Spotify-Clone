import 'package:flutter/material.dart';
import '../music_controller.dart';
import '../services/youtube_importer.dart';

class YoutubeImportButton extends StatelessWidget {
  const YoutubeImportButton({super.key, required this.controller});
  final MusicController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => OutlinedButton.icon(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _YoutubeImportDialog(controller: controller),
      ),
      icon: const Icon(Icons.video_library_outlined),
      label: Text(
        controller.importingYoutube ? 'Importing…' : 'Import from YouTube',
      ),
    ),
  );
}

class _YoutubeImportDialog extends StatefulWidget {
  const _YoutubeImportDialog({required this.controller});
  final MusicController controller;
  @override
  State<_YoutubeImportDialog> createState() => _YoutubeImportDialogState();
}

class _YoutubeImportDialogState extends State<_YoutubeImportDialog> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.controller.importingYoutube ||
        widget.controller.settings.offline) {
      return;
    }
    try {
      YoutubeImporter.videoId(_input.text);
    } on ArgumentError {
      setState(() => _error = 'Enter a valid YouTube video link.');
      return;
    }
    setState(() => _error = null);
    final success = await widget.controller.importYoutube(_input.text.trim());
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pop();
    } else {
      setState(
        () => _error =
            widget.controller.notice ?? 'Import failed. Please try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final busy = widget.controller.importingYoutube;
      final offline = widget.controller.settings.offline;
      return AlertDialog(
        title: const Text('Import from YouTube'),
        scrollable: true,
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                offline
                    ? 'Turn off offline mode to import from YouTube.'
                    : 'Paste a video link to save its audio as an MP3 in Downloads.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                autofocus: !busy && !offline,
                enabled: !busy && !offline,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'YouTube video link',
                  hintText: 'https://youtu.be/…',
                  errorText: _error,
                  errorMaxLines: 4,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Downloading and converting…'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(busy ? 'Close' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: busy || offline ? null : _submit,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download MP3'),
          ),
        ],
      );
    },
  );
}
