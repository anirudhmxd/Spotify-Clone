import 'package:flutter/material.dart';

class Artwork extends StatelessWidget {
  final String url;
  final double size;
  const Artwork({super.key, required this.url, this.size = 48});
  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: const Color(0xff282828),
      width: size,
      height: size,
      child: Icon(Icons.music_note, color: Colors.white38, size: size * .45),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: url.isEmpty
          ? placeholder
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, error, stack) => placeholder,
            ),
    );
  }
}
