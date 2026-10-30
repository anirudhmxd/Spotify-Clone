import 'music.dart';
import 'equalizer.dart';

enum AudioQuality { dataSaver, balanced, high }

enum RepeatMode { off, all, one }

class AppSettings {
  final String displayName, equalizer;
  final bool autoplay, offline, privateSession, equalizerEnabled;
  final List<double>? equalizerBands;
  List<double> get eqGains =>
      Equalizer.sanitize(equalizerBands, preset: equalizer);
  final double speed, volume;
  final AudioQuality streamingQuality, downloadQuality;
  const AppSettings({
    this.displayName = 'Your music',
    this.equalizer = 'flat',
    this.equalizerEnabled = true,
    this.equalizerBands,
    this.autoplay = true,
    this.offline = false,
    this.privateSession = false,
    this.speed = 1,
    this.volume = .7,
    this.streamingQuality = AudioQuality.high,
    this.downloadQuality = AudioQuality.high,
  });
  AppSettings copyWith({
    String? displayName,
    String? equalizer,
    List<double>? equalizerBands,
    bool? equalizerEnabled,
    bool? autoplay,
    bool? offline,
    bool? privateSession,
    double? speed,
    double? volume,
    AudioQuality? streamingQuality,
    AudioQuality? downloadQuality,
  }) => AppSettings(
    displayName: displayName ?? this.displayName,
    equalizer: equalizer ?? this.equalizer,
    equalizerBands: equalizerBands == null
        ? this.equalizerBands
        : Equalizer.sanitize(equalizerBands),
    equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
    autoplay: autoplay ?? this.autoplay,
    offline: offline ?? this.offline,
    privateSession: privateSession ?? this.privateSession,
    speed: speed ?? this.speed,
    volume: volume ?? this.volume,
    streamingQuality: streamingQuality ?? this.streamingQuality,
    downloadQuality: downloadQuality ?? this.downloadQuality,
  );
  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'equalizer': equalizer,
    'equalizerBands': eqGains,
    'equalizerEnabled': equalizerEnabled,
    'autoplay': autoplay,
    'offline': offline,
    'privateSession': privateSession,
    'speed': speed,
    'volume': volume,
    'streamingQuality': streamingQuality.name,
    'downloadQuality': downloadQuality.name,
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    AudioQuality quality(dynamic value) => AudioQuality.values.firstWhere(
      (q) => q.name == value,
      orElse: () => AudioQuality.high,
    );
    return AppSettings(
      displayName: j['displayName'] as String? ?? 'Your music',
      equalizer:
          ['flat', 'bass', 'vocal', 'treble', 'custom'].contains(j['equalizer'])
          ? j['equalizer']
          : 'flat',
      equalizerBands: j['equalizerBands'] is List
          ? Equalizer.sanitize(j['equalizerBands'])
          : null,
      equalizerEnabled: j['equalizerEnabled'] != false,
      autoplay: j['autoplay'] != false,
      offline: j['offline'] == true,
      privateSession: j['privateSession'] == true,
      speed: ((j['speed'] as num?)?.toDouble() ?? 1).clamp(.5, 2),
      volume: ((j['volume'] as num?)?.toDouble() ?? .7).clamp(0, 1),
      streamingQuality: quality(j['streamingQuality']),
      downloadQuality: quality(j['downloadQuality']),
    );
  }
}

class ListenDay {
  final Track track;
  final DateTime day;
  final int milliseconds, plays;
  const ListenDay({
    required this.track,
    required this.day,
    required this.milliseconds,
    required this.plays,
  });
  factory ListenDay.fromJson(Map<String, dynamic> j) => ListenDay(
    track: Track.fromJson(j['track']),
    day: DateTime.parse(j['day']),
    milliseconds: (j['milliseconds'] as num).toInt(),
    plays: (j['plays'] as num).toInt(),
  );
  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'day': day.toIso8601String(),
    'milliseconds': milliseconds,
    'plays': plays,
  };
}

class DownloadRecord {
  final Track track;
  final String path;
  final int bytes;
  const DownloadRecord({
    required this.track,
    required this.path,
    required this.bytes,
  });
  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
    track: Track.fromJson(j['track']),
    path: j['path'],
    bytes: (j['bytes'] as num).toInt(),
  );
  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'path': path,
    'bytes': bytes,
  };
}

class LibraryProfile {
  final AppSettings settings;
  final List<Track> liked, recent;
  final List<ListenDay> listening;
  final List<String> searches;
  final List<DownloadRecord> downloads;
  const LibraryProfile({
    this.settings = const AppSettings(),
    this.liked = const [],
    this.recent = const [],
    this.listening = const [],
    this.searches = const [],
    this.downloads = const [],
  });
  LibraryProfile withDownloads(List<DownloadRecord> value) => LibraryProfile(
    settings: settings,
    liked: liked,
    recent: recent,
    listening: listening,
    searches: searches,
    downloads: value,
  );
}

class WrappedSummary {
  final int year;
  final List<ListenDay> entries;
  WrappedSummary(Iterable<ListenDay> all, this.year)
    : entries = all.where((e) => e.day.year == year).toList();
  int get milliseconds => entries.fold(0, (total, e) => total + e.milliseconds);
  int get minutes => milliseconds ~/ 60000;
  int get plays => entries.fold(0, (total, e) => total + e.plays);
  int get uniqueSongs => entries.map((e) => e.track.id).toSet().length;
  int get uniqueArtists => entries.map((e) => e.track.artist).toSet().length;
  int get days =>
      entries.map((e) => '${e.day.month}-${e.day.day}').toSet().length;
  Map<String, int> get artistTime {
    final sums = <String, int>{};
    for (final e in entries) {
      sums.update(
        e.track.artist,
        (v) => v + e.milliseconds,
        ifAbsent: () => e.milliseconds,
      );
    }
    return Map.fromEntries(
      sums.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
    );
  }

  List<Track> get topTracks {
    final sums = <String, int>{};
    final tracks = <String, Track>{};
    for (final e in entries) {
      tracks[e.track.id] = e.track;
      sums.update(
        e.track.id,
        (v) => v + e.milliseconds,
        ifAbsent: () => e.milliseconds,
      );
    }
    final ids = sums.keys.toList()
      ..sort((a, b) => sums[b]!.compareTo(sums[a]!));
    return ids.map((id) => tracks[id]!).toList();
  }

  List<int> get monthlyMinutes => List.generate(
    12,
    (i) =>
        entries
            .where((e) => e.day.month == i + 1)
            .fold(0, (sum, e) => sum + e.milliseconds) ~/
        60000,
  );
  String get shareText =>
      '$year · My Rhythm Replay\n$minutes minutes · $plays plays · $uniqueSongs songs · $uniqueArtists artists\n'
      '${artistTime.isEmpty ? '' : 'Top artist: ${artistTime.keys.first}\n'}'
      '${topTracks.isEmpty ? '' : 'Top song: ${topTracks.first.title}\n'}Based on my listening on this device.';
}
