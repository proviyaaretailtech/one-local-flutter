import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/devices/device_manager_screen.dart';
import 'package:vinii_pos/devices/devices_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show ignoreOverflow, toast;

// Settings → Devices (founder, 31 Oct 2026): the store's printers by job, add / edit / remove, and a test print each.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

class Fake {
  final requests = <http.Request>[];
  var printers = <Map<String, dynamic>>[
    {'id': 'p1', 'name': 'Counter printer', 'printer_type': 'receipt', 'connection': 'lan', 'address': '192.168.1.50:9100', 'paper_mm': 80, 'label_size': '',
      'copies': 1, 'auto_cut': true, 'is_default': true, 'last_test_at': null, 'last_test_ok': null, 'last_test_note': ''},
    {'id': 'p2', 'name': 'Label printer', 'printer_type': 'label', 'connection': 'bluetooth', 'address': '', 'paper_mm': 80, 'label_size': '50x25',
      'copies': 1, 'auto_cut': true, 'is_default': true, 'last_test_at': '2026-10-01T10:00:00Z', 'last_test_ok': false, 'last_test_note': 'Did not print'},
  ];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
  Iterable<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn);
  late final api = DevicesApi(baseUrl: 'http://t.test', accessToken: () => 't', client: MockClient((r) async {
    requests.add(r);
    final b = jsonDecode(r.body.isEmpty ? '{}' : r.body) as Map<String, dynamic>;
    return switch (fnOf(r)) {
      'dev_printers' => ok({'printers': printers, 'can_edit': true, 'kind': 'retail'}),
      'dev_printer_save' => ok({...b, 'id': b['id'] ?? 'p9', 'address': b['address'] ?? ''}),
      'dev_printer_remove' => ok({'removed': true}),
      'dev_printer_tested' => ok({...printers.firstWhere((p) => p['id'] == b['id']), 'last_test_at': DateTime.now().toIso8601String(), 'last_test_ok': b['ok'], 'last_test_note': b['note'] ?? ''}),
      _ => http.Response('{}', 404),
    };
  }));
}

