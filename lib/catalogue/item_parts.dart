import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';

/// The three parts of the store's Item tab (founder, 25 Oct 2026): products, their stock, and buying them — one place instead of
/// the separate Item, Stock and Purchase sections.
const itemParts = [
  ('products', 'Products', LucideIcons.packageSearch),
  ('stock', 'Stock', LucideIcons.boxes),
  ('purchase', 'Purchase', LucideIcons.truck),
];

/// Which Item part shows, for the screen inside it: [ItemPartSwitcher] reads it and switches through [select].
class ItemParts extends InheritedWidget {
  const ItemParts({super.key, required this.current, required this.select, required super.child});
  final String current;
  final ValueChanged<String> select;

  static ItemParts? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ItemParts>();

  @override
  bool updateShouldNotify(ItemParts old) => old.current != current;
}

/// Products · Stock · Purchase, side by side under the header. Draws nothing outside the Item tab.
class ItemPartSwitcher extends StatelessWidget {
  const ItemPartSwitcher({super.key, this.bottom = 14});
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final parts = ItemParts.maybeOf(context);
    if (parts == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE3E5DF))),
        child: Row(children: [
          for (final (id, label, icon) in itemParts)
            Expanded(
              child: Material(
                color: parts.current == id ? const Color(0xFF111827) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  key: ValueKey('item-part-$id'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => parts.select(id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(icon, size: 16, color: parts.current == id ? const Color(0xFFA1FE2F) : kMuted),
                      const SizedBox(width: 6),
                      Text(label, style: inter(13.5, 700, color: parts.current == id ? const Color(0xFFA1FE2F) : kMuted)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The store's Item tab: one of its three parts at a time, each a full screen that draws the [ItemPartSwitcher] under its header.
/// [parts] builds each part's screen (the app passes the catalogue, stock and purchase screens).
class ItemHome extends StatefulWidget {
  const ItemHome({super.key, required this.parts, this.initial = 'products'});
  final Map<String, WidgetBuilder> parts;
  final String initial;

  /// Asks the Item tab to show a part from elsewhere (Home's "stock" links, for example): set it, then switch to Item.
  static final requested = ValueNotifier<String?>(null);

  @override
  State<ItemHome> createState() => _ItemHomeState();
}

class _ItemHomeState extends State<ItemHome> {
  late String _part = widget.parts.containsKey(ItemHome.requested.value) ? ItemHome.requested.value! : (widget.parts.containsKey(widget.initial) ? widget.initial : 'products');

  void _asked() {
    final p = ItemHome.requested.value;
    if (p != null && widget.parts.containsKey(p) && mounted) setState(() => _part = p);
  }

  @override
  void initState() {
    super.initState();
    ItemHome.requested.addListener(_asked);
  }

  @override
  void dispose() {
    ItemHome.requested.removeListener(_asked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ItemParts(
        current: _part,
        select: (p) => setState(() => _part = p),
        child: KeyedSubtree(key: ValueKey(_part), child: Builder(builder: widget.parts[_part]!)),
      );
}
