import 'package:flutter/material.dart';

/// A custom [ScrollBehavior] that completely disables/hides scrollbars.
///
/// Useful on desktop and web platforms when a scrollable widget (like a
/// centered card) displays an ugly scrollbar in the middle of the viewport.
class NoScrollbarBehavior extends ScrollBehavior {
  const NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
