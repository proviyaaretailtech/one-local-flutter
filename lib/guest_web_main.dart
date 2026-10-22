import 'package:flutter/material.dart';

import 'guest/guest_api.dart';
import 'guest/guest_app.dart';

/// The guest menu web page: what a customer's phone opens after scanning a table's QR code (`<server>/t/<code>`), and the business's public
/// menu link (`<server>/m/<slug>`): the same screens, read-only, with no sign-in and no table.
/// Built on its own (`tool/build_guest_web.sh`: `flutter build web -t lib/guest_web_main.dart --base-href /t/`) and served by the POS gateway,
/// which also answers its calls (`POST /guest/<name>`), so the page needs no key, no sign-in and no other address.
/// `--dart-define=GUEST_API_BASE_URL` points it at another gateway (development only).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GuestWebPage(code: tableCodeFrom(Uri.base), slug: menuSlugFrom(Uri.base)));
}

/// The table code in the page address: `/t/<code>` (a `#/t/<code>` or `?t=<code>` address works too).
String? tableCodeFrom(Uri u) {
  bool ok(String? s) => s != null && RegExp(r'^[0-9a-f]{32,128}$').hasMatch(s);
  final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
  final i = segs.indexOf('t');
  if (i >= 0 && i + 1 < segs.length && ok(segs[i + 1])) return segs[i + 1];
  final frag = u.fragment.split('/').where((s) => s.isNotEmpty).toList();
  final j = frag.indexOf('t');
  if (j >= 0 && j + 1 < frag.length && ok(frag[j + 1])) return frag[j + 1];
  return ok(u.queryParameters['t']) ? u.queryParameters['t'] : null;
}

/// The business's address name in a public menu link: `/m/<slug>` (or `#/m/<slug>`).
String? menuSlugFrom(Uri u) {
  bool ok(String? s) => s != null && RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(s);
  for (final segs in [u.pathSegments, u.fragment.split('/')]) {
    final list = segs.where((s) => s.isNotEmpty).toList();
    final i = list.indexOf('m');
    if (i >= 0 && i + 1 < list.length && ok(list[i + 1].toLowerCase())) return list[i + 1].toLowerCase();
  }
  return null;
}

class GuestWebPage extends StatelessWidget {
  const GuestWebPage({super.key, required this.code, this.slug, this.gateway});
  final String? code;

  /// The public menu link's business (no table): the read-only menu card.
  final String? slug;
  final GuestGateway? gateway;

  @override
  Widget build(BuildContext context) {
    const base = String.fromEnvironment('GUEST_API_BASE_URL');
    return MaterialApp(
      title: code == null && slug != null ? 'Menu' : 'Order at your table',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: 'Inter'),
      builder: (context, child) => ColoredBox(
        color: const Color(0xFF1B1F1C),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: child)),
      ),
      home: code == null && slug == null && gateway == null
          ? const Scaffold(
              key: ValueKey('guest-no-code'),
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text('Scan the QR code on your table to see the menu and order.', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
            )
          : GuestApp(
              gateway: gateway ??
                  (code != null
                      ? WebGuestGateway(code: code!, baseUrl: base.isEmpty ? Uri.base.origin : base)
                      : MenuCardGateway(slug: slug!, baseUrl: base.isEmpty ? Uri.base.origin : base)),
            ),
    );
  }
}
