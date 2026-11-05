import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:printing/printing.dart';

import '../api/net_guard.dart' show errorSentence;
import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../outlets/outlet_scope.dart';
import '../ui/theme.dart' show showToast;
import 'devices_api.dart';
import 'print_service.dart' show receiptPdf;

// Printing that prints (founder, 4 Nov 2026: kitchen tickets never printed while the app said "sent to the printer"; Print KOT and the
// receipt's Print did nothing; the printers saved in Devices were never used). The phone or tablet on the shop's Wi-Fi prints: a server
// online cannot reach a printer on the shop's network. The database says WHAT to print and WHERE (`pos_print_targets`, `pos_kot_print`,
// migration 0658, from Devices and Kitchen setup) and keeps what happened (`pos_print_log`, on the order's events).
//   Network (LAN)          ESC/POS bytes on the printer's port (9100 unless the address names another), its copies, cut when auto cut is on
//   Phone's print service  the phone's print dialog
//   Bluetooth / USB        not in this build: said plainly, nothing pretends to print
//   a browser              cannot open a socket to a printer: the print dialog, and it says so
// Every message says what happened; "printed" only once the bytes were written to the printer.

/// What one print did. [outcome] is what `pos_print_log` keeps: printed, failed, no_printer, or dialog (handed to the phone's print dialog).
class PrintResult {
  const PrintResult(this.outcome, this.message, {this.printerId, this.printer, this.detail});
  final String outcome;

  /// The sentence the screen shows.
  final String message;

  /// The printer it went to (id and name), when there was one.
  final String? printerId, printer;

  /// Why it did not print, for the order's events (at most 200 characters).
  final String? detail;
  bool get printed => outcome == 'printed';

  /// Printed, or handed to the print dialog.
  bool get ok => outcome == 'printed' || outcome == 'dialog';
}

/// The phone's print dialog for a PDF: true when it was printed or sent, false when it was closed without printing. Tests replace it.
Future<bool> Function(Uint8List pdf, String name) printPdfDialog = (pdf, name) => Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

/// True in a browser: a browser cannot open a socket to a printer. Tests set it.
bool printingInBrowser = kIsWeb;

/// Bumped when a printer is added, changed or removed, so every screen loads the printers again.
int printTargetsEpoch = 0;

/// The business's printers, which kitchen station prints where, and the business's name and details for a receipt's header
/// (`pos_print_targets`; every staff role may read it).
class PrintTargets {
  PrintTargets(this.raw);
  final Map<String, dynamic> raw;
  late final List<StorePrinter> printers = [
    for (final p in (raw['printers'] as List?) ?? const [])
      if (p is Map) StorePrinter(p.cast<String, dynamic>()),
  ];

  /// {name, outlet, gstin, address, phone}
  Facts get business => Facts((raw['business'] as Map?)?.cast<String, dynamic>() ?? const {});

  StorePrinter? byId(String? id) => id == null || id.isEmpty ? null : printers.where((p) => p.id == id).firstOrNull;

  /// The printer for a job (receipt, kot, label): its default, else the first one for it.
  StorePrinter? forJob(String job) {
    final all = printers.where((p) => p.type == job).toList();
    return all.where((p) => p.isDefault).firstOrNull ?? all.firstOrNull;
  }
}

/// Prints through the printers set up in Devices, over one server door ([RpcClient]): kitchen tickets, bills and receipts, test pages.
class PrinterRouter {
  PrinterRouter._(this._rpc);
  final RpcClient _rpc;

  static final _of = Expando<PrinterRouter>();
  static PrinterRouter? _shared;

  /// One per server door: the printers are loaded once for a screen, then again after two minutes or a change in Devices.
  factory PrinterRouter.of(RpcClient rpc) => _of[rpc] ??= PrinterRouter._(rpc);

  /// For screens without a door of their own (the store's bills and labels).
  static PrinterRouter get shared => _shared ??= PrinterRouter._(RpcClient());

  Future<PrintTargets>? _targets;
  DateTime? _at;
  int _epoch = -1;
  String? _loc;

