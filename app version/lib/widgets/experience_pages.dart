import '../brand.dart';
import 'package:flutter/material.dart';
import '../models/experience.dart';
import '../models/music.dart';
import '../music_controller.dart';
import 'artwork.dart';
import 'equalizer_panel.dart';
import 'youtube_import_button.dart';

class ExperiencePages extends StatelessWidget {
  final MusicController c;
  final Widget Function(List<Track>, int) row;
  final void Function(String) search;
  final VoidCallback importAudio, exportLibrary, importLibrary;
  const ExperiencePages({
    super.key,
    required this.c,
    required this.row,
    required this.search,
    required this.importAudio,
    required this.exportLibrary,
    required this.importLibrary,
  });
  Widget heading(String title, [String? subtitle]) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: Colors.white60)),
        ],
      ],
    ),
  );
  Widget section(String title) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Text(
      title,
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    ),
  );
  Widget shortcut(
    String title,
    String subtitle,
    IconData icon,
    Color color,
    VoidCallback tap,
  ) => SizedBox(
    width: 240,
    child: Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32),
              const SizedBox(height: 20),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(subtitle),
            ],
          ),
        ),
      ),
    ),
  );
  Widget tracks(
    String title,
    List<Track> items, {
    List<Widget> actions = const [],
    String empty = 'Nothing here yet.',
  }) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(20),
        sliver: SliverList.list(
          children: [
            heading(title, '${items.length} songs'),
            if (actions.isNotEmpty)
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            if (items.isNotEmpty)
              FilledButton.icon(
                onPressed: () => c.playTracks(items, 0),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  empty,
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
          ],
        ),
      ),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (_, i) => row(items, i),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );
  @override
  Widget build(BuildContext context) => switch (c.page) {
    MusicPage.home => _home(context),
    MusicPage.liked => tracks(
      'Liked Songs',
      c.profile.liked,
      empty: 'Tap the heart on a song to save it here.',
      actions: [
        OutlinedButton.icon(
          onPressed: c.profile.liked.isEmpty
              ? null
              : () => c.makePlaylist('My liked songs', c.profile.liked),
          icon: const Icon(Icons.playlist_add),
          label: const Text('Make a playlist'),
        ),
      ],
    ),
    MusicPage.history => tracks(
      'Recently played',
      c.profile.recent,
      empty: 'Your listening history will appear after you play music.',
    ),
    MusicPage.downloads => _downloads(context),
    MusicPage.artist => tracks(
      c.artist,
      c.artistTracks,
      actions: [
        OutlinedButton.icon(
          onPressed: () => search(c.artist),
          icon: const Icon(Icons.search),
          label: const Text('Find more songs'),
        ),
      ],
    ),
    MusicPage.wrapped => WrappedPage(c: c),
    MusicPage.settings => _settings(context),
    _ => const SizedBox.shrink(),
  };
  Widget _home(BuildContext context) => ListView(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 18 : 28),
    children: [
      heading(
        'Your daily rhythm',
        'A little familiar. A little unexpected. All yours.',
      ),
      Container(
        margin: const EdgeInsets.only(top: 8, bottom: 24),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff493773), Color(0xff252f53), Color(0xff192b3b)],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  color: RhythmBrand.cyan,
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  'MADE FOR YOUR MOMENT',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: RhythmBrand.cyan,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Find your next\non-repeat song.',
              style: TextStyle(
                fontSize: 34,
                height: 1.12,
                letterSpacing: -1,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Start with a favourite. Discover what comes next.',
              style: TextStyle(color: Color(0xffd0cede), height: 1.5),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => c.navigate(MusicPage.search),
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Find music'),
                ),
                OutlinedButton.icon(
                  onPressed: () => c.navigate(MusicPage.songs),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('Made for you'),
                ),
              ],
            ),
          ],
        ),
      ),
      LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 650 ? 4 : 2;
          final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
          Widget tile(
            String title,
            String subtitle,
            IconData icon,
            Color color,
            MusicPage page,
          ) => SizedBox(
            width: width,
            child: Material(
              color: RhythmBrand.raised,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => c.navigate(page),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, color: color, size: 26),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              tile(
                'Liked songs',
                '${c.profile.liked.length} favourites',
                Icons.favorite_rounded,
                RhythmBrand.pink,
                MusicPage.liked,
              ),
              tile(
                'Downloads',
                '${c.profile.downloads.length} offline',
                Icons.download_rounded,
                RhythmBrand.cyan,
                MusicPage.downloads,
              ),
              tile(
                'Made for you',
                'Similar songs',
                Icons.auto_awesome_rounded,
                RhythmBrand.violet,
                MusicPage.songs,
              ),
              tile(
                'Rhythm Replay',
                'Your listening story',
                Icons.insights_rounded,
                RhythmBrand.blue,
                MusicPage.wrapped,
              ),
            ],
          );
        },
      ),
      if (c.profile.recent.isNotEmpty) ...[
        section('Jump back in'),
        ...List.generate(
          c.profile.recent.take(6).length,
          (i) => row(c.profile.recent, i),
        ),
        TextButton(
          onPressed: () => c.navigate(MusicPage.history),
          child: const Text('Show listening history'),
        ),
      ],
      if (c.playlists.isNotEmpty) ...[
        section('Your playlists'),
        ...c.visiblePlaylists
            .take(6)
            .map(
              (p) => ListTile(
                leading: Artwork(
                  url: p.tracks.isEmpty ? '' : p.tracks.first.artwork,
                ),
                title: Text(p.name),
                subtitle: Text('${p.tracks.length} songs'),
                onTap: () => c.openPlaylist(p),
              ),
            ),
      ],
      section('Find your next favourite'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            [
                  'Pop',
                  'Hip hop',
                  'Rock',
                  'Jazz',
                  'Classical',
                  'Bollywood',
                  'Indie',
                  'Electronic',
                  'Focus',
                  'Workout',
                ]
                .map(
                  (genre) => ActionChip(
                    label: Text(genre),
                    onPressed: () => search('$genre music'),
                  ),
                )
                .toList(),
      ),
      const SizedBox(height: 24),
      ListTile(
        leading: const Icon(Icons.favorite_outline),
        title: const Text('Made for you'),
        subtitle: const Text('Related songs inspired by your listening'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => c.navigate(MusicPage.songs),
      ),
      ListTile(
        leading: const Icon(Icons.folder_open),
        title: const Text('Bring your own music'),
        subtitle: const Text('Import audio files for offline listening'),
        onTap: importAudio,
      ),
    ],
  );
  Widget _downloads(BuildContext context) {
    final items = c.profile.downloads.map((r) => r.track).toList();
    final bytes = c.profile.downloads.fold(0, (sum, r) => sum + r.bytes);
    return tracks(
      'Downloads & local files',
      items,
      empty: 'Download a song or import an audio file to listen offline.',
      actions: [
        YoutubeImportButton(controller: c),
        Chip(label: Text('${(bytes / 1048576).toStringAsFixed(1)} MB used')),
        OutlinedButton.icon(
          onPressed: importAudio,
          icon: const Icon(Icons.folder_open),
          label: const Text('Import audio'),
        ),
      ],
    );
  }

  Future<void> _renameProfile(BuildContext context) async {
    final input = TextEditingController(text: c.settings.displayName);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: input, autofocus: true, maxLength: 50),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(ctx, input.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null) {
      await c.updateSettings(c.settings.copyWith(displayName: value));
    }
  }

  Widget _settings(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      heading('Settings', 'Make listening feel right for you.'),
      ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: Text(c.settings.displayName),
        subtitle: const Text('Local profile'),
        trailing: const Icon(Icons.edit),
        onTap: () => _renameProfile(context),
      ),
      section('Playback'),
      SwitchListTile(
        title: const Text('Autoplay'),
        subtitle: const Text(
          'Continue with songs from your listening history when the queue ends.',
        ),
        value: c.settings.autoplay,
        onChanged: (v) => c.updateSettings(c.settings.copyWith(autoplay: v)),
      ),
      SwitchListTile(
        title: const Text('Offline mode'),
        subtitle: const Text(
          'Search your library and play downloaded or imported audio only.',
        ),
        value: c.settings.offline,
        onChanged: (v) => c.updateSettings(c.settings.copyWith(offline: v)),
      ),
      ListTile(
        title: const Text('Playback speed'),
        trailing: DropdownButton<double>(
          value: c.settings.speed,
          items:
              ({.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0, c.settings.speed}.toList()
                    ..sort())
                  .map((s) => DropdownMenuItem(value: s, child: Text('$s×')))
                  .toList(),
          onChanged: (v) {
            if (v != null) c.updateSettings(c.settings.copyWith(speed: v));
          },
        ),
      ),
      ListTile(
        title: const Text('Volume'),
        subtitle: Slider(value: c.volume, onChanged: c.setVolume),
      ),
      EqualizerPanel(controller: c),
      ListTile(
        title: const Text('Sleep timer'),
        subtitle: Text(
          c.sleepAfterTrack
              ? 'At the end of this song'
              : c.sleepUntil == null
              ? 'Off'
              : 'Stops at ${TimeOfDay.fromDateTime(c.sleepUntil!).format(context)}',
        ),
        onTap: () => showSleepTimer(context, c),
      ),
      section('Audio quality'),
      _quality(
        'Streaming quality',
        c.settings.streamingQuality,
        (q) => c.updateSettings(c.settings.copyWith(streamingQuality: q)),
      ),
      _quality(
        'Download quality',
        c.settings.downloadQuality,
        (q) => c.updateSettings(c.settings.copyWith(downloadQuality: q)),
      ),
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Quality applies to the next stream or new download. The available bitrate depends on the source.',
          style: TextStyle(color: Colors.white60),
        ),
      ),
      section('Privacy & library'),
      SwitchListTile(
        title: const Text('Private session'),
        subtitle: const Text(
          'Exclude new listening and searches from history, recommendations, and Replay.',
        ),
        value: c.settings.privateSession,
        onChanged: (v) =>
            c.updateSettings(c.settings.copyWith(privateSession: v)),
      ),
      ListTile(
        leading: const Icon(Icons.save_alt),
        title: const Text('Export library'),
        subtitle: const Text('Save playlists and liked songs as a JSON backup'),
        onTap: exportLibrary,
      ),
      ListTile(
        leading: const Icon(Icons.file_open),
        title: const Text('Import library'),
        subtitle: const Text('Merge playlists and likes from a backup'),
        onTap: importLibrary,
      ),
      ListTile(
        leading: const Icon(Icons.delete_outline),
        title: const Text('Clear listening history'),
        subtitle: const Text('Also resets your Replay and Songs For You.'),
        onTap: () async {
          final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Clear listening history?'),
              content: const Text(
                'This removes listening statistics and recent searches from this device. Your playlists, likes, and downloads are kept.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Clear'),
                ),
              ],
            ),
          );
          if (yes == true) await c.clearHistory();
        },
      ),
      section('About Rhythm'),
      Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.asset(
            RhythmBrand.logo,
            width: 220,
            height: 220,
            semanticLabel: 'Rhythm',
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Rhythm · Your music, your device\nMusic discovery uses YouTube. Your listening story includes only listening recorded in Rhythm.',
        style: TextStyle(color: Colors.white60),
      ),
      const SizedBox(height: 32),
    ],
  );
  Widget _quality(
    String title,
    AudioQuality value,
    void Function(AudioQuality) change,
  ) => ListTile(
    title: Text(title),
    trailing: DropdownButton<AudioQuality>(
      value: value,
      items: const [
        DropdownMenuItem(
          value: AudioQuality.dataSaver,
          child: Text('Data saver'),
        ),
        DropdownMenuItem(value: AudioQuality.balanced, child: Text('Balanced')),
        DropdownMenuItem(value: AudioQuality.high, child: Text('High')),
      ],
      onChanged: (v) {
        if (v != null) change(v);
      },
    ),
  );
}

