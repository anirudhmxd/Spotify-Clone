import '../models/music.dart';

class SearchPage {
  final List<Track> tracks;
  final bool hasMore;
  const SearchPage(this.tracks, {this.hasMore = false});
}

abstract class MusicRepository {
  Future<SearchPage> search(String query, int page);
  void cancelSearch();
  Future<String> resolveAudio(Track track);
  Future<List<Playlist>> playlists();
  Future<Playlist> createPlaylist(String name);
  Future<void> deletePlaylist(String id);
  Future<Playlist> addTrack(String id, Track track);
  Future<Playlist> removeTrack(String id, String trackId);
  Future<List<Track>> songs();
  Future<List<Track>> recommend(List<Track> queue);
  Future<void> score(Track track);
  Future<String> download(Track track);
  void dispose();
}
