import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import '../home/home_nav.dart';
import 'outlet_status_screen.dart';
import 'outlets_api.dart';

const kOutletOnline = Color(0xFF16A34A);
const kOutletPaused = Color(0xFFD97706);
const kOutletChipBg = Color(0xFFE9F9DC);
const kOutletChipText = Color(0xFF14532D);
const kOutletSquare = Color(0xFFF3F4F6);

/// Colour of an outlet status word (D7 in specs/outlets-multi/spec.md).
Color outletStatusColor(String status) => switch (status) {
      'online' => kOutletOnline,
      'paused' || 'pending' => kOutletPaused,
      'rejected' => kError,
      _ => kMuted,
    };

String outletInitials(String name) {
  final parts = name.trim().split(RegExp(r'[\s@._]+')).where((p) => p.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(p[0])).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// The one top header of every main screen once a partner is onboarded (Figma `screen-pos-orders`): ☰, the outlet's name, its live
/// status from the server (Online / Offline / Paused), the "All online ›" chip that sums up every outlet, and the person's initials.
/// Tapping the name or the chip opens Restaurant status. While the server has not answered (or cannot be reached) it shows [title], so
/// the screen is never blank.
class OutletHeader extends StatefulWidget {
  const OutletHeader({super.key, required this.title, this.onMenu, this.locationId, this.safeTop = true, this.rounded = false, this.menuKey = const ValueKey('outlet-header-menu'), this.initials});

  /// Shown until the outlet is known.
  final String title;
  final VoidCallback? onMenu;

  /// The outlet the screen works in, when it has its own picker (restaurant dashboard). Otherwise the server's default outlet.
  final String? locationId;

  /// Adds the status-bar inset (for screens without a SafeArea above the header).
  final bool safeTop;

  /// Rounded bottom corners, for the section top bars that had them.
  final bool rounded;

  /// The person's initials the screen already knows, shown until the server names the person.
  final String? initials;

  /// Key of the ☰ button (screens keep the key their tests already use).
  final Key menuKey;

  /// Where the header reads from. Tests replace it.
  static OutletsApi Function() api = OutletsApi.new;

  /// One read shared by every header on screen; [refresh] drops it after a change (a toggle, a new outlet).
  static final Map<String, Future<OutletOverview>> _cache = {};
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static void refresh() {
    _cache.clear();
    changes.value++;
  }

  static Future<OutletOverview> load([String? locationId]) =>
      _cache.putIfAbsent(locationId ?? '', () => api().list(locationId: locationId)..catchError((Object _) {
            _cache.remove(locationId ?? '');
            return const OutletOverview({});
          }));

  /// Opens Restaurant status; every header reloads when it closes.
  static Future<void> openStatus(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OutletStatusScreen(api: api())));
    refresh();
  }

  @override
  State<OutletHeader> createState() => _OutletHeaderState();
}

class _OutletHeaderState extends State<OutletHeader> {
  late Future<OutletOverview> _f;

  @override
  void initState() {
    super.initState();
    _f = OutletHeader.load(widget.locationId);
    OutletHeader.changes.addListener(_reload);
  }

  @override
  void didUpdateWidget(OutletHeader old) {
    super.didUpdateWidget(old);
    if (old.locationId != widget.locationId) _f = OutletHeader.load(widget.locationId);
  }

  @override
  void dispose() {
    OutletHeader.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _f = OutletHeader.load(widget.locationId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OutletOverview>(
      future: _f,
      builder: (context, snap) {
        final o = snap.hasError ? null : snap.data;
        final cur = o?.current;
        final name = cur?.name.isNotEmpty == true ? cur!.name : widget.title;
        return Container(
          padding: EdgeInsets.fromLTRB(16, (widget.safeTop ? MediaQuery.paddingOf(context).top : 0) + 10, 16, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: widget.rounded ? const BorderRadius.vertical(bottom: Radius.circular(28)) : null,
            border: widget.rounded ? null : const Border(bottom: BorderSide(color: kLine)),
          ),
          child: Row(children: [
            Semantics(
              button: true,
              label: 'Menu',
              child: InkWell(
                key: widget.menuKey,
                borderRadius: BorderRadius.circular(12),
                onTap: widget.onMenu ?? () => HomeNav.go(context, HomeNav.home, 'Menu'),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: kOutletSquare, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(LucideIcons.menu, size: 20, color: kInk),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                button: cur != null,
                label: cur == null ? null : 'Outlet ${cur.name}, ${cur.statusLabel}. Open restaurant status',
                excludeSemantics: cur != null,
                child: InkWell(
                  key: const ValueKey('outlet-header-name'),
                  onTap: cur == null ? null : () => OutletHeader.openStatus(context),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(17, 700)),
                    if (cur != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: outletStatusColor(cur.status), shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(cur.statusLabel,
                                key: const ValueKey('outlet-header-status'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: inter(13, 600, color: outletStatusColor(cur.status))),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ),
            ),
            if (o != null && o.chip.isNotEmpty) ...[
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: '${o.chip}. Open restaurant status',
                excludeSemantics: true,
                child: InkWell(
                  key: const ValueKey('outlet-header-chip'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => OutletHeader.openStatus(context),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                    decoration: BoxDecoration(color: kOutletChipBg, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(o.chip, style: inter(11, 600, color: kOutletChipText)),
                      const Icon(LucideIcons.chevronRight, size: 12, color: kOutletChipText),
                    ]),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: kOutletSquare, shape: BoxShape.circle),
              child: Text(o == null || o.personName.isEmpty ? (widget.initials ?? '') : outletInitials(o.personName), style: inter(13, 700)),
            ),
          ]),
        );
      },
    );
  }
}