Future<void> show(WidgetTester t, Widget w) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 2400);
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
  testWidgets('printers by job: receipts and barcode labels (no kitchen for a store); status and default shown', (t) async {
    final f = Fake();
    await show(t, DeviceManagerScreen(api: f.api, store: 'Sharma General Store'));
    expect(find.text('Receipt printers'), findsOneWidget);
    expect(find.text('Barcode label printers'), findsOneWidget);
    expect(find.text('Kitchen printers (KOT)'), findsNothing);
    expect(find.textContaining('192.168.1.50:9100'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('printer-status-p1')), matching: find.text('Not tested yet')), findsOneWidget);
    expect(find.textContaining('Test failed'), findsOneWidget);
    expect(find.text('Default'), findsNWidgets(2));
  });

  testWidgets('test print, network printer: a slip straight to its port, no dialog; the result is saved', (t) async {
    final f = Fake();
    String? sentTo;
    List<int>? sent;
    final real = sendRawToPrinter;
    sendRawToPrinter = (host, port, bytes) async {
      sentTo = '$host:$port';
      sent = bytes;
    };
    addTearDown(() => sendRawToPrinter = real);
    await show(t, DeviceManagerScreen(api: f.api, store: 'Sharma General Store'));
    await tapKey(t, 'printer-test-p1');
    expect(sentTo, '192.168.1.50:9100');
    expect(String.fromCharCodes(sent!), contains('SHARMA GENERAL STORE'));
    expect(sent!.sublist(sent!.length - 4), [0x1D, 0x56, 0x42, 0x00]); // auto cut
    expect(f.body('dev_printer_tested'), {'id': 'p1', 'ok': true, 'note': 'Printed over the network'});
    expect(find.textContaining('Tested OK'), findsOneWidget);
  });

  testWidgets('test print, a network printer that does not answer: saved as failed, and says what to check', (t) async {
    final f = Fake();
    final real = sendRawToPrinter;
    sendRawToPrinter = (host, port, bytes) async => throw Exception('refused');
    addTearDown(() => sendRawToPrinter = real);
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-test-p1');
    expect(f.body('dev_printer_tested')['ok'], false);
    expect(f.body('dev_printer_tested')['note'], contains('No answer from 192.168.1.50:9100'));
  });

  testWidgets('test print, Bluetooth label printer: the print dialog, then "did it print?"', (t) async {
    final f = Fake();
    final printed = <String>[];
    final real = printDevicePdf;
    printDevicePdf = (pdf, name) async => printed.add(name);
    addTearDown(() => printDevicePdf = real);
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-test-p2');
    expect(printed, ['Test print · Label printer']);
    expect(find.text('Did the test page print?'), findsOneWidget);
    await tapKey(t, 'printer-test-yes');
    expect(f.body('dev_printer_tested'), {'id': 'p2', 'ok': true, 'note': 'Printed through the print dialog'});
  });

  testWidgets('add a printer: name, job, connection; a network printer needs its IP; label printers pick a label size', (t) async {
    final f = Fake();
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-add');
    expect(find.text('Copies'), findsNothing); // a bill prints once
    expect(find.byKey(const ValueKey('printer-type-kot')), findsNothing); // a store has no kitchen printer
    await t.enterText(find.byKey(const ValueKey('printer-name')), 'Back office');
    await tapKey(t, 'printer-conn-lan');
    await tapKey(t, 'printer-save');
    expect(find.byKey(const ValueKey('printer-error')), findsOneWidget);
    expect(f.calls('dev_printer_save'), isEmpty);
    await t.enterText(find.byKey(const ValueKey('printer-address')), '192.168.1.60');
    await tapKey(t, 'printer-type-label');
    await tapKey(t, 'printer-label-38x25');
    await tapKey(t, 'printer-save');
    expect(f.body('dev_printer_save'), {
      'name': 'Back office', 'printer_type': 'label', 'connection': 'lan', 'address': '192.168.1.60', 'label_size': '38x25', 'auto_cut': true, 'is_default': false, 'model': '',
    });
    expect(f.calls('dev_printers'), hasLength(2)); // the list again
  });

  testWidgets('add a USB printer: Find printers lists the one on the OTG cable; picking it fills its id and name', (t) async {
    final f = Fake();
    final real = findLocalPrinters;
    findLocalPrinters = () async => [
          (kind: 'usb', address: 'usb:04b8:0e28', name: 'EPSON TM-T82X'),
          (kind: 'bluetooth', address: '66:22:B1:0A:7C:01', name: 'RPP02N'),
        ];
    addTearDown(() => findLocalPrinters = real);
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-add');
    await tapKey(t, 'printer-conn-usb');
    await tapKey(t, 'printer-find');
    expect(find.byKey(const ValueKey('printer-found-66:22:B1:0A:7C:01')), findsNothing); // only USB ones for a USB printer
    await tapKey(t, 'printer-found-usb:04b8:0e28');
    expect(find.byKey(const ValueKey('printer-picked')), findsOneWidget);
    await tapKey(t, 'printer-save');
    expect(f.body('dev_printer_save'), {
      'name': 'EPSON TM-T82X', 'printer_type': 'receipt', 'connection': 'usb', 'address': 'usb:04b8:0e28', 'paper_mm': 80, 'auto_cut': true, 'is_default': false, 'model': 'EPSON TM-T82X',
    });
  });

  testWidgets('no printer on the cable: says what to check', (t) async {
    final f = Fake();
    final real = findLocalPrinters;
    findLocalPrinters = () async => const [];
    addTearDown(() => findLocalPrinters = real);
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-add');
    await tapKey(t, 'printer-conn-usb');
    await tapKey(t, 'printer-find');
    expect(find.textContaining('No USB printer found'), findsOneWidget);
  });

  testWidgets('test print, paired Bluetooth printer: a slip straight to it, no dialog; its error is saved when it fails', (t) async {
    final f = Fake()..printers[1]['address'] = '66:22:B1:0A:7C:01';
    final sent = <String>[];
    final real = sendLocalPrinter, realDialog = printDevicePdf;
    sendLocalPrinter = (address, bytes) async => sent.add(address);
    printDevicePdf = (pdf, name) async => fail('no print dialog for a picked printer');
    addTearDown(() {
      sendLocalPrinter = real;
      printDevicePdf = realDialog;
    });
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-test-p2');
    expect(sent, ['66:22:B1:0A:7C:01']);
    expect(f.body('dev_printer_tested'), {'id': 'p2', 'ok': true, 'note': 'Printed over Bluetooth'});

    sendLocalPrinter = (address, bytes) async => throw StateError('Pair the printer in the phone\'s Bluetooth settings first.');
    await tapKey(t, 'printer-test-p2');
    expect(f.body('dev_printer_tested'), {'id': 'p2', 'ok': false, 'note': 'Pair the printer in the phone\'s Bluetooth settings first.'});
  });

  testWidgets('remove asks first', (t) async {
    final f = Fake();
    await show(t, DeviceManagerScreen(api: f.api));
    await tapKey(t, 'printer-remove-p1');
    expect(find.text('Remove Counter printer?'), findsOneWidget);
    await tapKey(t, 'printer-remove-yes');
    expect(f.body('dev_printer_remove'), {'id': 'p1'});
    expect(toast('Counter printer removed.'), findsOneWidget);
  });
}
