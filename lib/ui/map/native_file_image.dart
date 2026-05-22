import 'dart:io';
import 'package:flutter/material.dart';

class NativeFileImage extends StatelessWidget {
  final String path;
  const NativeFileImage({super.key, required this.path});
  @override
  Widget build(BuildContext context) {
    return Image.file(File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
  }
}
