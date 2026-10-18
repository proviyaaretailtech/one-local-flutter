import 'catalogue_api.dart';

/// Display only. Every amount arrives from the server in paise; nothing is calculated for the business here.
String money(num minor, {bool fixed = false}) {
  final neg = minor < 0;
  final a = minor.abs().round();
  final whole = a ~/ 100, paise = a % 100;
  final s = whole.toString();
  String grouped;
  if (s.length <= 3) {
    grouped = s;
  } else {
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},${s.substring(s.length - 3)}';
  }
  final tail = (paise == 0 && !fixed) ? '' : '.${paise.toString().padLeft(2, '0')}';
  return '${neg ? '-' : ''}₹$grouped$tail';
}

/// 84 / 84.5 / 0.25 without trailing zeros.
String qty(num v) {
  final t = v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  return t.isEmpty ? '0' : t;
}

/// "₹40/L" and "84 L" (Figma list rows).
const _short = {'pc': 'pc', 'pack': 'Pk', 'kg': 'kg', 'g': 'g', 'l': 'L', 'ml': 'ml', 'dozen': 'Dz', 'box': 'Box'};
String unitShort(String u) => _short[u] ?? u;

/// "CC500 · Lts" (Figma list rows, under the name).
const _sub = {'pc': 'Nos', 'pack': 'Pack', 'kg': 'kg', 'g': 'gm', 'l': 'Lts', 'ml': 'ml', 'dozen': 'Dzn', 'box': 'Box'};
String unitSub(String u) => _sub[u] ?? u;

/// Names shown in the unit dropdowns.
const sellingUnits = [('pc', 'Piece'), ('pack', 'Pack'), ('kg', 'Kilogram'), ('g', 'Gram'), ('l', 'Litre'), ('ml', 'Millilitre'), ('dozen', 'Dozen'), ('box', 'Box')];
const netUnits = ['g', 'kg', 'ml', 'l', 'pc'];
const gstSlabs = [0, 0.25, 3, 5, 12, 18, 28];

String sellingUnitName(String u) => sellingUnits.firstWhere((e) => e.$1 == u, orElse: () => (u, u)).$2;

/// "500ml" / "1 kg" from the net quantity, or the unit description the person wrote.
String packSize(CatItem i) {
  if (i.unitDescription != null && i.unitDescription!.isNotEmpty) return i.unitDescription!;
  if (i.netQty != null && i.netQtyUnit != null) return '${qty(i.netQty!)}${i.netQtyUnit}';
  return '—';
}

String statusLabel(CatItem i) => switch (i.status) { 'draft' => 'Draft', 'inactive' => 'Unavailable', _ => 'Available' };
