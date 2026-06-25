import 'package:flutter/widgets.dart';

/// Constrains content to a comfortable reading width on wide (desktop / web)
/// windows so cards and list tiles don't stretch edge-to-edge; on phones it
/// passes the child through unchanged.
///
/// Wrap a screen's scroll view body:  `body: ResponsiveContent(child: ...)`.
class ResponsiveContent extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final double breakpoint;

  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = 720,
    this.breakpoint = 800,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= breakpoint) return child;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}
