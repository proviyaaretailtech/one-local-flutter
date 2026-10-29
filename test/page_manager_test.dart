import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ads/ads_screens.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/storefront/builder_screen.dart';
import 'package:vinii_pos/storefront/growth_screens.dart';
import 'package:vinii_pos/storefront/page_manager_screen.dart';
import 'package:vinii_pos/storefront/settings_screens.dart';

import 'storefront_test.dart' as st;

// Page Manager (founder, 28 Oct 2026; was Business profile): the dashboard of the shop's OneLocal page.

void main() {
  tearDown(HomeNav.reset);

  testWidgets('the dashboard: the shop, how ready the page is, Ads and Offers up front, then every part of the page', (t) async {
    final f = st.Fake();
    await st.show(t, PageManagerScreen(api: f.api));
    expect(find.text('Page Manager'), findsOneWidget);
    for (final k in ['pm-name', 'pm-status', 'pm-progress', 'pm-edit-page', 'pm-share', 'pm-ads', 'pm-offers', 'pm-profile', 'pm-page', 'pm-hours', 'pm-delivery', 'pm-link']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('Grow your sales'), findsOneWidget);
    expect(find.text('Your page'), findsOneWidget);
    expect(find.textContaining('ready'), findsWidgets);
    // it read the page's settings, its status, the offers and the ads
    for (final fn in ['sf_settings_get', 'sf_builder_get', 'sf_offer_list', 'sf_ad_list']) {
      expect(f.calls(fn), isNotEmpty, reason: fn);
    }
  });

  testWidgets('each card opens its screen, and coming back reloads the dashboard', (t) async {
    final f = st.Fake();
    await st.show(t, PageManagerScreen(api: f.api));
    Future<void> openAndBack(String key, Type screen) async {
      await t.ensureVisible(find.byKey(ValueKey(key)));
      await t.tap(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget, reason: key);
      Navigator.of(t.element(find.byType(screen))).pop();
      await t.pumpAndSettle();
    }

    await openAndBack('pm-ads', AdsHomeScreen); // the Ads section, in coins
    await openAndBack('pm-offers', OffersScreen);
    await openAndBack('pm-profile', ProfileScreen);
    await openAndBack('pm-page', StorePageBuilder);
    await openAndBack('pm-hours', HoursScreen);
    await openAndBack('pm-delivery', DeliveryScreen);
    expect(f.calls('sf_settings_get').length, greaterThan(1));
  });

  testWidgets('Reviews shows when the reviews screen is plugged in', (t) async {
    var opened = 0;
    HomeNav.reviews = (_) => opened++;
    final f = st.Fake();
    await st.show(t, PageManagerScreen(api: f.api));
    await t.ensureVisible(find.byKey(const ValueKey('pm-reviews')));
    await t.tap(find.byKey(const ValueKey('pm-reviews')));
    expect(opened, 1);
  });

  testWidgets('ads and offers that the server refuses leave the rest of the dashboard working', (t) async {
    final f = st.Fake((r) => r.url.pathSegments.last == 'sf_ad_list' || r.url.pathSegments.last == 'sf_offer_list' ? st.err(403, 'No access') : null);
    await st.show(t, PageManagerScreen(api: f.api));
    expect(find.text('Start an ad'), findsOneWidget);
    expect(find.text('Add an offer'), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-profile')), findsOneWidget);
  });
}
