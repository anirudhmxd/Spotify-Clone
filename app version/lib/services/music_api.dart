import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/music.dart';

class MusicApi {
  final Uri base;
  final http.Client Function() clientFactory;
  http.Client? _searchClient;
  final Set<http.Client> _clients = {};
  MusicApi(String server, {http.Client Function()? clientFactory})
    : base = Uri.parse(server),
      clientFactory = clientFactory ?? http.Client.new;

  Uri url(String path) => base.resolve(path);
  void cancelSearch() {
    _searchClient?.close();
    _searchClient = null;
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool search = false,
  }) async {
    final client = clientFactory();
    _clients.add(client);
    if (search) {
      cancelSearch();
      _searchClient = client;
    }
    try {
      final req = http.Request(method, url(path));
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final response = await (() async => http.Response.fromStream(
        await client.send(req),
      ))().timeout(const Duration(seconds: 20));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 400) {
        throw Exception(
          data['error'] ?? 'Request failed (${response.statusCode}).',
        );
      }
      return data;
    } on TimeoutException {
      throw Exception('The server took too long. Please try again.');
    } on FormatException {
      throw Exception('The server returned an invalid response.');
    } on http.ClientException {
      throw Exception(
        'Cannot reach the music server. Check its address and connection.',
      );
    } finally {
      if (identical(_searchClient, client)) _searchClient = null;
      _clients.remove(client);
      client.close();
    }
  }

  Future<Map<String, dynamic>> search(String query, int page) => request(
    '/api/search',
    method: 'POST',
    body: {'query': query, 'page': page},
    search: true,
  );
  Future<List<Playlist>> playlists() async =>
      ((await request('/api/playlists'))['playlists'] as List)
          .map((item) => Playlist.fromJson(item))
          .toList();
  Future<Playlist> createPlaylist(String name) async => Playlist.fromJson(
    (await request(
      '/api/playlists',
      method: 'POST',
      body: {'name': name},
    ))['playlist'],
  );
  Future<void> deletePlaylist(String id) async {
    await request('/api/playlists/$id', method: 'DELETE');
  }

  Future<Playlist> addTrack(String id, Track track) async => Playlist.fromJson(
    (await request(
      '/api/playlists/$id/tracks',
      method: 'POST',
      body: {'track': track.toJson()},
    ))['playlist'],
  );
  Future<Playlist> removeTrack(String id, String trackId) async =>
      Playlist.fromJson(
        (await request(
          '/api/playlists/$id/tracks/$trackId',
          method: 'DELETE',
        ))['playlist'],
      );
  Future<List<Track>> songs() async =>
      decodeTracks((await request('/api/liked-songs'))['songs']);
  Future<List<Track>> recommend(List<Track> queue) async => decodeTracks(
    (await request(
      Uri(
        path: '/api/liked-songs/recommend',
        queryParameters: {
          'limit': '15',
          'exclude': queue.map((t) => t.id).toList(),
        },
      ).toString(),
    ))['songs'],
  );
  Future<void> score(Track track) async {
    await request(
      '/api/liked-songs/score',
      method: 'POST',
      body: {'trackId': track.id},
    );
  }

  Uri download(Track track) => url(
    Uri(
      path: '/api/download/${track.id}',
      queryParameters: {'name': track.title},
    ).toString(),
  );
  void dispose() {
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
  }
}
