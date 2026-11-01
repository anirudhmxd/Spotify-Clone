class Track {
  final String id, title, artist, album, artwork, stream;
  final int durationMs, fullPlays;
  final bool isMusic;
  bool get isSong => isMusic || id.startsWith('local_');
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.artwork,
    required this.stream,
    this.durationMs = 0,
    this.fullPlays = 0,
    this.isMusic = false,
  });
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: '${json['trackId'] ?? ''}',
    title: json['trackName'] ?? 'Unknown title',
    artist: json['artistName'] ?? 'YouTube',
    album: json['collectionName'] ?? 'Single',
    artwork: json['artworkUrl100'] ?? '',
    stream: json['previewUrl'] ?? '',
    durationMs: (json['trackTimeMillis'] as num?)?.toInt() ?? 0,
    fullPlays: (json['fullPlays'] as num?)?.toInt() ?? 0,
    isMusic: json['isMusic'] == true,
  );
  Map<String, dynamic> toJson() => {
    'trackId': id,
    'trackName': title,
    'artistName': artist,
    'collectionName': album,
    'artworkUrl100': artwork,
    'previewUrl': stream,
    'trackTimeMillis': durationMs,
    'fullPlays': fullPlays,
    'isMusic': isMusic,
  };
}

class Playlist {
  final String id, name, description;
  final bool pinned;
  final List<Track> tracks;
  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.description = '',
    this.pinned = false,
  });
  Playlist copyWith({
    String? name,
    String? description,
    bool? pinned,
    List<Track>? tracks,
  }) => Playlist(
    id: id,
    name: name ?? this.name,
    tracks: tracks ?? this.tracks,
    description: description ?? this.description,
    pinned: pinned ?? this.pinned,
  );
  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'],
    name: json['name'],
    description: json['description'] ?? '',
    pinned: json['pinned'] == true,
    tracks: decodeTracks(json['tracks']),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'pinned': pinned,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };
  int get durationMs => tracks.fold(0, (sum, track) => sum + track.durationMs);
}

List<Track> decodeTracks(dynamic json) => (json as List? ?? [])
    .map((item) => Track.fromJson(Map<String, dynamic>.from(item as Map)))
    .toList();
String formatTime(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
