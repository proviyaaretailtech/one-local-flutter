import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ui/barcode_scanner.dart';

void main() {
  testWidgets('the scanner fills the phone screen: the scan window sits in the middle, close and torch at the top', (t) async {
    t.view.physicalSize = const Size(780, 1688); // a 390 x 844 phone
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: BarcodeScannerScreen()));
    await t.pump(const Duration(milliseconds: 300));

    final window = t.getRect(find.byKey(const ValueKey('scan-window')));
    expect(window.center.dx, closeTo(195, 1));
    expect(window.center.dy, closeTo(422, 1));
    expect(window.width, closeTo(312, 1));
    expect(window.height, closeTo(312 * 0.6, 1));
    expect(t.getRect(find.byTooltip('Close')).top, lessThan(80));
    expect(t.getRect(find.byTooltip('Torch')).top, lessThan(80));
    expect(t.getRect(find.text('Point the camera at the barcode')).bottom, greaterThan(700));
    expect(find.text('Type the code instead'), findsNothing); // only when the caller offers typing
  });

  testWidgets('"Type the code instead" closes the camera answering an empty code', (t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    String? answer = 'not yet';
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () async => answer = await scanBarcodeOrType(c), child: const Text('go')))));
    await t.tap(find.text('go'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(BarcodeScannerScreen), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('scan-type-instead')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(answer, '');
  });
}
