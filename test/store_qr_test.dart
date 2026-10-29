import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/settings/store_qr.dart';
import 'package:vinii_pos/ui/theme.dart';

// The store's payment QR (founder, 29 Oct 2026): added during store setup, changed in Settings, shown when a bill is paid by UPI.

Future<void> show(WidgetTester t, Widget w) async {
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: Center(child: w))));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no QR yet: the owner uploads a photo, which is saved and then shown with Change and Remove', (t) async {
    StoreQr? saved;
    PickedDocument? sent;
    await show(
      t,
      StoreQrCard(
        canEdit: true,
        load: () async => saved,
        pick: () async => PickedDocument(name: 'qr.png', bytes: Uint8List(10), contentType: 'image/png'),
        save: (f) async {
          sent = f;
          saved = (url: 'https://qr.test/shop.png', pdf: false);
        },
        remove: () async => saved = null,
      ),
    );
    expect(find.byKey(const ValueKey('store-qr-empty')), findsOneWidget);
    expect(find.text('Upload QR'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('store-qr-upload')));
    await t.pumpAndSettle();
    expect(sent?.contentType, 'image/png');
    expect(find.byKey(const ValueKey('store-qr-image')), findsOneWidget);
    expect(find.text('Change QR'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('store-qr-remove')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('store-qr-empty')), findsOneWidget);
  });

  testWidgets('a PDF is refused: the QR must be a photo', (t) async {
    var saves = 0;
    await show(
      t,
      StoreQrCard(
        canEdit: true,
        load: () async => null,
        pick: () async => PickedDocument(name: 'qr.pdf', bytes: Uint8List(10), contentType: 'application/pdf'),
        save: (_) async => saves++,
      ),
    );
    await t.tap(find.byKey(const ValueKey('store-qr-upload')));
    await t.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('Choose a photo of your QR (JPG or PNG).'), findsOneWidget);
  });

  testWidgets('read-only on the bill: the picture, no buttons', (t) async {
    await show(t, StoreQrCard(big: true, load: () async => (url: 'https://qr.test/shop.png', pdf: false)));
    expect(find.byKey(const ValueKey('store-qr-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('store-qr-upload')), findsNothing);
  });
}
