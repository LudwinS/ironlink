import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/notify/iron_notice.dart';
import 'package:frontend/core/notify/iron_notify.dart';
import 'package:frontend/core/notify/iron_notify_host.dart';
import 'package:frontend/core/notify/notch_bridge.dart';
import 'package:frontend/core/notify/notice_styles.dart';

IronNotice notice(
  String id, {
  NoticeKind kind = NoticeKind.info,
  Duration? duration,
  List<NoticeAction> actions = const [],
}) => IronNotice(
  id: id,
  kind: kind,
  title: 'Aviso $id',
  duration: duration,
  actions: actions,
);

/// Deja terminar las animaciones de entrada y salida sin esperar a que el
/// aviso se cierre solo (la barra de tiempo del toast nunca «se asienta»).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Al terminar una prueba de widgets no deben quedar temporizadores vivos.
Future<void> finish(WidgetTester tester) async {
  IronNotify.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await settle(tester);
}

void main() {
  final notify = IronNotify.instance;
  setUp(() {
    notify.reset();
    // Tiempo simulado de las pruebas de widgets.
    IronNotify.now = () => TestWidgetsFlutterBinding.instance.clock.now();
  });
  tearDown(notify.reset);

  group('cola', () {
    testWidgets('uno visible a la vez; los demás esperan por llegada', (
      tester,
    ) async {
      notify
        ..add(notice('a'))
        ..add(notice('b'))
        ..add(notice('c'));
      expect(notify.current!.id, 'a');
      expect(notify.queued.map((n) => n.id), ['b', 'c']);
      await tester.pump(const Duration(seconds: 5));
      expect(notify.current!.id, 'b');
      await tester.pump(const Duration(seconds: 5));
      expect(notify.current!.id, 'c');
      await tester.pump(const Duration(seconds: 5));
      expect(notify.current, isNull);
      notify.reset();
    });

    testWidgets('un id repetido no se vuelve a mostrar ni a encolar', (
      tester,
    ) async {
      notify
        ..add(notice('a'))
        ..add(notice('a'))
        ..add(notice('b'))
        ..add(notice('b'));
      expect(notify.current!.id, 'a');
      expect(notify.queued.map((n) => n.id), ['b']);
      notify.reset();
    });

    testWidgets(
      'mayor prioridad: reemplaza y el desplazado vuelve con su tiempo',
      (tester) async {
        notify.add(notice('error', kind: NoticeKind.error));
        await tester.pump(const Duration(seconds: 2));
        notify.add(notice('reunion', kind: NoticeKind.meeting));
        expect(notify.current!.id, 'reunion');
        expect(notify.queued.single.id, 'error');
        notify.remove('reunion');
        expect(notify.current!.id, 'error');
        // Le quedaban 5 de sus 7 segundos.
        await tester.pump(const Duration(milliseconds: 4900));
        expect(notify.current!.id, 'error');
        await tester.pump(const Duration(milliseconds: 200));
        expect(notify.current, isNull);
      },
    );

    testWidgets('un aviso solo informativo desplazado se descarta', (
      tester,
    ) async {
      notify
        ..add(notice('info'))
        ..add(notice('reunion', kind: NoticeKind.meeting));
      expect(notify.current!.id, 'reunion');
      expect(notify.queued, isEmpty);
      notify.reset();
    });

    testWidgets('la cola ordena por prioridad y se limita', (tester) async {
      notify.add(notice('visible', kind: NoticeKind.meeting));
      for (var i = 0; i < IronNotify.maxQueued + 2; i++) {
        notify.add(notice('info$i'));
      }
      notify.add(notice('msg', kind: NoticeKind.message));
      expect(notify.queued.first.id, 'msg');
      expect(notify.queued.length, IronNotify.maxQueued);
      notify.reset();
    });

    testWidgets('pausa y reanuda conservando el tiempo restante', (
      tester,
    ) async {
      notify.add(notice('a'));
      await tester.pump(const Duration(seconds: 3));
      notify.pause();
      await tester.pump(const Duration(minutes: 1));
      expect(notify.current!.id, 'a');
      expect(notify.remaining, const Duration(seconds: 2));
      notify.resume();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(notify.current, isNotNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(notify.current, isNull);
      notify.reset();
    });

    testWidgets('una acción se ejecuta una vez y cierra el aviso', (
      tester,
    ) async {
      var taps = 0;
      notify.add(notice('a', actions: [NoticeAction('Unirse', () => taps++)]));
      notify
        ..runAction('a', 0)
        ..runAction('a', 0);
      expect(taps, 1);
      expect(notify.current, isNull);
      notify.reset();
    });

    testWidgets('cerrar un aviso que ya no está visible no afecta al actual', (
      tester,
    ) async {
      notify
        ..add(notice('a'))
        ..add(notice('b'));
      notify.remove('a');
      notify.remove('a');
      expect(notify.current!.id, 'b');
      notify.reset();
    });

    testWidgets('duración y prioridad por defecto según el tipo', (
      tester,
    ) async {
      final meeting = IronNotice(kind: NoticeKind.meeting, title: 'x');
      final info = IronNotice(kind: NoticeKind.info, title: 'x');
      expect(meeting.duration, const Duration(seconds: 30));
      expect(info.duration, const Duration(seconds: 5));
      expect(meeting.priority, greaterThan(info.priority));
      notify.reset();
    });
  });

  group('estilo por plataforma', () {
    test('cada sistema tiene su presentación', () {
      expect(
        noticeStyleFor(TargetPlatform.macOS, web: false),
        NoticeStyle.notch,
      );
      expect(
        noticeStyleFor(TargetPlatform.iOS, web: false),
        NoticeStyle.island,
      );
      expect(
        noticeStyleFor(TargetPlatform.android, web: false),
        NoticeStyle.headsUp,
      );
      expect(
        noticeStyleFor(TargetPlatform.windows, web: false),
        NoticeStyle.toast,
      );
      expect(
        noticeStyleFor(TargetPlatform.linux, web: false),
        NoticeStyle.toast,
      );
      expect(
        noticeStyleFor(TargetPlatform.macOS, web: true, width: 1280),
        NoticeStyle.toast,
      );
      expect(
        noticeStyleFor(TargetPlatform.iOS, web: true, width: 390),
        NoticeStyle.headsUp,
      );
    });
  });

  group('anfitrión', () {
    Future<void> pumpHost(
      WidgetTester tester,
      NoticeStyle style, {
      double topPadding = 0,
      bool disableAnimations = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewPadding: EdgeInsets.only(top: topPadding),
              padding: EdgeInsets.only(top: topPadding),
              disableAnimations: disableAnimations,
            ),
            child: IronNotifyHost(style: style, child: child!),
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
    }

    for (final style in NoticeStyle.values) {
      testWidgets('$style muestra el aviso y su acción funciona', (
        tester,
      ) async {
        var joined = 0;
        await pumpHost(tester, style, topPadding: 59);
        IronNotify.show(
          IronNotice(
            id: 'r',
            kind: NoticeKind.meeting,
            title: 'Ana inició la Daily Scrum',
            initials: 'AN',
            actions: [
              NoticeAction('Ignorar', () {}),
              NoticeAction('Unirse', () => joined++, primary: true),
            ],
          ),
        );
        await settle(tester);
        expect(find.text('Ana inició la Daily Scrum'), findsOneWidget);
        expect(find.text('AN'), findsOneWidget);
        await tester.tap(find.text('Unirse'));
        await settle(tester);
        expect(joined, 1);
        expect(find.text('Ana inició la Daily Scrum'), findsNothing);
        await finish(tester);
      });
    }

    testWidgets('al cerrar, entra el siguiente de la cola', (tester) async {
      await pumpHost(tester, NoticeStyle.toast);
      IronNotify.show(notice('a', duration: const Duration(minutes: 1)));
      IronNotify.show(notice('b', duration: const Duration(minutes: 1)));
      await settle(tester);
      expect(find.text('Aviso a'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await settle(tester);
      expect(find.text('Aviso a'), findsNothing);
      expect(find.text('Aviso b'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('con «Reducir movimiento» también se muestra', (tester) async {
      await pumpHost(tester, NoticeStyle.headsUp, disableAnimations: true);
      IronNotify.show(notice('a'));
      await settle(tester);
      expect(find.text('Aviso a'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('se anuncia a los lectores de pantalla', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpHost(tester, NoticeStyle.toast);
      IronNotify.show(notice('a'));
      await settle(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('Aviso a'))),
        isSemantics(isLiveRegion: true),
      );
      await finish(tester);
      semantics.dispose();
    });

    testWidgets('la isla solo con margen de Dynamic Island', (tester) async {
      for (final (padding, expected) in [(59.0, true), (47.0, false)]) {
        late bool island;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(viewPadding: EdgeInsets.only(top: padding)),
            child: Builder(
              builder: (context) {
                island = IslandNotice.hasIsland(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(island, expected, reason: 'margen $padding');
      }
    });
  });

  group('panel nativo de macOS', () {
    const channel = MethodChannel('ironlink/notch');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> pumpNative(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => IronNotifyHost(
          style: NoticeStyle.notch,
          bridge: NotchBridge(notify, channel: channel),
          child: child!,
        ),
        home: const SizedBox(),
      ),
    );

    testWidgets('entrega el aviso al panel y atiende sus respuestas', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      var joined = 0;
      await pumpNative(tester);
      IronNotify.show(
        IronNotice(
          id: 'r',
          kind: NoticeKind.meeting,
          context: 'Reunión en curso · InnovaSoft',
          title: 'Ana inició la Daily Scrum',
          initials: 'AN',
          actions: [NoticeAction('Unirse', () => joined++, primary: true)],
        ),
      );
      await settle(tester);
      final show = calls.single;
      expect(show.method, 'show');
      final args = (show.arguments as Map).cast<String, Object?>();
      expect(args['id'], 'r');
      expect(args['context'], 'REUNIÓN EN CURSO · INNOVASOFT');
      expect(args['symbol'], 'video');
      expect(args['actions'], [
        {'label': 'Unirse', 'primary': true},
      ]);
      // No se dibuja nada en Flutter: lo dibuja el panel.
      expect(find.text('Ana inició la Daily Scrum'), findsNothing);

      // El puntero encima pausa; el botón ejecuta la acción y se oculta.
      Future<void> fromNative(String method, Map<String, Object?> args) =>
          messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, args),
            ),
            (_) {},
          );
      await fromNative('hover', {'id': 'r', 'inside': true});
      expect(notify.paused, isTrue);
      await fromNative('action', {'id': 'r', 'index': 0});
      await settle(tester);
      expect(joined, 1);
      expect(calls.last.method, 'hide');
      await finish(tester);
    });

    testWidgets('sin panel nativo se dibuja la versión Flutter', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw MissingPluginException(),
      );
      await pumpNative(tester);
      IronNotify.show(notice('a'));
      await settle(tester);
      expect(find.byType(NotchNotice), findsOneWidget);
      expect(find.text('Aviso a'), findsOneWidget);
      await finish(tester);
    });
  });

  test('ningún aviso usa ya SnackBar', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('showSnackBar'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}
