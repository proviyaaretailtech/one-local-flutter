// Printing that prints (founder, 4 Nov 2026: kitchen tickets never printed while the app said "sent to the printer"). The router prints
// through the printers set up in Devices (`pos_print_targets`), a kitchen ticket on the printer of each station on it (`pos_kot_print`),
// and records what really happened (`pos_print_log`). These tests check the bytes, the routing, a real socket, and every sentence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/devices/devices_api.dart';
import 'package:vinii_pos/devices/print_service.dart' show forgetPrinters;
import 'package:vinii_pos/devices/printer_router.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;

Map<String, dynamic> printerRow(String id, String name, {String type = 'kot', String conn = 'lan', String address = '192.168.1.50', int paper = 80, int copies = 1, bool dflt = false, bool cut = true}) => {
      'id': id, 'name': name, 'type': type, 'connection': conn, 'address': address, 'paper_mm': paper, 'copies': copies, 'auto_cut': cut,
      'is_default': dflt, 'model': null, 'label_size': null, 'location_id': null, 'last_test_at': null,
    };

Map<String, dynamic> dish(String name, {num qty = 1, String? variant, List<Object>? addOns, String? notes, bool takeaway = false, bool cancelled = false}) => {
      'name': name, 'qty': qty, 'variant': variant, 'add_ons': addOns, 'notes': notes, 'takeaway': takeaway, 'cancelled': cancelled,
    };

/// `pos_kot_print` as the database answers it (0658).
Map<String, dynamic> kotAnswer({bool reprint = false, List<Map<String, dynamic>>? groups}) => {
      'ticket_id': 'k-12', 'kot_no': 12, 'order_id': 'o-1', 'display_no': 'P-00012', 'channel': 'dine_in', 'table_label': 'T4',
      'sent_at': '2026-11-04T14:15:00Z', 'note': 'No onions at all', 'reprint': reprint,
      'groups': groups ??
          [
            {
              'printer_id': 'p-kit',
              'station': 'Main Kitchen',
              'items': [
                dish('Paneer Tikka', qty: 2, variant: 'Half', addOns: [{'name': 'Extra cheese', 'qty': 2, 'kind': 'add_on', 'price': 30}], notes: 'less spicy'),
                dish('Veg Biryani', takeaway: true),
                dish('Dal Makhani', qty: 0, cancelled: true),
              ],
            },
          ],
    };

/// A fake POS server for the three print functions.
class Server {
  Server({List<Map<String, dynamic>>? printers, Map<String, dynamic>? kot, this.business = const {'name': 'Dosa House', 'outlet': 'MG Road', 'gstin': '29ABCDE1234F1Z5'}})
      : printers = printers ?? [printerRow('p-kit', 'Kitchen printer', dflt: true)],
        kot = kot ?? kotAnswer();
  List<Map<String, dynamic>> printers;
  Map<String, dynamic> kot;
  final Map<String, dynamic> business;
  final calls = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> of(String fn) => [for (final c in calls) if (c.$1 == fn) c.$2];

  late final rpc = RpcClient(
    baseUrl: 'http://print.test',
    accessToken: () => 't',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body));
      final answer = switch (fn) {
        'pos_print_targets' => {'printers': printers, 'stations': const [], 'business': business},
        'pos_kot_print' => kot,
        'pos_print_log' => {'logged': true},
        _ => null,
      };
      return answer == null
          ? http.Response(jsonEncode({'detail': 'not found: $fn'}), 404, headers: {'content-type': 'application/json'})
          : http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
    }),
  );
  PrinterRouter get router => PrinterRouter.of(rpc);
}

StorePrinter lan({int paper = 80, bool cut = true}) => StorePrinter(printerRow('p', 'Kitchen printer', paper: paper, cut: cut));

