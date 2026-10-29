import '../brand.dart';
import 'package:flutter/material.dart';

class Artwork extends StatelessWidget {
  final String url;
  final double size;
  const Artwork({super.key, required this.url, this.size = 48});
  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: RhythmBrand.raised,
      width: size,
      height: size,
      child: RhythmLogo(size: size),
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
