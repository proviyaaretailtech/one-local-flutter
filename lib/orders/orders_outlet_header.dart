import 'package:flutter/material.dart';

import '../ui/app_header.dart';
import '../ui/theme.dart';

/// Figma header of the Orders tab: menu button, outlet name, One Local status (Online / Offline), initials.
/// Kept on its own on purpose: the shared outlet header (outlets-multi) replaces this widget; it only needs the same four inputs.
/// [accepting] null = the business is not on One Local, so no status line is drawn.
class OrdersOutletHeader extends StatelessWidget {
  const OrdersOutletHeader({super.key, required this.name, this.accepting, this.onMenu});
  final String name;
  final bool? accepting;
  final VoidCallback? onMenu;

  static String initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(w[0])).toList();
    if (words.isEmpty) return '·';
    return (words.length == 1 ? words.first.substring(0, words.first.length.clamp(1, 2)) : '${words[0][0]}${words[1][0]}').toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final on = accepting == true;
    // The shared banner: back, the outlet's name over "Orders", its One Local status, bell, ☰.
    return AppHeader(
      title: 'Orders',
      kicker: name.isEmpty ? null : name,
      onMenu: onMenu,
      subtitle: accepting == null
          ? null
          : Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: on ? const Color(0xFF16B364) : kMuted, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(on ? 'Online' : 'Offline', style: inter(13, 500, color: on ? const Color(0xFF16B364) : kMuted)),
            ]),
    );
  }
}