void main() {
  late List<(String, List<int>)> raw;
  late List<String> dialogs;
  final realRaw = sendRawToPrinter, realDialog = printPdfDialog;
  setUp(() {
    raw = [];
    dialogs = [];
    sendRawToPrinter = (host, port, bytes) async => raw.add(('$host:$port', bytes));
    printPdfDialog = (Uint8List pdf, String name) async {
      dialogs.add(name);
      return true;
    };
  });
  tearDown(() {
    sendRawToPrinter = realRaw;
    printPdfDialog = realDialog;
    printingInBrowser = false;
  });

  group('the KOT slip (ESC/POS)', () {
    test('KOT number big and bold, table, order and kind, time, station, each dish with its size, add-ons, note, TAKEAWAY and CANCELLED, the order note, cut', () {
      final kot = Facts(kotAnswer());
      final e = kotTicket(kot, kot.l('groups').single, printer: lan());
      final text = e.text, bytes = e.bytes;
      expect(text, startsWith('KOT #12\nTABLE T4\n'));
      expect(text, isNot(contains('REPRINT')));
      expect(text, contains('Order P-00012 - Dine in'));
      expect(text, contains('04 Nov 2026'));
      expect(text, contains('Station: Main Kitchen'));
      expect(text, contains('2 x Paneer Tikka\n    Half\n    + 2 x Extra cheese\n    Note: less spicy\n'));
      expect(text, contains('1 x Veg Biryani\n    ** TAKEAWAY **'));
      expect(text, contains('CANCELLED: Dal Makhani'));
      expect(text, contains('2 dishes'));
      expect(text, contains('Order note: No onions at all'));
      final s = String.fromCharCodes(bytes);
      expect(s, contains('\x1b\x45\x01\x1d\x21\x11KOT #12'), reason: 'bold, double width and height');
      expect(bytes.sublist(0, 2), [0x1B, 0x40], reason: 'reset first');
      expect(bytes.sublist(bytes.length - 7), [0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00], reason: 'fed out and cut');
      expect(bytes.every((b) => b < 128), isTrue, reason: 'plain ASCII');
    });

    test('REPRINT when printed before; ₹ as Rs; 58 mm paper wraps at 32 characters; no cut when auto cut is off', () {
      final kot = Facts(kotAnswer(reprint: true, groups: [
        {'printer_id': null, 'station': 'Bar', 'items': [dish('Fresh lime soda ₹ special with a very long name that wraps', qty: 3)]},
      ]));
      final e = kotTicket(kot, kot.l('groups').single, printer: lan(paper: 58, cut: false), reprint: true);
      expect(e.text, contains('*** REPRINT ***'));
      expect(e.text, isNot(contains('₹')));
      expect(e.text, contains('Rs '));
      expect(e.text.split('\n').every((l) => l.length <= 32), isTrue);
      expect(e.bytes.sublist(e.bytes.length - 3), [0x1B, 0x64, 0x04]);
    });
  });

  group('kitchen tickets', () {
    test('each station prints on its own printer; a printer no longer set up falls back to the default kitchen printer; each print is logged', () async {
      final s = Server(
        printers: [printerRow('p-kit', 'Kitchen printer', dflt: true), printerRow('p-bar', 'Bar printer', address: '192.168.1.51:9101')],
        kot: kotAnswer(groups: [
          {'printer_id': 'p-bar', 'station': 'Bar', 'items': [dish('Mojito')]},
          {'printer_id': 'p-removed', 'station': 'Grill', 'items': [dish('Seekh Kebab', qty: 2)]},
        ]),
      );
      final r = await s.router.printKot('o-1');
      expect(raw.map((x) => x.$1), ['192.168.1.51:9101', '192.168.1.50:9100']);
      expect(String.fromCharCodes(raw[0].$2), allOf(contains('Station: Bar'), contains('1 x Mojito'), isNot(contains('Seekh'))));
      expect(String.fromCharCodes(raw[1].$2), allOf(contains('Station: Grill'), contains('2 x Seekh Kebab')));
      expect(r.outcome, 'printed');
      expect(r.message, 'KOT #12 printed on Bar printer and Kitchen printer.');
      expect(s.of('pos_kot_print').single, {'order_id': 'o-1'});
      expect(s.of('pos_print_log').map((l) => (l['kind'], l['outcome'], l['printer_id'], l['ticket_id'])), [
        ('kot', 'printed', 'p-bar', 'k-12'),
        ('kot', 'printed', 'p-kit', 'k-12'),
      ]);
    });

    test('copies print one after the other; the printers are loaded once, and again after a change in Devices', () async {
      final s = Server(printers: [printerRow('p-kit', 'Kitchen printer', copies: 2)]);
      final one = kotTicket(Facts(s.kot), Facts(s.kot).l('groups').single, printer: StorePrinter(s.printers.single)).bytes;
      final r = await s.router.printKot('o-1');
      expect(raw.single.$2, [...one, ...one]);
      expect(r.message, 'KOT #12 printed on Kitchen printer (2 copies).');
      await s.router.printKot('o-1');
      expect(s.of('pos_print_targets').length, 1, reason: 'kept for the screen');
      forgetPrinters();
      await s.router.printKot('o-1');
      expect(s.of('pos_print_targets').length, 2, reason: 'a change in Devices loads them again');
    });

    test('no kitchen printer set up: says so plainly, prints nothing, logs no_printer', () async {
      final s = Server(printers: [], kot: kotAnswer(groups: [
        {'printer_id': null, 'station': 'Main Kitchen', 'items': [dish('Idli', qty: 2)]},
      ]));
      final r = await s.router.printKot('o-1');
      expect(r.outcome, 'no_printer');
      expect(r.message, 'No kitchen printer set up. Add one in Settings → Devices.');
      expect(raw, isEmpty);
      expect(dialogs, isEmpty);
      expect(s.of('pos_print_log').single, containsPair('outcome', 'no_printer'));
    });

    test('a Bluetooth kitchen printer: not supported yet, said plainly, nothing pretends to print', () async {
      final s = Server(printers: [printerRow('p-kit', 'Kitchen printer', conn: 'bluetooth', address: 'RPP02N')]);
      final r = await s.router.printKot('o-1');
      expect(r.outcome, 'failed');
      expect(r.message, contains('Bluetooth printers are not supported yet.'));
      expect(r.message, isNot(contains('sent to the printer')));
      expect(raw, isEmpty);
      expect(s.of('pos_print_log').single, allOf(containsPair('outcome', 'failed'), containsPair('printer_id', 'p-kit')));
    });

    test("the phone's print service gets the print dialog; a browser cannot reach a network printer and says so", () async {
      final s = Server(printers: [printerRow('p-kit', 'Kitchen printer', conn: 'system', address: '')]);
      expect((await s.router.printKot('o-1')).message, "KOT #12 sent to the print dialog for Kitchen printer.");
      expect(dialogs.single, startsWith('KOT #12'));
      printingInBrowser = true;
      final b = Server();
      final r = await b.router.printKot('o-1');
      expect(r.outcome, 'dialog');
      expect(r.message, 'A browser cannot reach Kitchen printer at 192.168.1.50, so KOT #12 opened in the print dialog.');
      expect(raw, isEmpty);
    });

    test('the print right after Send KOT is never marked REPRINT; a print from the KDS card prints only that station', () async {
      final s = Server(kot: kotAnswer(reprint: true, groups: [
        {'printer_id': 'p-kit', 'station': 'Main Kitchen', 'items': [dish('Dosa')]},
        {'printer_id': 'p-kit', 'station': 'Bar', 'items': [dish('Lassi')]},
      ]));
      await printSentKot(s.rpc, {'order_id': 'o-1', 'kot': {'ticket_id': 'k-12', 'kot_no': 12}});
      expect(s.of('pos_kot_print').single, {'order_id': 'o-1', 'ticket_id': 'k-12'});
      expect(raw.map((x) => String.fromCharCodes(x.$2)).any((t) => t.contains('REPRINT')), isFalse);
      raw.clear();
      await s.router.printKot('o-1', ticketId: 'k-12', stationName: 'Bar');
      expect(String.fromCharCodes(raw.single.$2), allOf(contains('REPRINT'), contains('Lassi'), isNot(contains('Dosa'))));
      expect(printSentKot(s.rpc, {'order_id': 'o-1', 'kot': null}), isNull, reason: 'nothing went to the kitchen');
    });
  });

  group('a real network printer (a socket on this machine)', () {
    setUp(() => sendRawToPrinter = realRaw);

    test('the KOT bytes arrive at the printer port, all of them', () async {
      final printer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final got = Completer<List<int>>();
      printer.listen((c) async {
        final bytes = <int>[];
        await c.forEach(bytes.addAll);
        got.complete(bytes);
      });
      final s = Server(printers: [printerRow('p-kit', 'Kitchen printer', address: '127.0.0.1:${printer.port}')]);
      final r = await s.router.printKot('o-1');
      final bytes = await got.future.timeout(const Duration(seconds: 5));
      await printer.close();
      expect(r.message, 'KOT #12 printed on Kitchen printer.');
      expect(bytes, kotTicket(Facts(s.kot), Facts(s.kot).l('groups').single, printer: StorePrinter(s.printers.single)).bytes);
      expect(String.fromCharCodes(bytes), contains('2 x Paneer Tikka'));
    });

    test('nothing listening: "did not answer (connection refused)", logged as failed with the reason', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final s = Server(printers: [printerRow('p-kit', 'Kitchen printer', address: '127.0.0.1:$port')]);
      final r = await s.router.printKot('o-1');
      expect(r.outcome, 'failed');
      expect(r.message, 'KOT #12 not printed: Kitchen printer at 127.0.0.1:$port did not answer (connection refused).');
      expect(s.of('pos_print_log').single, allOf(containsPair('outcome', 'failed'), containsPair('detail', '127.0.0.1:$port did not answer (connection refused)')));
    });
  });

  group('bills and receipts', () {
    test('the default receipt printer, with the business at the top; none set up: the print dialog, and why', () async {
      final s = Server(printers: [
        printerRow('p-r1', 'Spare printer', type: 'receipt', address: '192.168.1.70'),
        printerRow('p-r2', 'Counter printer', type: 'receipt', address: '192.168.1.60', dflt: true),
      ]);
      Facts? seen;
      final r = await s.router.printReceipt(
        kind: 'bill',
        what: 'bill',
        title: 'Bill R1',
        orderId: 'o-1',
        escPos: (p, b) {
          seen = b;
          return 'BILL ${b.s('name')}'.codeUnits;
        },
        pdf: (_, _) async => Uint8List(0),
      );
      expect(raw.single.$1, '192.168.1.60:9100');
      expect(seen!.s('gstin'), '29ABCDE1234F1Z5');
      expect(r.message, 'Bill printed on Counter printer.');
      expect(s.of('pos_print_log').single, {'kind': 'bill', 'outcome': 'printed', 'order_id': 'o-1', 'printer_id': 'p-r2'});

      final none = Server(printers: [printerRow('p-kit', 'Kitchen printer')]);
      final d = await none.router.printReceipt(kind: 'receipt', what: 'receipt', title: 'Receipt R1', escPos: (_, _) => [], pdf: (_, _) async => Uint8List(1));
      expect(d.outcome, 'dialog');
      expect(d.message, 'No receipt printer set up, so the receipt opened in the print dialog. Add a receipt printer in Settings → Devices.');
      expect(dialogs, ['Receipt R1.pdf']);
    });
  });

  test("a network printer's address: IPv4 or a host name, an optional port", () {
    for (final ok in ['192.168.1.50', '192.168.1.50:9100', '10.0.0.7:515', 'kitchen-printer.local', 'epson:9100']) {
      expect(lanAddressError(ok), isNull, reason: ok);
    }
    expect(lanAddressError(''), "Enter the printer's IP address, like 192.168.1.50.");
    for (final bad in ['192.168.1', '192.168.1.256', '192.168.1.50:', 'http://192.168.1.50', '192.168.1.50:9100:1', 'bad name']) {
      expect(lanAddressError(bad), isNotNull, reason: bad);
    }
    expect(lanAddressError('192.168.1.50:70000'), contains('between 1 and 65535'));
  });
}
