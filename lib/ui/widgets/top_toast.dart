import 'package:flutter/material.dart';

/// Lightweight slide-down-from-top toast — replaces the default SnackBar
/// for situations where:
///   * the FAB / bottom nav must not be pushed (Material's stock SnackBar
///     reflows the Scaffold);
///   * we want the message above the user's gaze rather than under it.
///
/// Single-instance: a new call dismisses any previous toast first so they
/// don't stack.
class TopToast {
  static OverlayEntry? _current;
  static AnimationController? _controller;

  static void show(BuildContext context, String message,
      {Duration duration = const Duration(seconds: 2),
      Color? background,
      Color foreground = Colors.white}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _dismiss();

    final ctrl = AnimationController(
      duration: const Duration(milliseconds: 220),
      vsync: overlay,
    );
    final anim = CurvedAnimation(parent: ctrl, curve: Curves.easeOut);

    final entry = OverlayEntry(builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      return Positioned(
        top: mq.padding.top + 12,
        left: 16,
        right: 16,
        child: IgnorePointer(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1.5),
              end: Offset.zero,
            ).animate(anim),
            child: FadeTransition(
              opacity: anim,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: background ??
                        Theme.of(ctx)
                            .colorScheme
                            .inverseSurface
                            .withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
    _current = entry;
    _controller = ctrl;
    overlay.insert(entry);
    ctrl.forward();
    Future.delayed(duration, () async {
      if (_current != entry) return;
      try {
        await ctrl.reverse();
      } catch (_) {}
      if (_current == entry) _dismiss();
    });
  }

  static void _dismiss() {
    _current?.remove();
    _current = null;
    _controller?.dispose();
    _controller = null;
  }
}
