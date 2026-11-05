// Settings → Devices for a restaurant (0638): the printers for receipts, kitchen tickets (KOT) and barcode labels; add, change, default,
// test print and delete. The database checks every rule again; these tests check what the screens send and show. Test print (4 Nov 2026)
// sends a network printer the ESC/POS test slip and says exactly what happened; Bluetooth and USB are not supported by this build.
import 'dart:convert';
import 'dart:io' show OSError, SocketException;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/devices/devices_api.dart' show sendRawToPrinter;
import 'package:vinii_pos/settings/rst_devices_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

Map<String, dynamic> _printer(String id, String name, String type, {String conn = 'bluetooth', bool dflt = false, String? tested, List<String> stations = const []}) => {
      'id': id, 'name': name, 'type': type, 'connection': conn, 'address': conn == 'lan' ? '192.168.1.50' : null, 'model': 'Epson TM-T82',
      'paper_mm': 80, 'label_size': type == 'label' ? '50x25' : null, 'copies': 1, 'auto_cut': true, 'is_default': dflt, 'tested_at': tested, 'stations': stations,
    };

class Fake {
  Fake({List<Map<String, dynamic>>? printers}) : printers = printers ?? [];
  final List<Map<String, dynamic>> printers;
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> last(String fn) => calls.lastWhere((c) => c.$1 == fn).$2;
  late final api = RstDevicesApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, b));
    final answer = switch (fn) {
      'rst_devices_list' => {'printers': printers, 'count': printers.length, 'tested': printers.where((p) => p['tested_at'] != null).length},
      'rst_printer_save' => () {
          printers.removeWhere((p) => p['id'] == b['id']);
          final p = {...b, 'id': b['id'] ?? 'new-${printers.length}', 'stations': [], 'is_default': b['is_default'] ?? false};
          printers.add(p);
          return p;
        }(),
      'rst_printer_delete' => () {
          printers.removeWhere((p) => p['id'] == b['id']);
          return {'id': b['id'], 'deleted': true};
        }(),
      'rst_printer_tested' => () {
          final p = printers.firstWhere((p) => p['id'] == b['id']);
          p['tested_at'] = '2026-11-01T10:00:00Z';
          return p;
        }(),
      'pos_print_log' => {'logged': true},
      _ => <String, dynamic>{},
    };
    return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(800, 2600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: w));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no printers: the counts, the three kinds with "None yet", and Add printer', (t) async {
    await show(t, RstDevicesScreen(api: Fake().api));
    expect(find.text('0 printers'), findsOneWidget);
    expect(find.text('0 tested OK'), findsOneWidget);
    for (final s in ['Receipt printers', 'Kitchen printers (KOT)', 'Barcode label printers']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.byKey(const ValueKey('devices-none-receipt')), findsOneWidget);
    expect(find.textContaining('Labels print through the print dialog'), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-add')), findsOneWidget);
  });

  testWidgets('add a receipt printer by Bluetooth: name, model, 58 mm, 2 copies, default; listed after saving, and it says Bluetooth does not print yet', (t) async {
    final f = Fake();
    await show(t, RstDevicesScreen(api: f.api));
    await tapKey(t, 'devices-add');
    expect(find.text('Add printer'), findsWidgets);
    expect(find.text("Printer's IP address"), findsOneWidget, reason: 'a new printer starts as a network printer');
    await t.enterText(find.byKey(const ValueKey('printer-name')), 'Counter printer');
    await tapKey(t, 'printer-conn-bluetooth');
    expect(find.byKey(const ValueKey('printer-conn-unsupported')), findsOneWidget);
    expect(find.textContaining('Bluetooth printers are not supported yet.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('printer-address')), 'RPP02N');
    await t.enterText(find.byKey(const ValueKey('printer-model')), 'Epson TM-T82');
    await tapKey(t, 'printer-paper-58');
    await tapKey(t, 'printer-copies-more');
    await tapKey(t, 'printer-default');
    await tapKey(t, 'printer-save');
    expect(f.last('rst_printer_save'), {'name': 'Counter printer', 'type': 'receipt', 'connection': 'bluetooth', 'address': 'RPP02N', 'model': 'Epson TM-T82',
      'paper_mm': 58, 'copies': 2, 'auto_cut': true, 'is_default': true});
    expect(find.text('Counter printer'), findsOneWidget, reason: 'back on Devices, listed');
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('1 printer'), findsOneWidget);
    expect(find.textContaining('Saved. Bluetooth printers are not supported yet.'), findsOneWidget);
  });

  testWidgets('a kitchen printer on Wi-Fi needs its IP address', (t) async {
    final f = Fake();
    await show(t, RstPrinterFormScreen(api: f.api, kind: 'kot'));
    await t.enterText(find.byKey(const ValueKey('printer-name')), 'Hot kitchen');
    await tapKey(t, 'printer-conn-lan');
    expect(find.text("Printer's IP address"), findsOneWidget);
    await tapKey(t, 'printer-save');
    expect(find.textContaining("Enter the printer's IP address"), findsOneWidget);
    expect(f.calls.where((c) => c.$1 == 'rst_printer_save'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('printer-address')), '192.168.1.256');
    await tapKey(t, 'printer-save');
    expect(find.textContaining('The IP address looks wrong'), findsOneWidget);
    expect(f.calls.where((c) => c.$1 == 'rst_printer_save'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('printer-address')), '192.168.1.50:99999');
    await tapKey(t, 'printer-save');
    expect(find.textContaining('between 1 and 65535'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('printer-address')), '192.168.1.50');
    await tapKey(t, 'printer-save');
    expect(f.last('rst_printer_save')['type'], 'kot');
    expect(f.last('rst_printer_save')['address'], '192.168.1.50');
  });

  testWidgets('a barcode label printer: label sizes instead of paper, no auto cut, the phone\'s print service sends no address', (t) async {
    final f = Fake();
    await show(t, RstPrinterFormScreen(api: f.api));
    await t.enterText(find.byKey(const ValueKey('printer-name')), 'Label printer');
    await tapKey(t, 'printer-type-label');
    expect(find.text('Label size (mm)'), findsOneWidget);
    expect(find.text('Paper width'), findsNothing);
    expect(find.byKey(const ValueKey('printer-cut')), findsNothing);
    expect(find.text('Default for labels'), findsOneWidget);
    await tapKey(t, 'printer-label-75x50');
    await tapKey(t, 'printer-conn-system');
    await tapKey(t, 'printer-save');
    final b = f.last('rst_printer_save');
    expect((b['type'], b['label_size'], b['connection'], b.containsKey('address'), b.containsKey('paper_mm')), ('label', '75x50', 'system', false, false));
  });

  testWidgets('a printer opens to change it; Delete asks first and takes it off the list', (t) async {
    final f = Fake(printers: [_printer('p1', 'Counter printer', 'receipt', dflt: true), _printer('p2', 'Hot kitchen', 'kot', conn: 'lan', stations: ['Main kitchen'])]);
    await show(t, RstDevicesScreen(api: f.api));
    expect(find.textContaining('192.168.1.50'), findsOneWidget);
    expect(find.textContaining('Main kitchen'), findsOneWidget, reason: 'the kitchen stations that print to it');
    await tapKey(t, 'printer-p2');
    expect(find.text('Edit printer'), findsWidgets);
    expect(t.widget<TextField>(find.byKey(const ValueKey('printer-name'))).controller!.text, 'Hot kitchen');
    await tapKey(t, 'printer-delete');
    expect(find.text('Delete this printer?'), findsOneWidget);
    await tapKey(t, 'printer-delete-yes');
    expect(f.last('rst_printer_delete'), {'id': 'p2'});
    expect(find.text('Hot kitchen'), findsNothing);
    expect(find.text('1 printer'), findsOneWidget);
  });

  // founder, 3 Nov 2026: Test print marked a printer tested even when the print dialog was cancelled
  Future<(Fake, List<String>)> testPrint(WidgetTester t, {required bool printed, String? answer}) async {
    final f = Fake(printers: [_printer('p1', 'Counter printer', 'receipt', conn: 'system', dflt: true)]);
    final sent = <String>[];
    final before = printTestPagePdf;
    printTestPagePdf = (Uint8List pdf, String name) async {
      sent.add(name);
      return printed;
    };
    addTearDown(() => printTestPagePdf = before);
    await show(t, RstDevicesScreen(api: f.api));
    expect(find.textContaining('Not tested yet'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('printer-test-p1')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pumpAndSettle();
    if (answer != null) {
      expect(find.text('Did the test page print?'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.byKey(ValueKey('test-printed-$answer')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pumpAndSettle();
    }
    return (f, sent);
  }

  testWidgets("Test print on the phone's print service: the test page goes to print; it is marked tested once you say it printed", (t) async {
    final (f, sent) = await testPrint(t, printed: true, answer: 'yes');
    expect(sent, ['Test Counter printer.pdf']);
    expect(f.last('rst_printer_tested'), {'id': 'p1'});
    expect(f.last('pos_print_log'), {'kind': 'test', 'outcome': 'printed', 'printer_id': 'p1'});
    expect(find.text('1 tested OK'), findsOneWidget);
  });

  testWidgets('Test print cancelled in the print dialog: not marked tested, and it says so', (t) async {
    final (f, sent) = await testPrint(t, printed: false);
    expect(sent, ['Test Counter printer.pdf']);
    expect(find.text('Did the test page print?'), findsNothing);
    expect(f.calls.where((c) => c.$1 == 'rst_printer_tested'), isEmpty);
    expect(find.text('Not printed. The printer is not marked as tested.'), findsOneWidget);
    expect(find.text('0 tested OK'), findsOneWidget);
  });

  testWidgets('Test print sent but nothing came out (No): not marked tested', (t) async {
    final (f, _) = await testPrint(t, printed: true, answer: 'no');
    expect(f.calls.where((c) => c.$1 == 'rst_printer_tested'), isEmpty);
    expect(f.last('pos_print_log'), containsPair('outcome', 'failed'));
    expect(find.text('Not marked as tested. Check the printer and its connection, then try again.'), findsOneWidget);
  });

  // 4 Nov 2026: a network printer gets the test slip straight to its port, no print dialog and no "did it print?"
  Future<(Fake, List<(String, List<int>)>)> lanTest(WidgetTester t, {Object? error}) async {
    final f = Fake(printers: [_printer('p2', 'Hot kitchen', 'kot', conn: 'lan')]);
    final raw = <(String, List<int>)>[];
    final before = sendRawToPrinter, beforePdf = printTestPagePdf;
    sendRawToPrinter = (host, port, bytes) async {
      if (error != null) throw error;
      raw.add(('$host:$port', bytes));
    };
    printTestPagePdf = (pdf, name) async => fail('a network printer needs no print dialog');
    addTearDown(() {
      sendRawToPrinter = before;
      printTestPagePdf = beforePdf;
    });
    await show(t, RstDevicesScreen(api: f.api));
    await tapKey(t, 'printer-test-p2');
    return (f, raw);
  }

  testWidgets('Test print on a network printer: the ESC/POS test slip goes to its port; marked tested; it says where it printed', (t) async {
    final (f, raw) = await lanTest(t);
    expect(raw.single.$1, '192.168.1.50:9100');
    expect(String.fromCharCodes(raw.single.$2), contains('OneLocal test print'));
    expect(find.text('Did the test page print?'), findsNothing);
    expect(f.last('rst_printer_tested'), {'id': 'p2'});
    expect(f.last('pos_print_log'), {'kind': 'test', 'outcome': 'printed', 'printer_id': 'p2'});
    expect(find.text('Test page printed on Hot kitchen. Marked as tested.'), findsOneWidget);
  });

  testWidgets('Test print on a network printer that does not answer: why, not marked tested, logged as failed', (t) async {
    final (f, _) = await lanTest(t, error: const SocketException('Connection failed', osError: OSError('Connection refused', 61)));
    expect(f.calls.where((c) => c.$1 == 'rst_printer_tested'), isEmpty);
    expect(find.text('Test page not printed: Hot kitchen at 192.168.1.50 did not answer (connection refused). Not marked as tested.'), findsOneWidget);
    expect(f.last('pos_print_log'), allOf(containsPair('outcome', 'failed'), containsPair('detail', '192.168.1.50 did not answer (connection refused)')));
  });

  testWidgets('Test print on a Bluetooth printer: not supported yet, said plainly; nothing printed or marked', (t) async {
    final f = Fake(printers: [_printer('p1', 'Counter printer', 'receipt')]);
    final before = printTestPagePdf;
    printTestPagePdf = (pdf, name) async => fail('nothing goes to the print dialog');
    addTearDown(() => printTestPagePdf = before);
    await show(t, RstDevicesScreen(api: f.api));
    await tapKey(t, 'printer-test-p1');
    expect(find.textContaining('Bluetooth printers are not supported yet.'), findsOneWidget);
    expect(f.calls.where((c) => c.$1 == 'rst_printer_tested'), isEmpty);
    expect(f.last('pos_print_log'), containsPair('outcome', 'failed'));
  });
}
