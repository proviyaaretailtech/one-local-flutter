import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../devices/devices_api.dart' show sendRawToPrinter;
import '../inventory/inventory_api.dart' show Facts;
import '../settings/rst_devices_screen.dart' show RstDevicesApi;

// Restaurant printing straight to the printer (founder, 4 Nov 2026: "whenever i try to print the test print it is not connecting to
// any printer", a USB printer). Android's print screen only finds printers that have a print-service app, which USB and most thermal
// printers do not, so a USB printer gets ESC/POS down the cable (MainActivity: onelocal/usb_printer) and a network printer gets it on
// its port (9100 unless the address says otherwise). Bluetooth and "phone's print service" printers still use the print screen.

/// Why a direct print failed, said to the person.
class DirectPrintException implements Exception {
  DirectPrintException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _usb = MethodChannel('onelocal/usb_printer');

/// Sends bytes to the USB printer plugged into this phone or tablet (tests replace it).
Future<void> Function(List<int> bytes) sendUsbPrinter = (bytes) async {
  try {
    await _usb.invokeMethod<bool>('print', {'bytes': Uint8List.fromList(bytes)});
  } on PlatformException catch (e) {
    throw DirectPrintException(switch (e.code) {
      'USB_NONE' => 'No USB printer found. Check the cable (an OTG adapter on a phone) and that the printer is on.',
      'USB_DENIED' => 'USB access was not allowed. Tap Test print again and choose OK when Android asks.',
      _ => 'The USB printer did not print: ${e.message ?? e.code}.',
    });
  } on MissingPluginException {
    throw DirectPrintException('USB printing works in the Android app.');
  }
};

/// Whether this printer is printed to directly on this device (USB on Android, or the network), not through the print screen.
bool printsDirect(Facts p) {
  if (kIsWeb) return false;
  return switch (p.s('connection')) {
    'usb' => defaultTargetPlatform == TargetPlatform.android,
    'lan' => p.s('address').trim().isNotEmpty,
    _ => false,
  };
}

/// Sends ESC/POS (or TSPL) bytes to [p], as many copies as it is set to print.
Future<void> sendToPrinter(Facts p, List<int> bytes) async {
  final copies = p.n('copies') < 1 ? 1 : p.n('copies').toInt();
  final all = [for (var i = 0; i < copies; i++) ...bytes];
  if (p.s('connection') == 'usb') return sendUsbPrinter(all);
  final a = p.s('address').trim();
  final host = a.split(':').first, port = int.tryParse(a.contains(':') ? a.split(':').last : '') ?? 9100;
  try {
    await sendRawToPrinter(host, port, all);
  } catch (_) {
    throw DirectPrintException('${p.s('name')} did not answer at $host:$port. Check it is on the same Wi-Fi.');
  }
}

/// The printer for a job: its default, else the first one for that job. A restaurant with no printer for this job uses another of its
/// USB or network printers (one printer saved under Kitchen still prints the bill), never a label printer.
Facts? pickPrinter(List<Facts> printers, String type) {
  final forJob = printers.where((p) => p.s('type') == type).toList();
  return forJob.where((p) => p.b('is_default')).firstOrNull ?? forJob.firstOrNull ?? printers.where((p) => p.s('type') != 'label' && printsDirect(p)).firstOrNull;
}

/// The restaurant's printer for a job ('receipt', 'kot'), or null when none is set up (tests replace it).
Future<Facts?> Function(String type) rstPrinterFor = (type) async {
  try {
    return pickPrinter((await RstDevicesApi().list()).l('printers'), type);
  } catch (_) {
    return null;
  }
};

/// ESC/POS text on a receipt roll: characters a line (32 on 58 mm, 48 on 80 mm), plain ASCII (₹ as Rs).
class EscPos {
  EscPos(Facts p)
      : cols = p.n('paper_mm') == 58 ? 32 : 48,
        cut = p.raw['auto_cut'] != false;
  final int cols;
  final bool cut;
  final _b = <int>[0x1B, 0x40]; // reset

  List<int> _ascii(String s) => s.replaceAll('₹', 'Rs ').codeUnits.map((c) => c < 128 ? c : 0x3F).toList();

  void line(String s, {bool bold = false, bool centre = false, bool big = false}) {
    if (centre) _b.addAll([0x1B, 0x61, 0x01]);
    if (bold) _b.addAll([0x1B, 0x45, 0x01]);
    if (big) _b.addAll([0x1D, 0x21, 0x11]);
    var rest = s;
    final width = big ? cols ~/ 2 : cols;
    do {
      final n = rest.length > width ? width : rest.length;
      _b.addAll(_ascii(rest.substring(0, n)));
      _b.add(0x0A);
      rest = rest.substring(n);
    } while (rest.isNotEmpty);
    if (big) _b.addAll([0x1D, 0x21, 0x00]);
    if (bold) _b.addAll([0x1B, 0x45, 0x00]);
    if (centre) _b.addAll([0x1B, 0x61, 0x00]);
  }

  /// [left] and [right] on one line, the right one against the edge.
  void row(String left, String right, {bool bold = false}) {
    final room = cols - right.length - 1;
    if (left.length > room) {
      line(left, bold: bold);
      left = '';
    }
    line('${left.padRight(cols - right.length)}$right', bold: bold);
  }

  void dashes() => line('-' * cols);

  List<int> done() => [..._b, 0x1B, 0x64, 0x04, if (cut) ...[0x1D, 0x56, 0x42, 0x00]];
}

/// The test slip for a receipt or kitchen printer.
List<int> escPosTestSlip(Facts p) {
  final e = EscPos(p)
    ..line('TEST PRINT', bold: true, centre: true, big: true)
    ..line(p.s('name'), centre: true)
    ..dashes()
    ..row(p.s('type') == 'kot' ? 'Kitchen tickets' : 'Receipts', '${p.n('paper_mm').toInt()} mm')
    ..row('Connection', p.s('connection') == 'usb' ? 'USB' : 'Network')
    ..dashes()
    ..line('OneLocal Partner', centre: true);
  return e.done();
}
