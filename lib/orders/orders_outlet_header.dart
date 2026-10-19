import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 10, 16, 12),
      child: Row(children: [
        Semantics(
          button: true,
          label: 'Menu',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onMenu,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: const Color(0xFFF3F4F1), borderRadius: BorderRadius.circular(10)),
              child: const Icon(LucideIcons.menu, size: 22, color: kInk),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(name.isEmpty ? 'Orders' : name, style: inter(17, 700), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (accepting != null)
              Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: on ? const Color(0xFF16B364) : kMuted, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(on ? 'Online' : 'Offline', style: inter(13, 500, color: on ? const Color(0xFF16B364) : kMuted)),
              ]),
          ]),
        ),
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xFFF3F4F1), shape: BoxShape.circle),
          child: Text(initials(name), style: inter(12.5, 700)),
        ),
      ]),
    );
  }
}
