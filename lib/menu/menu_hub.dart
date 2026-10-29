import 'package:flutter/material.dart';

import '../outlets/outlet_header.dart';
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'ingredients_screen.dart';
import 'menu_api.dart';
import 'menu_build_api.dart';
import 'menu_build_widgets.dart';
import 'menu_screen.dart';
import 'recipes_screen.dart';

/// The restaurant Menu tab (founder sketch, 26 Oct 2026): the banner, then three sub-masters on top.
///   * Menu: dishes by category (quick add → detailed view → detailed settings), add-ons and combos;
///   * Recipe: each dish's ingredients with live cost, food cost % and margin;
///   * Ingredients: what the kitchen uses, its cost and stock, from a preloaded library or typed in, bought from suppliers.
/// The three are kept alive while switching, so a search or a scroll position is not lost.
class MenuHub extends StatefulWidget {
  const MenuHub({super.key, this.menuApi, this.buildApi, this.initial = 0});
  final MenuApi? menuApi;
  final MenuBuildApi? buildApi;
  final int initial;

  /// A sub-master asked for from elsewhere (the side bar's Inventory → Recipe / Ingredients): 1 Recipe, 2 Ingredients.
  static final requestedTab = ValueNotifier<int?>(null);
  @override
  State<MenuHub> createState() => _MenuHubState();
}

class _MenuHubState extends State<MenuHub> {
  late int _tab = widget.initial;
  late final MenuBuildApi _build = widget.buildApi ?? MenuBuildApi();
  final _built = <int>{};

  // A filter asked for from elsewhere (Notification Centre → "Add images to items") belongs to the Menu sub-master: show it.
  @override
  void initState() {
    super.initState();
    if (MenuScreen.requestedFilter.value != null) _tab = 0;
    MenuScreen.requestedFilter.addListener(_toMenu);
    if (MenuHub.requestedTab.value != null) {
      _tab = MenuHub.requestedTab.value!;
      MenuHub.requestedTab.value = null;
    }
    MenuHub.requestedTab.addListener(_toTab);
  }

  void _toTab() {
    final t = MenuHub.requestedTab.value;
    if (t == null || !mounted) return;
    MenuHub.requestedTab.value = null;
    if (t != _tab) setState(() => _tab = t);
  }

  void _toMenu() {
    if (MenuScreen.requestedFilter.value != null && mounted && _tab != 0) setState(() => _tab = 0);
  }

  @override
  void dispose() {
    MenuScreen.requestedFilter.removeListener(_toMenu);
    MenuHub.requestedTab.removeListener(_toTab);
    super.dispose();
  }

  Widget _page(int i) => switch (i) {
        0 => MenuScreen(api: widget.menuApi, buildApi: _build, embedded: true),
        1 => RecipesView(api: _build),
        _ => IngredientsView(api: _build),
      };

  @override
  Widget build(BuildContext context) {
    _built.add(_tab);
    return Scaffold(
      backgroundColor: kBg,
      body: Column(children: [
        // opened on top (Recipe or Ingredients from the side bar): the green banner with the round ←; as a tab: the outlet header
        if (ModalRoute.of(context)?.canPop ?? false)
          AppHeader(title: const ['Menu', 'Recipe', 'Ingredients'][_tab])
        else
          const OutletHeader(title: 'Menu', allowAll: false, menuKey: ValueKey('menu-side-nav')),
        SubMasterTabs(labels: const ['Menu', 'Recipe', 'Ingredients'], selected: _tab, onSelect: (i) => setState(() => _tab = i)),
        Expanded(
          child: IndexedStack(index: _tab, children: [
            // a sub-master is built the first time it is opened, then kept
            for (var i = 0; i < 3; i++) _built.contains(i) ? _page(i) : const SizedBox.shrink(),
          ]),
        ),
      ]),
    );
  }
}