  /// The printers (cached). A failed load is not kept: the next print asks again.
  Future<PrintTargets> targets({bool refresh = false}) {
    final loc = OutletScope.pick(null);
    final stale = _at == null || DateTime.now().difference(_at!) > const Duration(minutes: 2);
    if (refresh || _targets == null || stale || _epoch != printTargetsEpoch || _loc != loc) {
      _epoch = printTargetsEpoch;
      _loc = loc;
      _at = DateTime.now();
      final f = _rpc.callMap('pos_print_targets', {'location_id': ?loc}).then(PrintTargets.new);
      _targets = f;
      f.catchError((Object _) {
        if (identical(_targets, f)) _targets = null;
        return PrintTargets(const {});
      });
    }
    return _targets!;
  }

  /// Records what a print did on the order's events (and a good test print on the printer). A lost record does not change what the
  /// person is told: the paper either came out or it did not.
  Future<void> log(String kind, PrintResult r, {String? orderId, String? ticketId}) async {
    try {
      await _rpc.callMap('pos_print_log', {
        'kind': kind,
        'outcome': r.outcome,
        'order_id': ?orderId,
        'ticket_id': ?ticketId,
        'printer_id': ?r.printerId,
        if (r.detail != null && r.detail!.isNotEmpty) 'detail': r.detail!.length > 200 ? r.detail!.substring(0, 200) : r.detail,
      });
    } catch (e) {
      debugPrint('pos_print_log failed: $e');
    }
  }

  // ---------------------------------------------------------------- kitchen tickets

  /// Prints one kitchen ticket (the order's latest when [ticketId] is null) on the printer of each station on it (`pos_kot_print`):
  /// a station's own printer, its kitchen group's, else the default kitchen printer. [fresh] is the print right after Send KOT (never
  /// marked REPRINT); [stationName] prints only that station's dishes (a KDS card).
  Future<PrintResult> printKot(String orderId, {String? ticketId, bool fresh = false, String? stationName}) async {
    final Facts kot;
    try {
      kot = Facts(await _rpc.callMap('pos_kot_print', {'order_id': orderId, 'ticket_id': ?ticketId}));
    } catch (e) {
      final r = PrintResult('failed', 'KOT not printed: ${errorSentence(e)}', detail: errorSentence(e));
      await log('kot', r, orderId: orderId, ticketId: ticketId);
      return r;
    }
    final what = 'KOT #${kot.n('kot_no').toInt()}';
    final tid = kot.so('ticket_id') ?? ticketId;
    PrintTargets? t;
    String? loadError;
    try {
      t = await targets();
    } catch (e) {
      loadError = errorSentence(e);
    }
    var groups = kot.l('groups');
    if (stationName != null && groups.any((g) => g.s('station') == stationName)) groups = [for (final g in groups) if (g.s('station') == stationName) g];
    if (groups.isEmpty) {
      final r = PrintResult('failed', '$what has no dishes to print.', detail: 'no dishes on the ticket');
      await log('kot', r, orderId: orderId, ticketId: tid);
      return r;
    }
    final results = <PrintResult>[];
    for (final g in groups) {
      final label = groups.length > 1 ? '$what (${g.s('station')})' : what;
      final PrintResult r;
      final p = t == null ? null : t.byId(g.so('printer_id')) ?? t.forJob('kot');
      if (t == null) {
        r = PrintResult('failed', '$label not printed: the printers could not be loaded ($loadError).', detail: 'printers not loaded: $loadError');
      } else if (p == null) {
        r = PrintResult('no_printer', groups.length > 1 ? '$label not printed: no kitchen printer set up. Add one in Settings → Devices.' : 'No kitchen printer set up. Add one in Settings → Devices.',
            detail: 'no kitchen printer for ${g.s('station')}');
      } else {
        final slip = kotTicket(kot, g, printer: p, reprint: !fresh && kot.b('reprint'));
        r = await send(p, what: label, escPos: () => slip.bytes, pdf: () => receiptPdf(slip.text, paperMm: p.paperMm), title: '$what ${g.s('station')}');
      }
      results.add(r);
      await log('kot', r, orderId: orderId, ticketId: tid);
    }
    if (results.length == 1) return results.single;
    if (results.every((r) => r.printed)) {
      final names = {for (final r in results) t!.byId(r.printerId)?.name ?? ''}.where((n) => n.isNotEmpty).toList();
      return PrintResult('printed', '$what printed on ${names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}'}.');
    }
    final worst = results.any((r) => r.outcome == 'failed')
        ? 'failed'
        : results.any((r) => r.outcome == 'no_printer')
            ? 'no_printer'
            : 'dialog';
    return PrintResult(worst, results.map((r) => r.message).join(' '));
  }

