import 'package:flutter/material.dart';

import 'guest/guest_api.dart';
import 'guest/guest_app.dart';
import 'guest/guest_link_io.dart' if (dart.library.js_interop) 'guest/guest_link_web.dart' as link;

/// The guest menu web page: what a customer's phone opens after scanning a table's QR code (`<server>/t/<code>`), and the restaurant's brand
/// page (`onelocal.co/<store link>`, also `/r/<store link>` and the older public menu link `/m/<store link>`): the same screens, with no
/// sign-in. The brand page has no table: dine-in there means scanning the table's code, and a pre-order goes through its own door; a
/// pre-order's tracking link is the brand page with `?track=<token>`.
/// Built on its own (`tool/build_guest_web.sh`: `flutter build web -t lib/guest_web_main.dart --base-href /t/`) and served by the POS gateway,
/// which also answers its calls (`POST /guest/<name>`), so the page needs no key, no sign-in and no other address.
/// `--dart-define=GUEST_API_BASE_URL` points it at another gateway (development only).
/// Orders (specs/guest-experience-builder part 2, contract A) go to the customer server: `--dart-define=CUSTOMER_API_BASE_URL` (empty = the
/// POS guest door as before), by default `http://localhost:8099` on this machine and the page's own host with `/api` online. The page keeps
/// a random device key for it in localStorage, and a sent order's tracking token in its address (`?track=`, on a table QR page too).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GuestWebPage(
    code: tableCodeFrom(Uri.base),
    slug: menuSlugFrom(Uri.base),
    track: trackFrom(Uri.base),
    onTrackLink: link.rememberTrackLink,
    prefs: link.browserPrefs(),
  ));
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

/// Names OneLocal's own pages use, which are never a store link (the server's RESERVED_SLUGS, the database's gx__reserved_slug).
const _reserved = {
  'privacy', 'terms', 'delete-account', 'join', 'auth', 'api', 'm', 't', 'b', 'r', 'guest', 'rpc', 'health', 'admin', 'partner', 'partners',
  'app', 'static', 'assets', 'www', 'help', 'support', 'about', 'login', 'signup', 'signin', 'onelocal', 'source', 'ol-api', 'webhooks',
  'download', 'blog', 'careers', 'contact', 'master', 'rider', 'riders', 'store', 'stores',
};

/// The restaurant's store link in the page address: `/<slug>`, `/r/<slug>` or `/m/<slug>` (or `#/m/<slug>`, `#/r/<slug>`).
String? menuSlugFrom(Uri u) {
  bool ok(String? s) => s != null && RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(s);
  for (final segs in [u.pathSegments, u.fragment.split('/')]) {
    final list = segs.where((s) => s.isNotEmpty).map((s) => s.toLowerCase()).toList();
    for (final word in const ['m', 'r']) {
      final i = list.indexOf(word);
      if (i >= 0 && i + 1 < list.length && ok(list[i + 1])) return list[i + 1];
    }
  }
  // the brand page itself: one path segment that is not one of OneLocal's own pages
  final path = u.pathSegments.where((s) => s.isNotEmpty).map((s) => s.toLowerCase()).toList();
  return path.length == 1 && ok(path.single) && !_reserved.contains(path.single) ? path.single : null;
}

/// A tracking token in the page address (`?track=<36 hex>`): a pre-order's, or a web order's (brand page or table QR).
String? trackFrom(Uri u) {
  final t = u.queryParameters['track']?.toLowerCase();
  return t != null && RegExp(r'^[0-9a-f]{36}$').hasMatch(t) ? t : null;
}

class GuestWebPage extends StatelessWidget {
  const GuestWebPage({
    super.key,
    required this.code,
    this.slug,
    this.track,
    this.gateway,
    this.preorders,
    this.orders,
    this.feed,
    this.prefs,
    this.onTrackLink,
  });
  final String? code;

  /// The brand page's restaurant (no table).
  final String? slug;

  /// A tracking token from the page address: the page opens on that order (or pre-order).
  final String? track;
  final GuestGateway? gateway;
  final PreorderDoor? preorders;

  /// The customer server's order door; by default the one [customerApiBaseFor] finds for this page (none: the POS guest door as before).
  final WebOrderDoor? orders;

  /// The live order feed; by default the POS guest door's `feed`.
  final LiveFeedDoor? feed;

  /// This browser's little memory (the device key, Live mode); memory only when null.
  final GuestPrefs? prefs;
  final ValueChanged<String>? onTrackLink;

  @override
  Widget build(BuildContext context) {
    const base = String.fromEnvironment('GUEST_API_BASE_URL');
    // the POS gateway that serves this page (none for a page that is not on http(s), as in tests)
    final page = Uri.base;
    final origin = base.isNotEmpty ? base : (page.isScheme('http') || page.isScheme('https') ? page.origin : null);
    final brand = code == null && slug != null;
    final memory = prefs ?? MemoryGuestPrefs();
    final customer = customerApiBaseFor(page);
    final orderDoor = orders ?? (customer == null ? null : CustomerOrderGateway(baseUrl: customer, prefs: memory));
    final feedDoor = feed ?? (origin == null ? null : LiveFeedGateway(baseUrl: origin));
    return MaterialApp(
      title: brand ? 'Menu' : 'Order at your table',
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
              gateway: gateway ?? (code != null ? WebGuestGateway(code: code!, baseUrl: origin) : MenuCardGateway(slug: slug!, baseUrl: origin)),
              preorders: brand ? preorders ?? PreorderGateway(slug: slug!, baseUrl: origin) : null,
              orders: orderDoor,
              feed: feedDoor,
              prefs: memory,
              storeLink: slug,
              track: brand || orderDoor != null ? track : null,
              onTrackLink: onTrackLink,
            ),
    );
  }
}
