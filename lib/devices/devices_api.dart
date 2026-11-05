import 'dart:async';
import 'dart:io' show Socket;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';

// The store's Device manager (founder, 31 Oct 2026): printers for receipts, barcode labels and the kitchen
// (database: hosted_store_devices_2026-10-31.sql).

class StorePrinter {
  StorePrinter(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => '${raw[k] ?? ''}';
  String get id => _s('id');
  String get name => _s('name');

  /// receipt, label (barcode labels) or kot (kitchen). `pos_print_targets` (0658) names it `type`.
  String get type => _s('printer_type').isNotEmpty ? _s('printer_type') : _s('type');

  /// lan (network, prints directly), bluetooth, usb, or system (the phone's print service).
  String get connection => _s('connection');
  String get address => _s('address');
  int get paperMm => (raw['paper_mm'] as num?)?.toInt() ?? 80;

  /// How many times each job prints (1 to 5).
  int get copies => ((raw['copies'] as num?)?.toInt() ?? 1).clamp(1, 5);
  String get labelSize => _s('label_size');
  bool get autoCut => raw['auto_cut'] != false;
  bool get isDefault => raw['is_default'] == true;
  String get model => _s('model');
  DateTime? get lastTestAt => DateTime.tryParse(_s('last_test_at'))?.toLocal();
  bool? get lastTestOk => raw['last_test_ok'] as bool?;
  String get lastTestNote => _s('last_test_note');

  /// Network printers print straight to port 9100, no print dialog.
  bool get direct => connection == 'lan';
  String get host => address.trim().split(':').first;
  int get port => int.tryParse(address.contains(':') ? address.split(':').last : '') ?? 9100;

  /// Where a network printer is, as the person typed it: "192.168.1.50", or with its port when that is not 9100.
  String get where => port == 9100 ? host : '$host:$port';
}

/// Why a network printer's address cannot be used, or null when it can: an IPv4 address (each part 0-255) or a host name, with an
/// optional port (1-65535), for example 192.168.1.50 or 192.168.1.50:9100.
String? lanAddressError(String address) {
  final a = address.trim();
  if (a.isEmpty) return "Enter the printer's IP address, like 192.168.1.50.";
  final m = RegExp(r'^([^:\s]+)(?::([0-9]{1,5}))?$').firstMatch(a);
  final port = m?.group(2) == null ? 9100 : int.parse(m!.group(2)!);
  final host = m?.group(1) ?? '';
  final ipv4 = RegExp(r'^[0-9]{1,3}(\.[0-9]{1,3}){3}$').hasMatch(host) && host.split('.').every((o) => int.parse(o) <= 255);
  final name = !RegExp(r'^[0-9.]+$').hasMatch(host) &&
      host.length <= 253 &&
      host.split('.').every((l) => RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$').hasMatch(l));
  if (m == null || !(ipv4 || name)) return 'The IP address looks wrong. It is four numbers with dots, like 192.168.1.50.';
  if (port < 1 || port > 65535) return 'The port after ":" must be between 1 and 65535 (most printers use 9100).';
  return null;
}

class DevicesApi {
  DevicesApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<({List<StorePrinter> printers, bool canEdit, bool restaurant})> printers() async {
    final r = await _rpc.callMap('dev_printers', {});
    return (
      printers: ((r['printers'] as List?) ?? const []).map((e) => StorePrinter((e as Map).cast<String, dynamic>())).toList(),
      canEdit: r['can_edit'] == true,
      restaurant: r['kind'] == 'restaurant',
    );
  }

  Future<StorePrinter> save(Map<String, Object?> fields) async => StorePrinter(await _rpc.callMap('dev_printer_save', fields..removeWhere((_, v) => v == null)));
  Future<void> remove(String id) => _rpc.callMap('dev_printer_remove', {'id': id});
  Future<StorePrinter> tested(String id, {required bool ok, String note = ''}) async =>
      StorePrinter(await _rpc.callMap('dev_printer_tested', {'id': id, 'ok': ok, if (note.isNotEmpty) 'note': note}));
}

/// How long a network printer has to take the connection and the job.
const printerTimeout = Duration(seconds: 5);

/// Sends raw ESC/POS bytes to a network printer's port (9100). Not on the web (a browser cannot open the socket). Tests replace it.
Future<void> Function(String host, int port, List<int> bytes) sendRawToPrinter = (host, port, bytes) async {
  if (kIsWeb) throw UnsupportedError('A browser cannot reach the printer directly. Print from the phone app, or use the print dialog.');
  final s = await Socket.connect(host, port, timeout: printerTimeout);
  try {
    s.add(bytes);
    await s.flush().timeout(printerTimeout);
  } finally {
    await s.close().timeout(printerTimeout, onTimeout: () => s.destroy());
  }
};

/// An ESC/POS test slip: the store, the printer, the paper width, a line ruler and (when on) a cut.
List<int> escPosTestSlip({required String store, required StorePrinter printer}) {
  final cols = printer.paperMm == 58 ? 32 : 48;
  String center(String t) => t.length >= cols ? t.substring(0, cols) : '${' ' * ((cols - t.length) ~/ 2)}$t';
  final lines = [
    center(store.toUpperCase()),
    center('OneLocal test print'),
    '-' * cols,
    'Printer : ${printer.name}',
    'Paper   : ${printer.paperMm} mm',
    '-' * cols,
    center('If you can read this, it works.'),
    '',
    '',
  ];
  final bytes = <int>[0x1B, 0x40]; // reset
  for (final l in lines) {
    bytes.addAll(l.codeUnits.map((c) => c < 128 ? c : 0x3F));
    bytes.add(0x0A);
  }
  bytes.addAll([0x1B, 0x64, 0x03]); // feed 3 lines
  if (printer.autoCut) bytes.addAll([0x1D, 0x56, 0x42, 0x00]); // cut
  return bytes;
}