  // ---------------------------------------------------------------- bills and receipts

  /// A bill ([kind] bill) or a paid receipt ([kind] receipt) on the receipt printer: the default one, else any. With none set up (or
  /// the printers not loaded) it opens in the print dialog and says why. [escPos] and [pdf] are given the business's details for the
  /// header.
  Future<PrintResult> printReceipt({
    required String kind,
    required String what,
    required String title,
    String? orderId,
    required List<int> Function(StorePrinter p, Facts business) escPos,
    required Future<Uint8List> Function(StorePrinter? p, Facts business) pdf,
  }) async {
    PrintTargets? t;
    String? loadError;
    try {
      t = await targets();
    } catch (e) {
      loadError = errorSentence(e);
    }
    final business = t?.business ?? const Facts({});
    final p = t?.forJob('receipt');
    final PrintResult r;
    if (p == null) {
      final why = t == null ? 'The printers could not be loaded ($loadError)' : 'No receipt printer set up';
      final shown = await _dialog(() => pdf(null, business), '$title.pdf');
      r = shown == null
          ? PrintResult('dialog', '$why, so the $what opened in the print dialog.${t == null ? '' : ' Add a receipt printer in Settings → Devices.'}', detail: why)
          : PrintResult(t == null ? 'failed' : 'no_printer', '$why, and the print dialog was closed: the $what was not printed.', detail: '$why; $shown');
    } else {
      r = await send(p, what: _cap(what), escPos: () => escPos(p, business), pdf: () => pdf(p, business), title: '$title.pdf');
    }
    await log(kind, r, orderId: orderId);
    return r;
  }

  // ---------------------------------------------------------------- one printer

  /// Sends one job to [p] the way it connects; [what] names the job in the sentence ("KOT #12", "Bill").
  Future<PrintResult> send(StorePrinter p, {required String what, required List<int> Function() escPos, required Future<Uint8List> Function() pdf, required String title}) async {
    switch (p.connection) {
      case 'lan' when printingInBrowser:
        final shown = await _dialog(pdf, title);
        return shown == null
            ? PrintResult('dialog', 'A browser cannot reach ${p.name} at ${p.where}, so $what opened in the print dialog.', printerId: p.id, printer: p.name, detail: 'browser: print dialog')
            : PrintResult('failed', '$what not printed: a browser cannot reach ${p.name} at ${p.where}, and the print dialog was closed.', printerId: p.id, printer: p.name, detail: 'browser; $shown');
      case 'lan':
        final one = escPos();
        try {
          await sendRawToPrinter(p.host, p.port, [for (var i = 0; i < p.copies; i++) ...one]);
          return PrintResult('printed', '$what printed on ${p.name}${p.copies > 1 ? ' (${p.copies} copies)' : ''}.', printerId: p.id, printer: p.name);
        } catch (e) {
          final why = noAnswer(e);
          return PrintResult('failed', '$what not printed: ${p.name} at ${p.where} did not answer$why.', printerId: p.id, printer: p.name, detail: '${p.where} did not answer$why');
        }
      case 'system':
        final shown = await _dialog(pdf, title);
        return shown == null
            ? PrintResult('dialog', '$what sent to the print dialog for ${p.name}.', printerId: p.id, printer: p.name)
            : PrintResult('failed', '$what not printed: $shown.', printerId: p.id, printer: p.name, detail: shown);
      case 'bluetooth' || 'usb':
        return PrintResult('failed', '$what not printed on ${p.name}. ${notSupported(p.connection)}', printerId: p.id, printer: p.name, detail: '${p.connection} printers are not supported yet');
      default:
        return PrintResult('failed', '$what not printed: ${p.name} has no connection set. Choose one in Settings → Devices.', printerId: p.id, printer: p.name, detail: 'no connection');
    }
  }

  /// Opens the print dialog; null when it printed (or was sent), else why not.
  Future<String?> _dialog(Future<Uint8List> Function() pdf, String title) async {
    try {
      return await printPdfDialog(await pdf(), title) ? null : 'the print dialog was closed';
    } catch (e) {
      return 'the print dialog could not open';
    }
  }
}

