import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/core/widgets/user_avatar.dart';
import 'package:frontend/features/nodos/data/live_updates_controller.dart';
import 'package:frontend/features/nodos/presentation/widgets/live_updates_banner.dart';

Map<String, dynamic> meeting(String id) => {
  'id': id,
  'node_id': 'node',
  'title': 'Reunión $id',
  'creator_id': 'moderator',
  'creator_name': 'Moderador',
  'started_at': '2026-09-30 17:45:00.123456+00',
};
Map<String, dynamic> snapshot({
  String state = 'available',
  List<String> meetings = const [],
}) => {
  'type': 'live_snapshot',
  'user_id': 'me',
  'presence': {'me': state, 'peer': 'in_call'},
  'meetings': [for (final id in meetings) meeting(id)],
  'truncated': false,
};

void main() {
  late LiveUpdatesController live;
  setUp(
    () => live = LiveUpdatesController(
      ticket: () async => throw StateError('offline'),
    ),
  );
  tearDown(() {
    live.dispose();
  });
  test(
    'server presence is separate from manual status and transitions are live',
    () {
      expect(live.applySnapshot(snapshot(state: 'in_call')), true);
      expect(LivePresence.values.value['me'], 'in_call');
      expect(LivePresence.label('in_call'), 'En llamada');
      live.applySnapshot(snapshot());
      expect(LivePresence.values.value['me'], 'available');
      expect(LivePresence.label(null), 'Sin sincronizar');
    },
  );
  test(
    'meeting creates a real join target and handles database timestamp format',
    () {
      expect(live.applySnapshot(snapshot(meetings: ['one'])), true);
      final room = live.pending.single.toReunion();
      expect(room.id, 'one');
      expect(room.nodoId, 'node');
      expect(room.rtcEstado, 'active');
      expect(room.fechaInicio, DateTime.utc(2026, 9, 30, 17, 45, 0, 123, 456));
    },
  );
  test(
    'discarded active notification is not replayed on identical or reconnected snapshots',
    () {
      live.applySnapshot(snapshot(meetings: ['one']));
      live.dismiss('one');
      live.applySnapshot(snapshot(meetings: ['one']));
      expect(live.pending, isEmpty);
      live.applySnapshot(snapshot(meetings: ['one', 'two']));
      expect(live.pending.single.id, 'two');
      live.applySnapshot(snapshot());
      expect(live.meetings, isEmpty);
    },
  );
  test(
    'ended or inaccessible meetings and members are removed by replacement snapshots',
    () {
      live.applySnapshot(snapshot(meetings: ['one']));
      final update = snapshot();
      update['presence'] = {'me': 'available'};
      live.applySnapshot(update);
      expect(live.pending, isEmpty);
      expect(LivePresence.values.value.containsKey('peer'), false);
    },
  );
  test(
    'malformed or cross-account snapshots never partially overwrite data',
    () {
      live.applySnapshot(snapshot(meetings: ['one']));
      final malformed = snapshot(meetings: ['two']);
      malformed['presence'] = {'me': 'invented'};
      expect(live.applySnapshot(malformed), false);
      expect(live.meetings.single.id, 'one');
      final cross = snapshot();
      cross['user_id'] = 'other-account';
      expect(live.applySnapshot(cross), false);
      expect(live.userId, 'me');
      expect(live.applySnapshot(snapshot(meetings: ['one', 'one'])), false);
      final missing = snapshot();
      missing['presence'] = {};
      expect(live.applySnapshot(missing), false);
    },
  );
  test(
    'bounded snapshot rejects oversized meetings and clears account data on disposal',
    () {
      expect(
        live.applySnapshot(snapshot(meetings: List.generate(51, (i) => '$i'))),
        false,
      );
      live.applySnapshot(snapshot(meetings: ['one']));
      live.dispose();
      expect(LivePresence.values.value, isEmpty);
      expect(LivePresence.selfId, null);
      expect(live.applySnapshot(snapshot()), false);
      live = LiveUpdatesController();
    },
  );
  test(
    'accepted friendship and sent requests change the snapshot (IRL-FULL-002)',
    () {
      // Antes de aceptar: una solicitud enviada, ninguna amistad.
      final before = snapshot();
      before['friends'] = {
        'pending': 0,
        'unread_messages': 0,
        'accepted': 0,
        'sent': 1,
      };
      expect(live.applySnapshot(before), true);
      expect(live.sentFriendRequests, 1);
      expect(live.acceptedFriends, 0);
      // La otra persona acepta: quien envió lo ve sin pulsar Actualizar.
      final after = snapshot();
      after['friends'] = {
        'pending': 0,
        'unread_messages': 0,
        'accepted': 1,
        'sent': 0,
      };
      live.applySnapshot(after);
      expect(live.acceptedFriends, 1);
      expect(live.sentFriendRequests, 0);
      // Un servidor anterior sin esos campos no rompe la instantánea.
      expect(live.applySnapshot(snapshot()), true);
      expect(live.acceptedFriends, 0);
    },
  );
  testWidgets(
    'ticket failure clears stale state, backs off and cancels retry on dispose',
    (tester) async {
      var attempts = 0;
      live.dispose();
      live = LiveUpdatesController(
        ticket: () async {
          attempts++;
          throw StateError('unavailable');
        },
      );
      live.applySnapshot(snapshot(meetings: ['one']));
      await live.start();
      expect(live.connected, false);
      expect(live.pending, isEmpty);
      expect(LivePresence.values.value, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(attempts, 2);
      live.dispose();
      live = LiveUpdatesController();
      await tester.pump(const Duration(seconds: 40));
      expect(attempts, 2);
    },
  );
  testWidgets('late ticket cannot reopen or restore a logged-out account', (
    tester,
  ) async {
    final pending = Completer<String>();
    live.dispose();
    live = LiveUpdatesController(ticket: () => pending.future);
    final start = live.start();
    live.dispose();
    pending.complete('must-not-connect');
    await start;
    expect(LivePresence.values.value, isEmpty);
    live = LiveUpdatesController();
  });
  testWidgets(
    'heartbeat renews freshness; silence clears presence and join targets',
    (tester) async {
      live.applySnapshot(snapshot(meetings: ['one']));
      await tester.pump(const Duration(seconds: 15));
      live.receive({'type': 'live_heartbeat', 'user_id': 'me'});
      await tester.pump(const Duration(seconds: 15));
      expect(live.connected, true);
      expect(live.pending.single.id, 'one');
      live.receive({'type': 'live_heartbeat', 'user_id': 'other-account'});
      await tester.pump(const Duration(seconds: 6));
      expect(live.connected, false);
      expect(live.pending, isEmpty);
      expect(LivePresence.values.value, isEmpty);
      live.dispose();
      live = LiveUpdatesController();
    },
  );
  testWidgets(
    'avatar and label react to presence without rebuilding their parent',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UserAvatar(name: 'Usuario', userId: 'peer'),
                LivePresenceLabel(userId: 'peer'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Sin sincronizar'), findsOneWidget);
      live.applySnapshot(snapshot());
      await tester.pump();
      expect(find.text('En llamada'), findsOneWidget);
      LivePresence.values.value = {};
      await tester.pump();
      expect(find.text('Sin sincronizar'), findsOneWidget);
      live.dispose();
      live = LiveUpdatesController();
    },
  );
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets(
      'notification fits $width px at 130 percent text and joins selected meeting',
      (tester) async {
        tester.view.physicalSize = Size(width, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        live.applySnapshot(snapshot(meetings: ['one', 'two']));
        LiveMeeting? joined;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  LiveUpdatesBanner(live: live, onJoin: (m) => joined = m),
                ],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Unirse ahora'));
        expect(joined?.id, 'one');
        await tester.tap(find.byTooltip('Descartar aviso'));
        await tester.pump();
        expect(live.pending.single.id, 'two');
        live.applySnapshot(snapshot(state: 'in_call', meetings: ['two']));
        await tester.pump();
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Unirse ahora'),
              )
              .onPressed,
          null,
        );
        live.dispose();
        live = LiveUpdatesController();
      },
    );
  }
}
