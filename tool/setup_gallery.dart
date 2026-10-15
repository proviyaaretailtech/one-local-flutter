// Dev only: shows one workspace-setup screen (Figma section C) with sample data, to compare with assets/figma_ref_c.
// flutter run -d web-server --web-port 8095 -t tool/setup_gallery.dart
//   open http://localhost:8095/?s=dashboard|plan|payment|tax|pos|staff|catalogue|listing|delivery|complete[&tour=0]
import 'package:flutter/material.dart';
import 'package:vinii_pos/setup/business_screens.dart';
import 'package:vinii_pos/setup/operations_screens.dart';
import 'package:vinii_pos/setup/setup_api.dart';
import 'package:vinii_pos/setup/setup_flow.dart';
import 'package:vinii_pos/setup/storefront_screens.dart';
import 'package:vinii_pos/ui/theme.dart';

SetupState sample({bool tour = true}) {
  Map<String, dynamic> row(String key, String title, bool req, bool done, [String? note]) =>
      {'key': key, 'title': title, 'required': req, 'done': done, 'status': done ? 'completed' : (req ? 'pending' : 'optional'), 'note': ?note};
  return SetupState({
    'organization': {'id': 'o1', 'name': 'Sharma General Store', 'partner_type': 'store', 'sell_plan': 'pos_and_onelocal'},
    'checklist': [
      row('business_profile', 'Business Profile', true, true),
      row('location', 'Location', true, true),
      row('owner_details', 'Owner Details', true, true),
      row('plan', 'Plan & Subscription', true, true),
      row('catalogue', 'Catalogue', true, false),
      row('payment', 'Payment Setup', true, false),
      row('staff', 'Staff', false, false, 'Optional'),
      row('inventory', 'Inventory', false, false, 'Optional'),
      row('onelocal_profile', 'OneLocal Profile', true, false),
      row('pos', 'POS Setup', true, false),
      row('delivery', 'Delivery / Fulfilment', false, false, 'When applicable'),
    ],
    'progress': {'done': 4, 'total': 8, 'next': 'catalogue', 'can_complete': false, 'completed': false},
    'tour_seen': tour ? <int>[] : [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    'plan': {'selected_code': 'retail_starter', 'confirmed': true, 'sell_plan': 'pos_and_onelocal', 'available': [
      {'code': 'retail_starter', 'name': 'Retail Starter', 'cadence': 'Monthly', 'price': 0, 'users_limit': 2, 'locations_limit': 1,
       'modules': ['POS billing', 'Catalogue', 'Payments', 'OneLocal listing']},
    ]},
    'payment': {'saved': false, 'holder_name': '', 'account_masked': null, 'bank_status': null, 'accept_upi': false, 'accept_card': false},
    'tax': {'saved': false, 'gst_registered': null, 'invoice_prefix': 'INV', 'prices_include_tax': true, 'show_address_on_receipt': true, 'show_gstin_on_invoice': true},
    'pos': {'required': true, 'registered': false, 'devices': [], 'kot_allowed': false},
    'staff': {'invites': [], 'roles': ['cashier', 'manager']},
    'catalogue': {'items': 0, 'names_done': false, 'prices_done': false, 'categories': []},
    'listing': {'saved': false, 'public_name': '', 'description': null, 'address_line': '', 'open_days': null},
    'fulfilment': {'saved': false, 'pickup': true, 'self_delivery': true, 'onelocal_delivery': false, 'delivery_hours': 'same_as_opening'},
  });
}

class _FakeApi extends SetupApi {
  _FakeApi(this.s) : super(accessToken: () => 'x', baseUrl: 'http://localhost');
  final SetupState s;
  @override
  Future<SetupState> get() async => s;
  @override
  Future<SetupState> tourSeen(int step) async => s;
}

void main() {
  final q = Uri.base.queryParameters;
  final s = sample(tour: q['tour'] != '0');
  final api = _FakeApi(s);
  final done = SetupState({...s.raw, 'progress': {'done': 8, 'total': 8, 'can_complete': true, 'completed': true}});
  final screens = <String, Widget>{
    'dashboard': SetupDashboardScreen(api: api, initial: s, onFinished: (_) {}),
    'plan': PlanScreen(api: api, state: s),
    'payment': PaymentScreen(api: api, state: s),
    'tax': TaxScreen(api: api, state: s),
    'pos': PosScreen(api: api, state: s),
    'staff': StaffScreen(api: api, state: s),
    'catalogue': CatalogueScreen(api: api, state: s),
    'listing': ListingScreen(api: api, state: s),
    'delivery': FulfilmentScreen(api: api, state: s),
    'complete': SetupCompleteScreen(api: api, state: done, onFinished: (_) {}),
  };
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screens[q['s']] ?? screens['dashboard']));
}