String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The sentence for a printer this build cannot reach (Bluetooth, USB).
String notSupported(String connection) =>
    '${connection == 'usb' ? 'USB' : 'Bluetooth'} printers are not supported yet. In Settings → Devices, set it to Network (Wi-Fi / LAN) or Phone\'s print service.';

/// Why a network printer did not take the job, as a few words after "did not answer".
String noAnswer(Object e) {
  if (e is TimeoutException) return ' within ${printerTimeout.inSeconds} seconds';
  if (e is SocketException) {
    final m = '${e.osError?.message ?? ''} ${e.message}'.toLowerCase();
    if (m.contains('refused')) return ' (connection refused)';
    if (m.contains('timed out')) return ' within ${printerTimeout.inSeconds} seconds';
    if (m.contains('lookup') || m.contains('nodename') || m.contains('not known')) return ' (that address was not found on this network)';
    if (m.contains('unreachable')) return ' (network unreachable: is this phone on the shop\'s Wi-Fi?)';
    return ' (${(e.osError?.message ?? e.message).trim()})';
  }
  if (e is UnsupportedError) return ' (${e.message})';
  return ' ($e)';
}

/// Right after a KOT went to the kitchen: prints that ticket ([answer] is the send's answer, with `order_id` and `kot.ticket_id`). Null
/// when the answer names no ticket (nothing went to the kitchen). The send has already succeeded; printing cannot undo it.
Future<PrintResult>? printSentKot(RpcClient rpc, Map<String, dynamic> answer) {
  final orderId = answer['order_id'], kot = answer['kot'];
  if (orderId is! String || orderId.isEmpty || kot is! Map) return null;
  return PrinterRouter.of(rpc).printKot(orderId, ticketId: kot['ticket_id'] as String?, fresh: true);
}

/// Prints and shows what happened in a toast.
Future<PrintResult> printAndSay(BuildContext context, Future<PrintResult> job) async {
  final r = await job;
  if (context.mounted) showToast(context, r.message);
  return r;
}

// ---------------------------------------------------------------- ESC/POS

/// A thermal slip being built: ESC/POS bytes and the same text (for the print dialog), in the printer's ASCII (₹ prints as "Rs"),
/// wrapped to the paper's width: 32 characters on 58 mm paper, 48 on 80 mm (half that in double width).
class EscPos {
  EscPos(this.printer) : cols = printer.paperMm == 58 ? 32 : 48 {
    _b.addAll([0x1B, 0x40]); // reset
  }
  final StorePrinter printer;
  final int cols;
  final _b = <int>[];
  final _text = StringBuffer();
  bool _wide = false;

