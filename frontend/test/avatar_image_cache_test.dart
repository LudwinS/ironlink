import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/core/widgets/avatar_image_cache.dart';
import 'package:frontend/core/widgets/avatar_viewer.dart';
import 'package:frontend/core/widgets/user_avatar.dart';
import 'package:image/image.dart' as img;

void main() {
  final photo =
      'data:image/png;base64,${base64Encode(img.encodePng(img.Image(width: 2, height: 2)))}';

  test('equal data URI strings reuse the provider and decoded bytes', () {
    final cache = AvatarImageCache();
    final first = cache.providerFor(photo) as MemoryImage;
    final second = cache.providerFor(String.fromCharCodes(photo.codeUnits));
    expect(second, same(first));
    expect((second as MemoryImage).bytes, same(first.bytes));
    expect(cache.providerFor('  $photo  '), same(first));
  });

  test('the LRU is bounded and retains recently accessed photos', () {
    final cache = AvatarImageCache(capacity: 2);
    final first = cache.providerFor(photo);
    final other = photo.replaceFirst('image/png', 'image/jpeg');
    final evicted = cache.providerFor(other);
    expect(cache.providerFor(photo), same(first));
    cache.providerFor(photo.replaceFirst('image/png', 'image/webp'));
    expect(cache.providerFor(photo), same(first));
    expect(cache.providerFor(other), isNot(same(evicted)));
  });

  test('network providers are reused and invalid photos return null', () {
    final cache = AvatarImageCache();
    const url = 'https://example.com/avatar.png';
    expect(cache.providerFor(url), isA<NetworkImage>());
    expect(cache.providerFor(url), same(cache.providerFor(url)));
    expect(cache.providerFor(null), isNull);
    expect(cache.providerFor('data:image/png;base64,%%%'), isNull);
    expect(cache.providerFor('file:///avatar.png'), isNull);
  });

  test('the viewer shares the avatar provider and its bytes', () async {
    final provider = AvatarImageCache.shared.providerFor(photo) as MemoryImage;
    final loaded = await AvatarImage.load(photo);
    expect(loaded!.provider, same(provider));
    expect(loaded.bytes, same(provider.bytes));
  });

  Widget avatar(String? url, {String name = 'Ana Rivas'}) => MaterialApp(
    home: Scaffold(
      body: UserAvatar(name: name, avatarUrl: url, userId: 'u1'),
    ),
  );

  testWidgets('parent and presence rebuilds keep the provider and frame', (
    tester,
  ) async {
    addTearDown(LivePresence.clear);
    await tester.pumpWidget(avatar(photo));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final provider = tester.widget<Image>(find.byType(Image)).image;
    final raw = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(raw, isNotNull);
    // Incluso tras expulsarlo de la caché, el avatar montado lo conserva.
    for (var i = 0; i < 65; i++) {
      AvatarImageCache.shared.providerFor('https://example.com/$i.png');
    }
    await tester.pumpWidget(avatar(photo, name: 'Ana Actualizada'));
    LivePresence.values.value = {'u1': 'available'};
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, same(provider));
    expect(image.gaplessPlayback, isTrue);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(raw));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing or removing a photo updates the avatar', (
    tester,
  ) async {
    await tester.pumpWidget(avatar(photo));
    final first = tester.widget<Image>(find.byType(Image)).image;
    await tester.pumpWidget(
      avatar(photo.replaceFirst('image/png', 'image/jpeg')),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isNot(same(first)));
    expect(image.gaplessPlayback, isTrue);
    await tester.pumpWidget(avatar(null));
    expect(find.byType(Image), findsNothing);
    expect(find.text('AR'), findsOneWidget);
  });

  testWidgets(
    'network avatars retain their provider and use gapless playback',
    (tester) async {
      const url = 'https://example.com/avatar.png';
      await tester.pumpWidget(avatar(url));
      final first = tester.widget<Image>(find.byType(Image));
      expect(first.image, isA<NetworkImage>());
      expect(first.gaplessPlayback, isTrue);
      await tester.pumpWidget(avatar(url, name: 'Ana Actualizada'));
      expect(tester.widget<Image>(find.byType(Image)).image, same(first.image));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('viewer rebuilds reuse its provider with gapless playback', (
    tester,
  ) async {
    Widget viewer(String name) => MaterialApp(
      home: AvatarViewer(name: name, avatarUrl: photo),
    );
    await tester.pumpWidget(viewer('Ana'));
    await tester.pumpAndSettle();
    final first = tester.widget<Image>(find.byType(Image));
    expect(first.gaplessPlayback, isTrue);
    await tester.pumpWidget(viewer('Ana Rivas'));
    await tester.pumpAndSettle();
    expect(tester.widget<Image>(find.byType(Image)).image, same(first.image));
    expect(tester.takeException(), isNull);
  });
}
