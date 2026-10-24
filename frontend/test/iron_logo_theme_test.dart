import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/widgets/iron_logo.dart';

void main() {
  for (final entry in <String, IronLogo>{
    'completo': const IronLogo.full(),
    'símbolo': const IronLogo.mark(),
  }.entries) {
    testWidgets('logo ${entry.key} responde al cambio de tema sin remontarse', (
      tester,
    ) async {
      final brightness = ValueNotifier(Brightness.dark);
      addTearDown(brightness.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          child: entry.value,
          builder: (context, value, child) => MaterialApp(
            theme: ThemeData(brightness: value),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(body: Center(child: child)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.element(find.byType(IronLogo));
      expect(find.byType(ColorFiltered), findsNothing);

      brightness.value = Brightness.light;
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(IronLogo)), same(original));
      expect(find.byType(ColorFiltered), findsOneWidget);
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        AssetImage(entry.value.asset),
      );

      brightness.value = Brightness.dark;
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(IronLogo)), same(original));
      expect(find.byType(ColorFiltered), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