  static String plain(String s) => s
      .replaceAll('₹', 'Rs ')
      .replaceAll('−', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll('×', 'x')
      .replaceAll('·', '-')
      .replaceAll('→', '>')
      .replaceAll('’', "'")
      .runes
      .map((c) => c < 128 ? String.fromCharCode(c) : '?')
      .join();

  int get width => _wide ? cols ~/ 2 : cols;

  void line([String s = '']) {
    var rest = plain(s);
    do {
      final cut = rest.length > width ? (rest.lastIndexOf(' ', width) > width ~/ 2 ? rest.lastIndexOf(' ', width) : width) : rest.length;
      final part = rest.substring(0, cut);
      _b
        ..addAll(part.codeUnits)
        ..add(0x0A);
      _text.writeln(part);
      rest = rest.substring(cut).trimLeft();
    } while (rest.isNotEmpty);
  }

  /// [left] and [right] on one line, the right one at the edge.
  void pair(String left, String right) {
    if (right.isEmpty) return line(left);
    final r = plain(right), room = width - r.length - 1;
    var l = plain(left);
    while (l.length > room && room > 0) {
      line(l.substring(0, room));
      l = l.substring(room).trimLeft();
    }
    line('${l.padRight(room < 0 ? 0 : room)} $r');
  }

  void rule([String c = '-']) => line(c * width);
  void centre(bool on) => _b.addAll([0x1B, 0x61, on ? 0x01 : 0x00]);
  void bold(bool on) => _b.addAll([0x1B, 0x45, on ? 0x01 : 0x00]);

  /// Double height ([tall]) and double width ([wide]).
  void size({bool tall = false, bool wide = false}) {
    _wide = wide;
    _b.addAll([0x1D, 0x21, (wide ? 0x10 : 0) | (tall ? 0x01 : 0)]);
  }

  /// The slip's bytes: fed out, and cut when the printer cuts.
  List<int> get bytes => [..._b, 0x1B, 0x64, 0x04, if (printer.autoCut) ...[0x1D, 0x56, 0x42, 0x00]];

  /// The same slip as plain text.
  String get text => _text.toString();
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "04 Nov 2026 7:45 PM" in the phone's time.
String slipTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal(), h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '${l.day.toString().padLeft(2, '0')} ${_months[l.month - 1]} ${l.year} $h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

String _qty(num q) => q == q.roundToDouble() ? '${q.toInt()}' : '$q';

/// "Dine in", "Takeaway", "Delivery", "Swiggy" …
String channelName(String c) => switch (c) {
      'dine_in' => 'Dine in',
      'pickup' || 'takeaway' => 'Takeaway',
      'delivery' => 'Delivery',
      'swiggy' => 'Swiggy',
      'zomato' => 'Zomato',
      'online' => 'Online',
      '' => '',
      _ => '${c[0].toUpperCase()}${c.substring(1).replaceAll('_', ' ')}',
    };

/// What was chosen with a dish, as the kitchen reads it: "2 x Cheese slice", "fries & Cole (combo)". Strings or `{name, qty, kind}`.
List<String> kotAddOns(Object? addOns) => [
      for (final a in addOns is List ? addOns : const [])
        if (a is Map)
          '${((a['qty'] as num?) ?? 1) > 1 ? '${_qty(a['qty'] as num)} x ' : ''}${a['name'] ?? ''}${a['kind'] == 'combo' ? ' (combo)' : ''}'
        else if ('$a'.trim().isNotEmpty)
          '$a',
    ];

/// One station's part of a kitchen ticket (one group of `pos_kot_print`): "KOT #12" big and bold (REPRINT under it when printed before),
/// the table or the order's kind, the order number, the time it went to the kitchen, the station, then each dish as "2 x Paneer Tikka"
/// with its size, add-ons and note on indented lines, TAKEAWAY on a dish to pack, cancelled dishes marked CANCELLED, and the order's note.
EscPos kotTicket(Facts kot, Facts group, {required StorePrinter printer, bool reprint = false}) {
  final e = EscPos(printer);
  final channel = kot.s('channel'), table = kot.so('table_label') ?? '';
  e
    ..centre(true)
    ..bold(true)
    ..size(tall: true, wide: true)
    ..line('KOT #${kot.n('kot_no').toInt()}')
    ..size();
  if (reprint) e.line('*** REPRINT ***');
  e.size(tall: true);
  e.line(table.isNotEmpty ? (table.toLowerCase().startsWith('table') ? table.toUpperCase() : 'TABLE ${table.toUpperCase()}') : channelName(channel).toUpperCase());
  e
    ..size()
    ..bold(false)
    ..centre(false)
    ..rule()
    ..line('Order ${kot.s('display_no')}${channel.isEmpty ? '' : ' - ${channelName(channel)}'}')
    ..line(slipTime(kot.t('sent_at')))
    ..line('Station: ${group.s('station')}')
    ..rule();
  for (final i in group.l('items')) {
    final q = i.n('qty');
    if (i.b('cancelled')) {
      e.line('CANCELLED: ${q > 0 ? '${_qty(q)} x ' : ''}${i.s('name')}');
      continue;
    }
    e
      ..bold(true)
      ..size(tall: true)
      ..line('${_qty(q)} x ${i.s('name')}')
      ..size()
      ..bold(false);
    if ((i.so('variant') ?? '').isNotEmpty) e.line('    ${i.s('variant')}');
    for (final a in kotAddOns(i.raw['add_ons'])) {
      e.line('    + $a');
    }
    if ((i.so('notes') ?? '').trim().isNotEmpty) e.line('    Note: ${i.s('notes').trim()}');
    if (i.b('takeaway')) {
      e
        ..bold(true)
        ..line('    ** TAKEAWAY **')
        ..bold(false);
    }
  }
  e.rule();
  final dishes = group.l('items').where((i) => !i.b('cancelled')).length;
  e.line('$dishes ${dishes == 1 ? 'dish' : 'dishes'}');
  if ((kot.so('note') ?? '').trim().isNotEmpty) {
    e
      ..bold(true)
      ..line('Order note: ${kot.s('note').trim()}')
      ..bold(false);
  }
  return e;
}
