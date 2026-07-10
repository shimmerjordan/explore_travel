import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../app/providers.dart';
import '../../services/imghost/private_image_loader.dart';

/// Full-screen rich-text editor backed by Quill. Returns the Delta JSON when
/// the user taps save. Supports inline images via [_ImageEmbedBuilder] — the
/// embed value stores a file path (string), so the resulting Delta is fully
/// portable across the app.
class QuillEditorScreen extends ConsumerStatefulWidget {
  final String? initialJson;
  final String title;
  const QuillEditorScreen({super.key, this.initialJson, required this.title});

  @override
  ConsumerState<QuillEditorScreen> createState() => _QuillEditorScreenState();
}

class _QuillEditorScreenState extends ConsumerState<QuillEditorScreen> {
  late final q.QuillController _ctrl;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    if (widget.initialJson != null && widget.initialJson!.isNotEmpty) {
      try {
        final delta =
            q.Document.fromJson(jsonDecode(widget.initialJson!) as List);
        _ctrl = q.QuillController(
          document: delta,
          selection: const TextSelection.collapsed(offset: 0),
        );
      } catch (_) {
        _ctrl = q.QuillController.basic();
      }
    } else {
      _ctrl = q.QuillController.basic();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _insertImage() async {
    try {
      final f = await _picker.pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final sel = _ctrl.selection;
      final index = sel.baseOffset < 0 ? 0 : sel.baseOffset;
      final length = sel.extentOffset - sel.baseOffset;
      // Use replaceText with a BlockEmbed — same path flutter_quill_extensions
      // uses internally. This puts the image as its own leaf instead of
      // sneaking it into an existing inline run, which used to confuse the
      // editor's line-builder protocol (RenderEditableBox vs RenderErrorBox).
      _ctrl
        ..skipRequestKeyboard = true
        ..replaceText(
          index,
          length,
          q.BlockEmbed.image(f.path),
          null,
        )
        ..moveCursorToPosition(index + 1);
    } catch (e, st) {
      debugPrint('[QuillEditor] insertImage failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('插入图片失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _embedSettings.value = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '插入图片',
            icon: const Icon(Icons.image_outlined),
            onPressed: _insertImage,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () {
              final delta = jsonEncode(_ctrl.document.toDelta().toJson());
              Navigator.pop(context, delta);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          q.QuillSimpleToolbar(
            controller: _ctrl,
            config: const q.QuillSimpleToolbarConfig(
              showAlignmentButtons: true,
              showFontFamily: false,
              showBackgroundColorButton: true,
              showColorButton: true,
              showCodeBlock: true,
              multiRowsDisplay: false,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: q.QuillEditor.basic(
                controller: _ctrl,
                config: q.QuillEditorConfig(
                  placeholder: '在这里记录你的旅行……',
                  padding: const EdgeInsets.all(8),
                  embedBuilders: [_ImageEmbedBuilder()],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An inline, page-embeddable rich-text body editor. Unlike [QuillEditorScreen]
/// it has no Scaffold/AppBar and does not scroll internally
/// (`scrollable: false`), so it grows with its content inside an outer scroll
/// view — the body simply *is* part of the page. Text and images interleave
/// freely; the "插入图片" affordance stores a local file-path embed, the same
/// portable format the reader understands and the upload queue harvests.
///
/// The parent owns the [controller] and reads
/// `controller.document.toDelta().toJson()` on save.
class QuillBodyField extends ConsumerStatefulWidget {
  final q.QuillController controller;
  final String placeholder;
  const QuillBodyField({
    super.key,
    required this.controller,
    this.placeholder = '在这里记录你的旅行……文字与图片可自由穿插',
  });

  @override
  ConsumerState<QuillBodyField> createState() => _QuillBodyFieldState();
}

class _QuillBodyFieldState extends ConsumerState<QuillBodyField> {
  final _picker = ImagePicker();

  Future<void> _insertImage(ImageSource source) async {
    try {
      final f = await _picker.pickImage(source: source);
      if (f == null) return;
      final ctrl = widget.controller;
      final sel = ctrl.selection;
      // Insert at the cursor, or at the end when nothing is focused yet.
      final docLen = ctrl.document.length;
      var index = sel.baseOffset < 0 ? docLen - 1 : sel.baseOffset;
      if (index < 0) index = 0;
      if (index > docLen - 1) index = docLen - 1;
      final length = sel.extentOffset - sel.baseOffset;
      ctrl
        ..skipRequestKeyboard = true
        ..replaceText(
          index,
          length < 0 ? 0 : length,
          q.BlockEmbed.image(f.path),
          null,
        )
        ..moveCursorToPosition(index + 1);
    } catch (e, st) {
      debugPrint('[QuillBodyField] insertImage failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('插入图片失败：$e')));
      }
    }
  }

  Future<void> _pickInsertSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('拍照插入'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从图库插入'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source != null) await _insertImage(source);
  }

  @override
  Widget build(BuildContext context) {
    _embedSettings.value = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Compact formatting toolbar + a dedicated insert-image button.
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(children: [
            Expanded(
              child: q.QuillSimpleToolbar(
                controller: widget.controller,
                config: const q.QuillSimpleToolbarConfig(
                  showFontFamily: false,
                  showFontSize: false,
                  showCodeBlock: false,
                  showBackgroundColorButton: false,
                  showSearchButton: false,
                  showAlignmentButtons: false,
                  showInlineCode: false,
                  showDividers: false,
                  showSubscript: false,
                  showSuperscript: false,
                  showClipboardCopy: false,
                  showClipboardCut: false,
                  showClipboardPaste: false,
                  showLineHeightButton: false,
                  showLink: false,
                  multiRowsDisplay: false,
                ),
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              tooltip: '插入图片',
              icon: const Icon(Icons.add_photo_alternate_outlined),
              onPressed: _pickInsertSource,
            ),
          ]),
        ),
        const SizedBox(height: 8),
        // The editor surface — non-scrolling so the whole page scrolls and the
        // body grows naturally as content (including inline images) is added.
        Container(
          constraints: const BoxConstraints(minHeight: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: q.QuillEditor.basic(
            controller: widget.controller,
            config: q.QuillEditorConfig(
              placeholder: widget.placeholder,
              scrollable: false,
              expands: false,
              padding: EdgeInsets.zero,
              embedBuilders: [_ImageEmbedBuilder()],
            ),
          ),
        ),
      ],
    );
  }
}

/// Static settings snapshot used by the embed builder when it needs to
/// render a `gh-private://` image. Kept as a top-level `ValueNotifier` so
/// any change pushes a rebuild — embed builders don't have a Riverpod
/// scope of their own.
final ValueNotifier<dynamic> _embedSettings = ValueNotifier(null);

/// Renders an `image` Quill embed whose payload is a local file path or URL.
/// Used by both the editor and the read-only viewer below.
///
/// Matches the official flutter_quill_extensions impl: `expanded => false` so
/// the embed goes through the inline-span path (wrapped in a `WidgetSpan`),
/// and the widget gets an explicit `maxWidth` so it lays out cleanly inside
/// the span. Without these, the editor used to crash with
/// `RenderEditor expected RenderEditableBox but received RenderErrorBox`.
class _ImageEmbedBuilder extends q.EmbedBuilder {
  @override
  String get key => q.BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  String toPlainText(q.Embed node) => '[图片]';

  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) {
    // Defensive: any throw here is replaced by an ErrorWidget which the
    // editor can't accept as a line child. Catch everything.
    try {
      final src = embedContext.node.value.data?.toString() ?? '';
      if (src.isEmpty) return const _BrokenImage();
      final maxW = MediaQuery.of(context).size.width * 0.8;
      Widget image;
      if (src.startsWith('gh-private://')) {
        final s = _embedSettings.value;
        if (s == null) {
          image = const _BrokenImage();
        } else {
          image = PrivateAwareImage(
            url: src,
            settings: s,
            fit: BoxFit.contain,
            errorBuilder: (_) => const _BrokenImage(),
          );
        }
      } else if (src.startsWith('http')) {
        image = Image.network(src,
            fit: BoxFit.contain,
            errorBuilder: (_, e, st) {
              debugPrint('[QuillImage] network load failed for "$src": $e');
              return const _BrokenImage();
            });
      } else {
        final file = File(src);
        if (!file.existsSync()) {
          debugPrint('[QuillImage] file missing: $src');
          return const _BrokenImage();
        }
        image = Image.file(file,
            fit: BoxFit.contain,
            errorBuilder: (_, e, st) {
              debugPrint('[QuillImage] file load failed for "$src": $e');
              return const _BrokenImage();
            });
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW, maxHeight: 320),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: image,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('[QuillImage] embed build threw: $e\n$st');
      return const _BrokenImage();
    }
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();
  @override
  Widget build(BuildContext context) => Container(
        height: 80,
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );
}

/// Read-only Quill renderer for the journal viewer.
class QuillReader extends ConsumerStatefulWidget {
  final String json;
  const QuillReader({super.key, required this.json});
  @override
  ConsumerState<QuillReader> createState() => _QuillReaderState();
}

class _QuillReaderState extends ConsumerState<QuillReader> {
  late final q.QuillController _ctrl;

  @override
  void initState() {
    super.initState();
    try {
      final delta = q.Document.fromJson(jsonDecode(widget.json) as List);
      _ctrl = q.QuillController(
        document: delta,
        selection: const TextSelection.collapsed(offset: 0),
        readOnly: true,
      );
    } catch (_) {
      _ctrl = q.QuillController.basic()..readOnly = true;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Push the current settings into the embed builder's static slot so the
    // private-image loader can find the PAT.
    _embedSettings.value = ref.watch(settingsProvider);
    return q.QuillEditor.basic(
      controller: _ctrl,
      config: q.QuillEditorConfig(
        showCursor: false,
        padding: EdgeInsets.zero,
        embedBuilders: [_ImageEmbedBuilder()],
      ),
    );
  }
}

/// Decodes a Quill Delta JSON to plain text for previews.
String quillToPreview(String deltaJson) {
  if (deltaJson.isEmpty) return '';
  try {
    final delta = jsonDecode(deltaJson) as List;
    final buf = StringBuffer();
    for (final op in delta) {
      if (op is Map && op['insert'] is String) {
        buf.write(op['insert']);
      } else if (op is Map && op['insert'] is Map) {
        final m = op['insert'] as Map;
        if (m.containsKey('image')) buf.write('[图片]');
      }
    }
    return buf.toString().trim();
  } catch (_) {
    return deltaJson;
  }
}
