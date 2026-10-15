// Dev only: the section D screens with fixed sample figures, to compare with the Figma export
// (assets/figma_ref_d). The figures below are the ones drawn in Figma, not real data.
// flutter run -d web-server --web-port 8131 -t tool/home_gallery.dart
//   open http://localhost:8131/?s=home|restaurant|empty|hub
import 'package:flutter/material.dart';
import 'package:vinii_pos/home/control_centre_screen.dart';
import 'package:vinii_pos/home/home_api.dart';
import 'package:vinii_pos/home/hub_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

Map<String, dynamic> _summary({String kind = 'store', bool empty = false}) => {
      'person': {'name': 'Riya Sharma', 'role': 'org_owner'},
      'outlet': {'id': 'l1', 'name': 'Latur Main Branch', 'kind': kind, 'is_open': empty ? null : true, 'last_sync_at': DateTime.now().subtract(const Duration(minutes: 2)).toUtc().toIso8601String()},
      'outlets': [{'id': 'l1', 'name': 'Latur Main Branch'}],
      'date': '2026-10-05',
      'as_of': DateTime.now().toUtc().toIso8601String(),
      'sales': empty ? {'total': 0, 'orders': 0, 'settled': 0, 'pax': 0, 'units': 0, 'active': 0} : {'total': 21469, 'orders': 53, 'settled': 25, 'pax': 57, 'units': 140, 'active': 8},
      'catalogue': {'items': 120, 'missing_descriptions': empty ? 0 : 77, 'missing_photos': empty ? 0 : 18, 'missing_recipes': kind == 'restaurant' ? 6 : null},
      'active_orders': empty
          ? []
          : [
              {'id': 'o1', 'number': '2051', 'items': 3, 'total': 340, 'fulfilment': 'pickup', 'status': 'preparing'},
              {'id': 'o2', 'number': '2050', 'items': 7, 'total': 820, 'fulfilment': 'delivery', 'status': 'out_for_delivery', 'eta_minutes': 12},
              {'id': 'o3', 'number': '2049', 'items': 2, 'total': 156, 'fulfilment': 'pickup', 'status': 'new'},
            ],
      'stock_tracked': !empty,
      'stock_health': empty
          ? []
          : [
              {'name': 'Amul Gold / Taaza 1L', 'quantity': 0, 'unit': 'L', 'level': 'out'},
              {'name': 'Boneless Chicken 1kg', 'quantity': 0, 'unit': 'kg', 'level': 'out'},
              {'name': 'Bacon Chicken Pkt', 'quantity': 2, 'unit': 'pkt', 'level': 'low'},
              {'name': 'Tortilla Wrap Pkt', 'quantity': 4, 'unit': 'pkt', 'level': 'low'},
            ],
      'stock_low_count': empty ? 0 : 4,
      'top_items': empty
          ? []
          : [
              {'name': 'Cold Coffee', 'qty': 14, 'revenue': 1620},
              {'name': 'Peri Peri Fries With Cheese', 'qty': 9, 'revenue': 1631},
              {'name': 'Veg Cheesy Pasta', 'qty': 6, 'revenue': 1440},
            ],
      'insights': {'expenses': null, 'kot_not_billed': empty ? 0 : 1, 'grn': {'bills': empty ? 0 : 3, 'amount': empty ? 0 : 25000}, 'price_trend': null},
    };

class _SampleApi extends HomeApi {
  _SampleApi(this.s) : super(accessToken: () => 'gallery');
  final Map<String, dynamic> s;
  @override
  Future<HomeSummary> summary({String? location}) async => HomeSummary(s);
  @override
  Future<HubFeed> feed({int days = 7, bool compare = true, String? location}) async => HubFeed({
        'outlets': [for (var i = 1; i <= 5; i++) {'id': 'l$i', 'name': 'Outlet $i'}],
        'scope': 'All outlets (5)',
        'days': days,
        'today': {'sales': 48920, 'orders': 127, 'is_open': true},
        'period': {'net_sales': 342800, 'orders': 1300, 'orders_completed': 1248, 'aov': 274},
        'previous': compare ? {'net_sales': 306071, 'orders': 1200, 'orders_completed': 1151, 'aov': 277.33} : null,
        'daily': [
          for (var i = 0; i < days; i++)
            {'date': DateTime(2026, 10, 5).subtract(Duration(days: days - 1 - i)).toIso8601String().substring(0, 10), 'sales': [21000, 33000, 29000, 58000, 31000, 32000, 52000][(i + 7 - days % 7) % 7]},
        ],
      });
}

void main() {
  final s = Uri.base.queryParameters['s'] ?? 'home';
  final Widget screen = switch (s) {
    'restaurant' => ControlCentreScreen(api: _SampleApi(_summary(kind: 'restaurant'))),
    'empty' => ControlCentreScreen(api: _SampleApi(_summary(empty: true))),
    'hub' => HubScreen(api: _SampleApi(_summary())),
    _ => ControlCentreScreen(api: _SampleApi(_summary())),
  };
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: posTheme(),
    builder: (context, child) => ColoredBox(
      color: const Color(0xFF1B1F1C),
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 390), child: child)),
    ),
    home: screen,
  ));
}
