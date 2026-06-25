import 'dart:io';
import 'package:flutter/material.dart';

class NativeFileImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  const NativeFileImage(
      {super.key, required this.path, this.fit = BoxFit.cover});
  @override
  Widget build(BuildContext context) {
    return Image.file(File(path),
        fit: fit,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
  }
}
