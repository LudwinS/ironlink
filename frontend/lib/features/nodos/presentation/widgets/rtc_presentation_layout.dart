import 'package:flutter/material.dart';

/// A readable presentation plus a scrollable participant strip on small screens.
class RtcPresentationLayout extends StatelessWidget {
  const RtcPresentationLayout({
    super.key,
    required this.presentation,
    required this.participants,
  });
  final Widget presentation;
  final List<Widget> participants;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final wide = size.maxWidth >= 850;
      final strip = ListView(
        scrollDirection: wide ? Axis.vertical : Axis.horizontal,
        children: [
          for (final tile in participants)
            SizedBox(
              width: wide ? 200 : 180,
              height: wide ? 140 : 120,
              child: tile,
            ),
        ],
      );
      if (wide) {
        return Row(
          children: [
            Expanded(child: presentation),
            SizedBox(width: 200, child: strip),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: presentation),
          SizedBox(height: 120, child: strip),
        ],
      );
    },
  );
}
