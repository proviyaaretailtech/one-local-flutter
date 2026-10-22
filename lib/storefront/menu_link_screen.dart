import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/rpc_client.dart';
import '../home/home_nav.dart';
import '../home/home_widgets.dart' show kRed;
import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart' show OrdersTopBar;
import '../ui/theme.dart';

/// The business's public menu link (database 0571, `menu_link_get`): anyone who opens it sees the published menu, with no sign-in and no
/// table. The database says whether it is live and why not; this screen only shows that and the link.
class MenuLinkApi {
  MenuLinkApi({RpcClient? rpc}) : _rpc = rpc ?? RpcClient();
  final RpcClient _rpc;

  Future<Facts> get() async => Facts(await _rpc.callMap('menu_link_get'));

  /// `<guest web base>/m/<slug>`: the same base the table QR codes print ([GUEST_WEB_BASE_URL], else the POS server the app talks to).
  static String urlFor(String path, {String? base}) {
    const web = String.fromEnvironment('GUEST_WEB_BASE_URL');
    const api = String.fromEnvironment('PARTNER_API_BASE_URL');
    final b = (base ?? (web.isNotEmpty ? web : api)).replaceAll(RegExp(r'/+$'), '');
    return '$b$path';
  }
}

/// Plain words for each reason the database gives (guest__public_blockers).
const menuLinkReasons = {
  'no_store_link': 'Choose your store link in the page builder (Business Profile).',
  'not_published': 'Publish your menu in the OneLocal page builder.',
  'not_approved': 'OneLocal has not approved your business yet.',
  'not_active': 'Your business is not active yet.',
  'no_outlet': 'Your outlet is not open on OneLocal.',
};

class MenuLinkScreen extends StatefulWidget {
  const MenuLinkScreen({super.key, this.api, this.linkBase, this.onOpen});
  final MenuLinkApi? api;
  final String? linkBase;

  /// Opens the link in the browser; swappable for tests.
  final Future<void> Function(Uri uri)? onOpen;

  @override
  State<MenuLinkScreen> createState() => _MenuLinkScreenState();
}

class _MenuLinkScreenState extends State<MenuLinkScreen> {
  late final _api = widget.api ?? MenuLinkApi();
  Facts? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.get();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e is RpcException ? e.message : 'Could not load your menu link. Please try again.');
    }
  }

  Timer? _back;

  @override
  void dispose() {
    _back?.cancel();
    super.dispose();
  }

  /// Opens the page builder, then reads the link again once the person is back on this screen (publishing changes it).
  void _openBuilder() {
    HomeNav.storefront!(context);
    _back?.cancel();
    _back = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (!mounted) return t.cancel();
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        t.cancel();
        _load();
      }
    });
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final live = d?.b('live') ?? false;
    final path = d?.so('path');
    final url = path == null ? '' : MenuLinkApi.urlFor(path, base: widget.linkBase);
    final reasons = d?.ls('blockers') ?? const <String>[];
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrdersTopBar(title: 'Menu link', onBack: () => Navigator.of(context).maybePop()),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Text('Your public menu', style: inter(24, 800)),
                  const SizedBox(height: 6),
                  Text(
                    'Anyone with this link sees your published menu. No app, no sign-in. Ordering stays on your table QR codes.',
                    style: inter(14, 400, color: kMuted),
                  ),
                  const SizedBox(height: 18),
                  if (d == null && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator(color: kLink)),
                    ),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      key: const ValueKey('menu-link-error'),
                      style: inter(15, 500, color: kRed),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('Try again')),
                  ],
                  if (d != null) ...[
                    Container(
                      key: ValueKey(live ? 'menu-link-live' : 'menu-link-off'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: live ? kNote : const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(14)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(live ? LucideIcons.circleCheck : LucideIcons.circleAlert, color: live ? kLink : const Color(0xFFB45309), size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(live ? 'Your menu is live' : 'Not live yet', style: inter(16, 700)),
                                for (final r in reasons)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(menuLinkReasons[r] ?? r, style: inter(14, 400, color: kMuted)),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!live && (reasons.contains('not_published') || reasons.contains('no_store_link')) && HomeNav.storefront != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('menu-link-publish'),
                        onPressed: _openBuilder,
                        icon: const Icon(LucideIcons.globe, size: 18),
                        label: const Text('Open the page builder'),
                      ),
                    ],
                    if (url.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Center(
                        child: Opacity(
                          opacity: live ? 1 : 0.35,
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: kLine),
                            ),
                            child: QrImageView(key: const ValueKey('menu-link-qr'), data: url, size: 220, backgroundColor: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        url,
                        key: const ValueKey('menu-link-url'),
                        textAlign: TextAlign.center,
                        style: inter(14, 600, color: kInk),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const ValueKey('menu-link-copy'),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: url));
                                if (mounted) _say('Link copied.');
                              },
                              icon: const Icon(LucideIcons.copy, size: 18),
                              label: const Text('Copy link'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey('menu-link-open'),
                              style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white),
                              onPressed: live ? () => (widget.onOpen ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(Uri.parse(url)) : null,
                              icon: const Icon(LucideIcons.externalLink, size: 18),
                              label: const Text('Open menu'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
