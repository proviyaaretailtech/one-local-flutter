import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../ui/theme.dart';

/// Floating stacked bars for the tables (founder, 27 Oct 2026; the till's "Current Cart #1 · 9 on hold" look): the front bar is one
/// table, the other tables' bars peek out behind it, each table in its own colour. ⌃ fans the deck out into one bar per table; tapping
/// a bar brings that table to the front and opens it. Up to [max] tables (the first ones on the floor, in their floor order).
class TableDeck extends StatefulWidget {
  const TableDeck({super.key, required this.tables, required this.onOpen, this.max = 5});
  final List<Facts> tables;
  final ValueChanged<Facts> onOpen;
  final int max;

  /// One colour per table, by its place in the deck (green, red, orange, blue, purple).
  static const colors = [
    (Color(0xFF15803D), Color(0xFF22A355)),
    (Color(0xFFB91C1C), Color(0xFFE0483A)),
    (Color(0xFFC2410C), Color(0xFFF08A24)),
    (Color(0xFF1D4ED8), Color(0xFF3B82F6)),
    (Color(0xFF6D28D9), Color(0xFF8B5CF6)),
  ];

  @override
  State<TableDeck> createState() => _TableDeckState();
}

class _TableDeckState extends State<TableDeck> {
  int _front = 0;
  bool _open = false;

  List<Facts> get _deck => widget.tables.take(widget.max).toList();

  static String status(Facts t) {
    final mins = t.n('elapsed_minutes').toInt();
    return switch (t.s('status')) {
      'occupied' => mins > 0 ? 'Occupied · ${mins}m' : 'Occupied',
      'reserved' => 'Reserved',
      'cleaning' => 'Cleaning',
      _ => 'Available',
    };
  }

  void _pick(int i) {
    setState(() {
      _front = i;
      _open = false;
    });
    widget.onOpen(_deck[i]);
  }

  @override
  Widget build(BuildContext context) {
    final deck = _deck;
    if (deck.isEmpty) return const SizedBox.shrink();
    final front = _front.clamp(0, deck.length - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: _open
            // fanned out: every table's bar, the front one last (closest to the thumb)
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                for (final i in [for (var j = 0; j < deck.length; j++) if (j != front) j, front])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _Bar(
                      key: ValueKey('deck-bar-${deck[i].s('label')}'),
                      table: deck[i],
                      colors: TableDeck.colors[i % TableDeck.colors.length],
                      status: status(deck[i]),
                      onTap: () => _pick(i),
                      toggleIcon: i == front ? LucideIcons.chevronsDown : null,
                      onToggle: () => setState(() => _open = false),
                    ),
                  ),
              ])
            // stacked: the front table, with up to two other tables' bars peeking out above it
            : SizedBox(
                height: 64 + (deck.length > 2 ? 14 : deck.length > 1 ? 7 : 0),
                child: Stack(clipBehavior: Clip.none, children: [
                  for (final (k, i) in [for (var j = 1; j < deck.length; j++) (front + j) % deck.length].take(2).toList().reversed.indexed)
                    Positioned(
                      left: k == 0 && deck.length > 2 ? 20 : 10,
                      right: k == 0 && deck.length > 2 ? 20 : 10,
                      top: k == 0 && deck.length > 2 ? 0 : (deck.length > 2 ? 7 : 0),
                      height: 64,
                      child: DecoratedBox(
                        key: ValueKey('deck-peek-${deck[i].s('label')}'),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [TableDeck.colors[i % TableDeck.colors.length].$1, TableDeck.colors[i % TableDeck.colors.length].$2]),
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 64,
                    child: _Bar(
                      key: ValueKey('deck-front-${deck[front].s('label')}'),
                      table: deck[front],
                      colors: TableDeck.colors[front % TableDeck.colors.length],
                      status: status(deck[front]),
                      onTap: () => widget.onOpen(deck[front]),
                      toggleIcon: deck.length > 1 ? LucideIcons.chevronsUp : null,
                      onToggle: () => setState(() => _open = true),
                      shadow: true,
                    ),
                  ),
                ]),
              ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({super.key, required this.table, required this.colors, required this.status, required this.onTap, this.toggleIcon, this.onToggle, this.shadow = false});
  final Facts table;
  final (Color, Color) colors;
  final String status;
  final VoidCallback onTap;
  final IconData? toggleIcon;
  final VoidCallback? onToggle;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    // the "9 on hold" pill is orange; on a red or orange bar it turns white so it still stands out
    final warmBar = colors == TableDeck.colors[1] || colors == TableDeck.colors[2];
    final pillBg = warmBar ? Colors.white : const Color(0xFFF97316);
    final pillFg = warmBar ? colors.$1 : Colors.white;
    return Semantics(
      button: true,
      label: 'Table ${table.s('label')}, ${table.n('seats').toInt()} seats, $status',
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: 64,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [colors.$1, colors.$2]),
            borderRadius: BorderRadius.circular(22),
            boxShadow: shadow ? const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 4))] : null,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: const Icon(LucideIcons.utensilsCrossed, size: 19, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Table', style: inter(12, 500, color: Colors.white.withValues(alpha: 0.8))),
                    Text('${table.s('label')} · ${table.n('seats').toInt()} Pax', maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(18, 800, color: Colors.white)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(999)),
                  child: Text(status, style: inter(13, 700, color: pillFg)),
                ),
                if (toggleIcon != null)
                  IconButton(
                    key: ValueKey('deck-toggle-${table.s('label')}'),
                    tooltip: toggleIcon == LucideIcons.chevronsUp ? 'Show all tables' : 'Close',
                    onPressed: onToggle,
                    icon: Icon(toggleIcon, color: Colors.white, size: 22),
                  )
                else
                  const SizedBox(width: 8),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
