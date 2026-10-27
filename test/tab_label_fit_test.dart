import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/orders/order_widgets.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  setUpAll(() => _font('Inter', 'fonts/Inter.ttf'));

  testWidgets('on a narrow phone the selected "Online order" label is shown whole, shrunk to fit, never cut with …', (t) async {
    t.view.physicalSize = const Size(720, 1400); // 360 points wide
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: const SizedBox.expand(), bottomNavigationBar: PosBottomNav(active: 'online', onTap: (_) {}))));
    final label = t.widget<Text>(find.text('Online order'));
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    expect(find.ancestor(of: find.text('Online order'), matching: find.byType(FittedBox)), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
