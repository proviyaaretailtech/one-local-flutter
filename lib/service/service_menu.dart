import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'availability_screen.dart';
import 'catalogue_screen.dart';
import 'history_screen.dart';
import 'plans_screen.dart';
import 'service_api.dart';
import 'staff_screen.dart';

/// The screens of the Service POS, by name (the menu, and catalogue rows that are packages or memberships).
Widget serviceScreen(String name, ServiceApi api, {String business = '', ValueChanged<String>? onNavigate}) => switch (name) {
      'catalogue' => ServiceCatalogueScreen(api: api, business: business, onNavigate: onNavigate),
      'packages' => PlansScreen(api: api, kind: 'package', business: business, onNavigate: onNavigate),
      'memberships' => PlansScreen(api: api, kind: 'membership', business: business, onNavigate: onNavigate),
      'staff' => StaffScreen(api: api, business: business, onNavigate: onNavigate),
      'availability' => AvailabilityScreen(api: api, business: business, onNavigate: onNavigate),
      _ => ServiceHistoryScreen(api: api, business: business, onNavigate: onNavigate),
    };

const _items = [
  ('calendar', 'Appointment calendar', LucideIcons.calendar),
  ('catalogue', 'Service catalogue', LucideIcons.scissors),
  ('packages', 'Packages', LucideIcons.package),
  ('memberships', 'Memberships', LucideIcons.star),
  ('staff', 'Staff & service providers', LucideIcons.users),
  ('availability', 'Availability & scheduling', LucideIcons.clock),
  ('history', 'Service history', LucideIcons.history),
];

/// The top-bar menu of every Service POS screen.
Future<void> showServiceMenu(BuildContext context, ServiceApi api, {String business = '', ValueChanged<String>? onNavigate, String current = 'calendar'}) async {
  final pick = await showOrderSheet<String>(context, title: 'Service', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (id, label, icon) in _items)
          ListTile(
            key: ValueKey('menu-$id'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, size: 20, color: id == current ? kGreenText : kInk),
            title: Text(label, style: inter(15, id == current ? 700 : 500)),
            trailing: const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
            onTap: () => Navigator.pop(ctx, id),
          ),
      ]));
  if (pick == null || pick == current || !context.mounted) return;
  final nav = Navigator.of(context);
  if (pick == 'calendar') {
    nav.popUntil((r) => r.isFirst || r.settings.name == 'service/calendar');
    return;
  }
  await nav.push(MaterialPageRoute(builder: (_) => serviceScreen(pick, api, business: business, onNavigate: onNavigate)));
}