Future<void> showSleepTimer(BuildContext context, MusicController c) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Sleep timer',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            for (final minutes in [5, 15, 30, 45, 60])
              ListTile(
                title: Text('$minutes minutes'),
                onTap: () {
                  c.setSleepTimer(Duration(minutes: minutes));
                  Navigator.pop(ctx);
                },
              ),
            ListTile(
              title: const Text('End of this song'),
              onTap: c.current == null
                  ? null
                  : () {
                      c.setSleepTimer(null, afterTrack: true);
                      Navigator.pop(ctx);
                    },
            ),
            ListTile(
              title: const Text('Turn off timer'),
              onTap: () {
                c.setSleepTimer(null);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );

class WrappedPage extends StatefulWidget {
  final MusicController c;
  const WrappedPage({super.key, required this.c});
  @override
  State<WrappedPage> createState() => _WrappedPageState();
}

class _WrappedPageState extends State<WrappedPage> {
  late int year = widget.c.now().year;
  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final summary = WrappedSummary(c.profile.listening, year);
    final years = {
      c.now().year,
      ...c.profile.listening.map((e) => e.day.year),
    }.toList()..sort((a, b) => b.compareTo(a));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Rhythm Replay',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
              ),
            ),
            DropdownButton<int>(
              value: year,
              items: years
                  .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => year = v);
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (summary.entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 50),
            child: Text(
              'Your story starts with a song.\nListen to music in this app to build your Replay. No listening data is invented.',
              style: TextStyle(fontSize: 22),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: RhythmBrand.gradient,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$year WAS YOUR YEAR',
                  style: const TextStyle(letterSpacing: 3),
                ),
                const SizedBox(height: 20),
                Text(
                  '${summary.minutes}',
                  style: const TextStyle(
                    fontSize: 76,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Text(
                  'minutes of music',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                Text(
                  '${summary.plays} plays · ${summary.uniqueSongs} songs\n${summary.uniqueArtists} artists · ${summary.days} listening days',
                  style: const TextStyle(fontSize: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Your top artists',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          ...summary.artistTime.entries
              .take(5)
              .indexed
              .map(
                (e) => ListTile(
                  leading: CircleAvatar(child: Text('${e.$1 + 1}')),
                  title: Text(e.$2.key),
                  subtitle: Text('${e.$2.value ~/ 60000} minutes'),
                  onTap: () => c.openArtist(e.$2.key),
                ),
              ),
          const SizedBox(height: 24),
          const Text(
            'Your top songs',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          ...summary.topTracks
              .take(5)
              .indexed
              .map(
                (e) => ListTile(
                  leading: Artwork(url: e.$2.artwork),
                  title: Text(
                    e.$2.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(e.$2.artist),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => c.playTracks(summary.topTracks, e.$1),
                ),
              ),
          const SizedBox(height: 24),
          const Text(
            'Your listening through the year',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _months(summary.monthlyMinutes),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => c.makePlaylist(
                  'My $year Replay',
                  summary.topTracks.take(100).toList(),
                ),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Save top songs playlist'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Based on recorded listening on this device. Skips, seeks, buffering, and private sessions do not add listening minutes.',
            style: TextStyle(color: Colors.white60),
          ),
        ],
      ],
    );
  }

  Widget _months(List<int> values) {
    final maximum = values.fold(1, (max, value) => value > max ? value : max);
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(
          12,
          (i) => Expanded(
            child: Tooltip(
              message: '${i + 1}: ${values[i]} minutes',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: 110 * values[i] / maximum + 2,
                      decoration: BoxDecoration(
                        color: RhythmBrand.cyan,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'JFMAMJJASOND'[i],
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
