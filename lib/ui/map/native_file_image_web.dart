import 'package:flutter/material.dart';

class NativeFileImage extends StatelessWidget {
  final String path;
  const NativeFileImage({super.key, required this.path});
  @override
  Widget build(BuildContext context) => const Icon(Icons.broken_image);
}
