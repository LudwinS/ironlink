import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:frontend/core/router/app_router.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/create_reunion_dialog.dart';
import 'package:frontend/main.dart';

Future<void> pumpApp(WidgetTester tester, {bool use24Hours = false}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
  tester.platformDispatcher.alwaysUse24HourFormatTestValue = use24Hours;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: CreateReunionDialog(initialDate: DateTime(2026, 10, 5)),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [routerProvider.overrideWithValue(router)],
      child: const IronLinkApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Finder pickerText(Type picker, String text) =>
    find.descendant(of: find.byType(picker), matching: find.text(text));

void main() {
  testWidgets('fecha en español, semana desde lunes y entrada día/mes/año', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.calendar_today_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(pickerText(DatePickerDialog, 'Cancelar'), findsOneWidget);
    expect(pickerText(DatePickerDialog, 'ACEPTAR'), findsOneWidget);
    expect(pickerText(DatePickerDialog, 'octubre de 2026'), findsOneWidget);
    final context = tester.element(find.byType(DatePickerDialog));
    final localizations = MaterialLocalizations.of(context);
    expect(Localizations.localeOf(context), const Locale('es'));
    expect(
      localizations.firstDayOfWeekIndex,
      weekStartOf(DateTime(2026, 10, 5)).weekday,
    );

    await tester.tap(find.byTooltip(localizations.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.byType(TextField),
      ),
      '06/10/2026',
    );
    await tester.tap(pickerText(DatePickerDialog, 'ACEPTAR'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('06/10/2026'), findsOneWidget);
  });

  for (final use24Hours in [false, true]) {
    for (final field in ['Inicio', 'Fin']) {
      testWidgets('$field en español y 24 horas (sistema: $use24Hours)', (
        tester,
      ) async {
        await pumpApp(tester, use24Hours: use24Hours);
        await tester.tap(
          find.byIcon(
            field == 'Inicio'
                ? Icons.access_time_rounded
                : Icons.timelapse_rounded,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(TimePickerDialog), findsOneWidget);
        expect(pickerText(TimePickerDialog, 'Cancelar'), findsOneWidget);
        expect(pickerText(TimePickerDialog, 'ACEPTAR'), findsOneWidget);
        expect(pickerText(TimePickerDialog, 'AM'), findsNothing);
        expect(pickerText(TimePickerDialog, 'PM'), findsNothing);
        final context = tester.element(find.byType(TimePickerDialog));
        final localizations = MaterialLocalizations.of(context);
        for (final hour in [0, 9, 13, 23]) {
          expect(
            localizations
                .formatTimeOfDay(TimeOfDay(hour: hour, minute: 5))
                .padLeft(5, '0'),
            hourLabel(DateTime(2026, 10, 5, hour, 5)),
          );
        }

        await tester.tap(
          find.byTooltip(localizations.inputTimeModeButtonLabel),
        );
        await tester.pumpAndSettle();
        final inputs = find.descendant(
          of: find.byType(TimePickerDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(inputs.at(0), field == 'Inicio' ? '00' : '23');
        await tester.pump();
        await tester.enterText(inputs.at(1), '05');
        await tester.pump();
        await tester.tap(pickerText(TimePickerDialog, 'ACEPTAR'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(
          find.text(field == 'Inicio' ? '00:05' : '23:05'),
          findsOneWidget,
        );

        await tester.tap(
          find.byIcon(
            field == 'Inicio'
                ? Icons.access_time_rounded
                : Icons.timelapse_rounded,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(pickerText(TimePickerDialog, 'Cancelar'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsNothing);
        expect(
          find.text(field == 'Inicio' ? '00:05' : '23:05'),
          findsOneWidget,
        );
      });
    }
  }
}
