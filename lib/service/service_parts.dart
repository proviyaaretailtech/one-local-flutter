import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_widgets.dart' show numberOnly;

// The pieces the template editor and the one Add service form share (founder, 3 Nov 2026: "like a restaurant's recipe master"): the
// categories, compact dropdown boxes, and the two row editors — what a service needs (a person, a place, a tool, a material, anything
// else, picked from dropdowns with how many) and its rules (any category the publisher picks, a condition and a result).

// ============================================================================================================ categories

class ListingCategory {
  const ListingCategory(this.key, this.name, this.books, this.icon, this.subcategories);
  final String key, name, books;
  final IconData icon;
  final List<(String group, List<String> names)> subcategories;
  List<String> get allSubcategories => [for (final (_, n) in subcategories) ...n];
}

// Dining is not part of the Service POS (founder, 4 Nov 2026); restaurants have their own POS.
const listingCategories = [
  ListingCategory('events', 'Events', 'Places per event, up to capacity', LucideIcons.ticket, [
    ('', ['Stand-up comedy', 'Live music', 'Workshop', 'Screening', 'Exhibition', 'Kids party venue', 'Party hall and banquet', 'Event planning', 'Event decoration']),
  ]),
  ListingCategory('activities', 'Activities', 'Time slot for a group', LucideIcons.gamepad2, [
    ('Games', ['Gaming zone and arcade', 'Bowling', 'Escape room', 'VR gaming', 'Trampoline park', 'Go-karting', 'Paintball']),
    ('Visits', ['Museum visit', 'Farm and nature visit', 'Amusement and water park', 'Guided tour']),
  ]),
  ListingCategory('play', 'Play', 'Court, turf or table by the hour', LucideIcons.trophy, [
    ('', ['Football turf', 'Box cricket', 'Cricket nets', 'Basketball court', 'Badminton court', 'Tennis court', 'Pickleball court', 'Volleyball court', 'Squash court',
      'Table tennis table', 'Snooker and pool table', 'Swimming lane', 'Indoor arena']),
  ]),
  ListingCategory('service', 'Service', 'Appointment with a provider', LucideIcons.scissors, [
    ('Doctors', ['General physician', 'Dentist', 'Orthodontist', 'Paediatrician', 'Dermatologist', 'Gynaecologist', 'Eye specialist', 'Physiotherapist', 'Dietitian']),
    ('Vehicle breakdown', ['Garage service appointment', 'Puncture repair', 'Battery jump-start', 'Roadside assistance', 'Towing']),
    ('Salon', ["Men's salon", "Women's salon", 'Unisex salon', 'Beauty parlour', 'Spa', 'Makeup artist', 'Mehendi artist']),
    ('Professional', ['CA and tax', 'Lawyer', 'Counsellor', 'Digital solutions', 'Financial advisor', 'Architect and interior']),
    ('Home and repairs', ['Cleaning', 'Plumbing', 'Electrical', 'Appliance and AC repair', 'Pest control', 'Carpentry', 'Painting']),
    ('Pets and wellness', ['Pet grooming', 'Fitness trainer', 'Yoga', 'Massage']),
    ('Printing', ['Printing']),
  ]),
  ListingCategory('stay', 'Stay', 'Rooms by the night', LucideIcons.bedDouble, [
    ('', ['Hotel', 'Bed and breakfast', 'Homestay', 'Guest house', 'Resort', 'Farmhouse', 'Hostel and dormitory', 'Day-use room']),
  ]),
];

/// What one subcategory's form asks for and starts with (founder, 4 Nov 2026: "check they're relevant to the subcategories"): how it is
/// booked, what customers book (empty: no units), the surfaces a unit can have (empty: none), its amenities, where it happens (empty:
/// at the venue, not asked), and how it is priced. The form shows only these; a change of subcategory resets to its defaults.
class ListingProfile {
  const ListingProfile({
    required this.bookingTypes,
    this.unitKinds = const [],
    this.surfaces = const [],
    this.settings = const ['Indoor', 'Outdoor', 'Covered'],
    this.parts = false,
    required this.amenities,
    this.where = const [],
    required this.pricing,
    this.bookedFor = 'Any',
    this.gender = true,
    this.age = false,
    this.safety = false,
  });
  final List<String> bookingTypes, unitKinds, surfaces, settings, amenities, where, pricing;
  final bool parts, gender, age, safety;
  final String bookedFor;
  String get bookingType => bookingTypes.first;
  String? get unitKind => unitKinds.firstOrNull;
  String? get whereDefault => where.firstOrNull;
  String get pricingDefault => pricing.first;
}

const _wherePlace = ['At your place', 'Both', 'On call'];
const _whereCall = ['On call', 'Both', 'At your place'];
const _whereBoth = ['Both', 'At your place', 'On call'];
const _amenPlay = ['Equipment for rent', 'Washroom', 'Drinking water', 'Parking', 'WiFi', 'Flood lights', 'First aid', 'Seating lounge', 'Changing room', 'Showers', 'Cafeteria'];
const _amenStay = ['WiFi', 'AC', 'Breakfast', 'Parking', 'Hot water', 'TV', 'Room service', 'Power backup', 'Lift', 'Swimming pool', 'Laundry', 'Kitchen'];
const _amenEvent = ['Parking', 'Washroom', 'AC', 'Seating', 'Stage', 'Sound system', 'Food counter', 'Wheelchair access', 'Coat check'];
const _amenService = ['Parking', 'Waiting area', 'AC', 'WiFi', 'Washroom', 'Card and UPI', 'Wheelchair access'];
const _amenActivity = ['Lockers', 'Washroom', 'Drinking water', 'Parking', 'First aid', 'Cafeteria', 'Changing room', 'Kids area', 'Wheelchair access'];

ListingProfile listingProfile(String? category, String? sub) {
  const courts = {
    'Badminton court': ['Wooden', 'Synthetic', 'Wooden + Synthetic', 'Cement'],
    'Tennis court': ['Hard court', 'Clay', 'Natural grass', 'Synthetic'],
    'Basketball court': ['Wooden', 'Hard court', 'Synthetic'],
    'Pickleball court': ['Hard court', 'Synthetic'],
    'Volleyball court': ['Sand', 'Synthetic', 'Wooden', 'Hard court'],
    'Squash court': ['Wooden'],
  };
  switch (category) {
    case 'play':
      if (courts.containsKey(sub)) {
        return ListingProfile(bookingTypes: const ['Slot', 'Entry'], unitKinds: const ['Court'], surfaces: courts[sub]!, parts: true, amenities: _amenPlay, pricing: const ['Per slot', 'Per hour', 'Per person', 'By type'], safety: true);
      }
      return switch (sub) {
        'Football turf' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Turf'], surfaces: ['Artificial turf', 'Natural grass'], parts: true, amenities: _amenPlay, pricing: ['Per slot', 'Per hour', 'Per person', 'By type'], bookedFor: 'Group', safety: true),
        'Box cricket' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Box'], surfaces: ['Artificial turf', 'Cement', 'Mat'], parts: true, amenities: _amenPlay, pricing: ['Per slot', 'Per hour', 'By type'], bookedFor: 'Group', safety: true),
        'Cricket nets' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Net'], surfaces: ['Artificial turf', 'Cement', 'Mat', 'Natural grass'], amenities: _amenPlay, pricing: ['Per slot', 'Per hour', 'Per person'], safety: true),
        'Table tennis table' || 'Snooker and pool table' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Table'], settings: ['Indoor'], amenities: _amenPlay, pricing: ['Per hour', 'Per slot', 'Per person']),
        'Swimming lane' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Lane'], settings: ['Indoor', 'Outdoor', 'Covered'], amenities: _amenPlay, pricing: ['Per person', 'Per slot', 'Per hour'], safety: true),
        'Indoor arena' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Arena'], surfaces: ['Synthetic', 'Wooden', 'Artificial turf'], settings: ['Indoor'], parts: true, amenities: _amenPlay, pricing: ['Per slot', 'Per hour', 'By type'], safety: true),
        _ => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Turf', 'Court', 'Arena', 'Table', 'Net', 'Box', 'Lane'], surfaces: ['Wooden', 'Synthetic', 'Artificial turf', 'Natural grass', 'Clay', 'Hard court', 'Cement', 'Mat'], parts: true, amenities: _amenPlay, pricing: ['Per slot', 'Per hour', 'Per person', 'By type'], safety: true),
      };
    case 'activities':
      return switch (sub) {
        'Gaming zone and arcade' || 'VR gaming' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Station'], settings: ['Indoor'], amenities: _amenActivity, pricing: ['Per person', 'Per slot', 'By type'], age: true),
        'Bowling' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Lane'], settings: ['Indoor'], amenities: _amenActivity, pricing: ['Per slot', 'Per person', 'Per group'], age: true),
        'Escape room' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Room'], settings: ['Indoor'], amenities: _amenActivity, pricing: ['Per group', 'Per person'], bookedFor: 'Group', age: true),
        'Trampoline park' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Zone'], settings: ['Indoor', 'Outdoor'], amenities: _amenActivity, pricing: ['Per person', 'By type'], age: true, safety: true),
        'Go-karting' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Kart'], settings: ['Indoor', 'Outdoor'], amenities: _amenActivity, pricing: ['Per person', 'By type'], age: true, safety: true),
        'Paintball' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Arena'], settings: ['Outdoor', 'Indoor'], amenities: _amenActivity, pricing: ['Per person', 'Per group'], bookedFor: 'Group', age: true, safety: true),
        // visits sell tickets: no units to pick
        'Museum visit' || 'Farm and nature visit' || 'Amusement and water park' => const ListingProfile(bookingTypes: ['Entry', 'Slot'], amenities: _amenActivity, pricing: ['Per person', 'By type', 'Per group'], age: true, safety: true),
        'Guided tour' => const ListingProfile(bookingTypes: ['Slot', 'Entry'], amenities: _amenActivity, where: _wherePlace, pricing: ['Per person', 'Per group', 'By type'], age: true),
        _ => const ListingProfile(bookingTypes: ['Slot', 'Entry'], unitKinds: ['Station', 'Lane', 'Room', 'Zone', 'Arena'], amenities: _amenActivity, pricing: ['Per person', 'Per slot', 'Per group', 'By type'], age: true, safety: true),
      };
    case 'events':
      return switch (sub) {
        // a venue booked for a few hours, not tickets
        'Kids party venue' || 'Party hall and banquet' => const ListingProfile(bookingTypes: ['Slot'], unitKinds: ['Hall'], settings: ['Indoor', 'Outdoor', 'Covered'], amenities: _amenEvent, pricing: ['Per slot', 'Per person', 'By type'], bookedFor: 'Group', gender: false),
        // a service for someone else's event, at their place
        'Event planning' || 'Event decoration' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenEvent, where: _whereCall, pricing: ['By type', 'Per booking', 'Per hour'], gender: false),
        _ => const ListingProfile(bookingTypes: ['Entry'], amenities: _amenEvent, where: _wherePlace, pricing: ['Per person', 'Per entry', 'Per group', 'By type', 'No charge to book'], age: true),
      };
    case 'stay':
      return switch (sub) {
        'Day-use room' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenStay, pricing: ['Per hour', 'Per slot'], bookedFor: 'Couple', gender: false, age: true),
        'Hostel and dormitory' => const ListingProfile(bookingTypes: ['Nights'], amenities: _amenStay, pricing: ['Per night', 'By type'], bookedFor: 'Single', age: true),
        _ => const ListingProfile(bookingTypes: ['Nights'], amenities: _amenStay, pricing: ['Per night', 'By type'], bookedFor: 'Couple', gender: false, age: true),
      };
    default:
      final group = listingCategory('service')?.subcategories.where((g) => g.$2.contains(sub)).firstOrNull?.$1;
      return switch (group) {
        'Doctors' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _wherePlace, pricing: ['By type', 'Per booking'], bookedFor: 'Single', gender: false),
        'Vehicle breakdown' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _whereCall, pricing: ['By type', 'Per booking'], bookedFor: 'Single', gender: false),
        'Salon' => sub == 'Makeup artist' || sub == 'Mehendi artist'
            ? const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _whereBoth, pricing: ['By type', 'Per person', 'Per hour'])
            : const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _wherePlace, pricing: ['By type', 'Per booking', 'Per person']),
        'Professional' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _whereBoth, pricing: ['Per hour', 'By type', 'Per booking'], bookedFor: 'Single', gender: false),
        'Home and repairs' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _whereCall, pricing: ['By type', 'Per booking', 'Per hour'], gender: false),
        'Pets and wellness' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _whereBoth, pricing: ['By type', 'Per booking', 'Per hour']),
        'Printing' => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _wherePlace, pricing: ['By type', 'Per booking'], gender: false),
        _ => const ListingProfile(bookingTypes: ['Slot'], amenities: _amenService, where: _wherePlace, pricing: ['By type', 'Per booking', 'Per hour', 'Per person', 'No charge to book']),
      };
  }
}

/// The examples a form shows in its empty boxes, for its own category and subcategory (founder, 4 Nov 2026: "keep the examples relevant,
/// why is it manicure here"): (name, description, a type, an add-on, notes for the team).
typedef ListingExamples = ({String name, String description, String type, String addon, String notes});

ListingExamples listingExamples(String? category, String? sub) {
  ListingExamples e(String name, String description, String type, String addon, String notes) => (name: name, description: description, type: type, addon: addon, notes: notes);
  final group = listingCategories.where((c) => c.key == category).firstOrNull?.subcategories.where((g) => g.$2.contains(sub)).firstOrNull?.$1;
  return switch (category) {
    'events' => switch (sub) {
        'Stand-up comedy' => e('Saturday stand-up night', 'Four comics, 90 minutes', 'Front row', 'Snack combo', 'Doors open 30 minutes before'),
        'Live music' => e('Friday acoustic evening', 'Live band, 2 sets', 'Standing', 'Drinks coupon', 'Sound check at 6 pm'),
        'Workshop' => e('Pottery for beginners', '2 hours, all materials included', 'Adult', 'Take-home kit', 'Set up tables and aprons'),
        'Screening' => e('Classic film night', 'Big screen, 2 hours', 'Recliner', 'Popcorn', 'Test the projector first'),
        'Exhibition' => e('Weekend art show', '40 works by local artists', 'Adult', 'Guided walk', 'Labels on every piece'),
        'Kids party venue' => e('Kids party room · 3 hours', 'Decor, games area, 20 kids', 'Weekday', 'Cake table setup', 'Clean the play area after'),
        'Party hall and banquet' => e('Banquet hall · evening', 'Seats 150, AC, stage', 'Evening slot', 'Decor package', 'Check the generator'),
        'Event planning' => e('Birthday party planning', 'Theme, vendors and on-day help', 'Up to 50 guests', 'Photographer', 'Call the client a week before'),
        'Event decoration' => e('Balloon and flower decor', 'Setup and take-down', 'Small hall', 'Name board', 'Carry spare balloons'),
        _ => e('Saturday stand-up night', 'What happens and for how long', 'Adult', 'Snack combo', 'Doors open 30 minutes before'),
      },
    'activities' => switch (sub) {
        'Gaming zone and arcade' => e('Arcade · 1 hour pass', 'All machines, unlimited plays', 'Kids', 'Extra tokens', 'Reset the machines at opening'),
        'Bowling' => e('Bowling · 1 game per lane', 'Shoes included, up to 6 players', 'Weekend', 'Extra game', 'Spray the shoes after'),
        'Escape room' => e('Escape room · The Vault', '60 minutes, 2 to 6 players', 'Group of 4', 'Photo pack', 'Reset the clues between groups'),
        'VR gaming' => e('VR · 30 minute session', 'Choose from 10 games', 'Adult', 'Extra 15 minutes', 'Wipe the headsets after each use'),
        'Trampoline park' => e('Trampoline · 1 hour jump', 'Grip socks needed', 'Kids under 12', 'Grip socks', 'Check the nets every morning'),
        'Go-karting' => e('Go-kart · 10 laps', 'Helmet and briefing included', 'Adult', 'Extra 5 laps', 'Check the tyres before the first run'),
        'Paintball' => e('Paintball · 200 balls', 'Gear and safety briefing', 'Per player', 'Extra 100 balls', 'Masks must stay on in the field'),
        'Museum visit' => e('Museum entry · day ticket', 'All galleries, audio guide', 'Adult', 'Audio guide', 'Bags at the cloakroom'),
        'Farm and nature visit' => e('Farm day visit', 'Animals, tractor ride, lunch', 'Adult', 'Lunch', 'Boots for the field walk'),
        'Amusement and water park' => e('Water park · day pass', 'All rides and pools', 'Adult', 'Locker', 'Costumes are required in the pools'),
        'Guided tour' => e('Old city heritage walk', '2 hours, 8 stops', 'Adult', 'Tea stop', 'Meet at the main gate'),
        _ => e('Bowling · 1 game per lane', 'What customers do and for how long', 'Adult', 'Extra game', 'Safety check before opening'),
      },
    'play' => switch (sub) {
        'Football turf' => e('5-a-side turf · 1 hour', 'Floodlit turf, bibs and ball', 'Weekend', 'Ball on rent', 'Water the turf at 5 pm'),
        'Box cricket' => e('Box cricket · 1 hour', 'Netted box, bat and ball', 'Weekend', 'Extra bat', 'Check the nets for tears'),
        'Cricket nets' => e('Cricket net · 1 hour', 'Bowling machine on request', 'With machine', 'Bowling machine', 'Load the machine before the slot'),
        'Basketball court' || 'Badminton court' || 'Tennis court' || 'Pickleball court' || 'Volleyball court' || 'Squash court' =>
          e('${sub!.replaceAll(' court', '')} court · 1 hour', 'Indoor court, lights included', 'Weekend', 'Racket on rent', 'Sweep the court between slots'),
        'Table tennis table' => e('Table tennis · 1 hour', 'Bats and balls included', 'Weekend', 'Extra balls', 'Check the nets'),
        'Snooker and pool table' => e('Snooker · 1 hour', 'Full-size table, cues and chalk', 'Weekend', 'Extra frame', 'Brush the cloth daily'),
        'Swimming lane' => e('Swimming lane · 45 minutes', 'One lane, lifeguard on duty', 'Adult', 'Cap on rent', 'Test the water every morning'),
        'Indoor arena' => e('Indoor arena · 1 hour', 'Multi-sport floor', 'Weekend', 'Equipment on rent', 'Lock the store after use'),
        _ => e('Badminton court · 1 hour', 'What players book', 'Weekend', 'Racket on rent', 'Sweep the court between slots'),
      },
    'stay' => switch (sub) {
        'Hostel and dormitory' => e('Bed in 6-bed dorm', 'Locker, shared bath, WiFi', 'Lower bunk', 'Breakfast', 'Fresh linen at check-in'),
        'Day-use room' => e('Day-use room · 6 hours', 'AC, bath, WiFi', 'Morning', 'Lunch', 'Clean the room before the next guest'),
        'Resort' => e('Pool view cottage', 'AC, balcony, breakfast', 'Weekend', 'Spa session', 'Welcome drink on arrival'),
        'Farmhouse' => e('Whole farmhouse · per night', '4 rooms, lawn, pool', 'Weekend', 'Bonfire', 'Hand over the keys at the gate'),
        _ => e('Deluxe double room', 'AC, balcony, breakfast', 'Weekend', 'Airport pickup', 'Fresh towels at check-in'),
      },
    _ => switch (group) {
        'Doctors' => e('General consultation', '15 minute visit with the doctor', 'Follow-up visit', 'Blood sugar test', 'Keep the previous reports ready'),
        'Vehicle breakdown' => e(sub == 'Towing' ? 'Towing within city' : sub == 'Battery jump-start' ? 'Battery jump-start' : 'Puncture repair at your spot',
            'We come to where the vehicle is', 'Two-wheeler', 'Tube replacement', 'Ask for the exact location pin'),
        'Salon' => switch (sub) {
            "Men's salon" => e('Haircut and beard', '45 minutes with a stylist', 'Adult', 'Hair spa', 'Sterilise the tools before each client'),
            'Makeup artist' => e('Bridal makeup', 'HD makeup and hairstyle', 'Bride', 'Draping', 'Carry the full kit'),
            'Mehendi artist' => e('Bridal mehendi · both hands', 'Full hands and feet', 'Bride', 'Feet design', 'Bring the cones fresh'),
            'Spa' => e('Swedish massage · 60 minutes', 'Full body, aroma oil', 'Single', 'Foot scrub', 'Warm towels ready'),
            _ => e('Manicure', '30 minutes, polish included', 'Adult', 'Nail art', 'Sterilise the tools before each client'),
          },
        'Professional' => e(sub == 'CA and tax' ? 'Income tax filing' : sub == 'Lawyer' ? 'Legal consultation · 30 minutes' : 'Consultation · 1 hour',
            'Online or at the office', 'First visit', 'Document review', 'Collect the documents beforehand'),
        'Home and repairs' => e(switch (sub) { 'Plumbing' => 'Tap and leak repair', 'Electrical' => 'Fan or switch repair', 'Cleaning' => 'Full home deep clean',
              'Appliance and AC repair' => 'AC service and gas check', 'Pest control' => 'Cockroach control · 2BHK', 'Carpentry' => 'Door and hinge repair',
              'Painting' => 'Room painting · per room', _ => 'Home repair visit' },
            'At your home, materials extra', '1BHK', 'Spare parts', 'Ask for a photo of the problem'),
        'Pets and wellness' => e(switch (sub) { 'Pet grooming' => 'Dog bath and trim', 'Fitness trainer' => 'Personal training · 1 hour', 'Yoga' => 'Morning yoga · 1 hour',
              'Massage' => 'Deep tissue massage · 60 minutes', _ => 'Wellness session' },
            'At the studio or at home', 'Small dog', 'Nail clipping', 'Keep towels ready'),
        'Printing' => e('Visiting cards · 100 pieces', 'Matte finish, both sides', 'Matte', 'Lamination', 'Proof the design with the customer'),
        _ => e('Haircut and beard', 'What customers get', 'Adult', 'Hair spa', 'Anything to prepare'),
      },
  };
}

ListingCategory? listingCategory(String? key) => listingCategories.where((c) => c.key == key).firstOrNull;

/// The type (group) a subcategory is under, for a category with more than one (Service: Doctors, Salon ...; Activities: Games, Visits).
String? groupOfSubcategory(String? category, String? sub) {
  final c = listingCategories.where((c) => c.key == category).firstOrNull;
  if (c == null || c.subcategories.length < 2) return null;
  return c.subcategories.where((g) => g.$2.contains(sub)).firstOrNull?.$1;
}

/// The category a subcategory belongs to (to fill a form from an older service's own category).
String? categoryOfSubcategory(String? sub) => listingCategories.where((c) => c.allSubcategories.contains(sub)).firstOrNull?.key;

// ============================================================================================================ options

const kLengths = ['15 min', '30 min', '45 min', '1 hr', '1.5 hr', '2 hr', '3 hr', '4 hr', '6 hr', '8 hr'];
const kUnits = ['pcs', 'ml', 'l', 'g', 'kg', 'pack', 'sheet', 'pair', 'tube', 'bottle'];

/// "1.5 hr" → 90, "45 min" → 45, "None" → 0.
int listingMinutes(String? s) {
  if (s == null) return 0;
  final m = RegExp(r'([\d.]+)\s*(min|hr|day)').firstMatch(s);
  if (m == null) return 0;
  final n = double.parse(m.group(1)!);
  return (n * switch (m.group(2)) { 'hr' => 60, 'day' => 1440, _ => 1 }).round();
}

/// 90 → "1.5 hr", 45 → "45 min".
String lengthLabel(int min) => min < 60 ? '$min min' : '${min % 60 == 0 ? min ~/ 60 : (min / 60).toStringAsFixed(1)} hr';

// ============================================================================================================ small widgets

/// A dropdown-looking box (white, a line round it, a chevron) that opens a sheet of choices.
class PickBox extends StatelessWidget {
  const PickBox({super.key, required this.fieldKey, required this.value, this.onTap, this.hint = 'Choose', this.label});
  final Key fieldKey;
  final String? value;
  final String hint;
  final String? label;
  final VoidCallback? onTap;

  /// Where the box just tapped is on screen, so [pickOne] opens its choices right under it (founder, 4 Nov 2026: the list should open
  /// below the dropdown, not come up from the bottom). Taken once.
  static Rect? _anchor;
  static Rect? takeAnchor() {
    final a = _anchor;
    _anchor = null;
    return a;
  }

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: fieldKey,
          borderRadius: BorderRadius.circular(12),
          onTap: onTap == null
              ? null
              : () {
                  final box = context.findRenderObject();
                  _anchor = box is RenderBox && box.attached ? box.localToGlobal(Offset.zero) & box.size : null;
                  onTap!();
                },
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E6E3), width: 1.5)),
            child: Row(children: [
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (label != null) Text(label!, style: inter(10.5, 600, color: kMuted)),
                  Text(value ?? hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14, value == null ? 400 : 500, color: value == null ? kHint : kInk)),
                ]),
              ),
              const Icon(LucideIcons.chevronDown, size: 16, color: kMuted),
            ]),
          ),
        ),
      );
}

/// The compact text box beside the pick boxes: white, a line round it, 42 px tall.
InputDecoration formBox({String? hint, String? prefix, String? label, String? suffix}) => InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      hintText: hint,
      labelText: label,
      prefixText: prefix,
      suffixText: suffix,
      hintStyle: inter(13.5, 400, color: kHint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E6E3), width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E6E3), width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kGreenText, width: 1.5)),
    );

Widget fieldLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 5), child: Text(text, maxLines: 2, style: inter(12, 700, color: const Color(0xFF3F4A46))));

/// Options people added themselves with "+ Add" in a dropdown (founder, 4 Nov 2026: "each drop down should have a + add option to add
/// their own options"), kept on this device per dropdown and listed with its own options next time.
class CustomOptions {
  static const _prefsKey = 'svc_custom_options';
  static Map<String, List<String>>? _all;

  /// Reads what was added on this device; the forms call it as they open, so the dropdowns can open at once.
  static Future<Map<String, List<String>>> load() async {
    if (_all != null) return _all!;
    final all = <String, List<String>>{};
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries) {
          all[e.key] = [for (final x in e.value as List) '$x'];
        }
      }
    } catch (_) {}
    return _all ??= all;
  }

  /// What was added to the dropdown [key] (empty until [load] has read the device).
  static List<String> of(String key) {
    if (_all == null) load();
    return [...?_all?[key]];
  }

  static Future<void> add(String key, String option) async {
    final all = await load();
    final list = all.putIfAbsent(key, () => []);
    if (list.contains(option)) return;
    list.add(option);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(all));
    } catch (_) {}
  }

  /// For tests: forget what was added.
  static void reset() => _all = {};
}

const _addValue = '\u0000add';

/// A typed length or gap ("75", "75 min", "2 hr", "1.5 hours", "2 days") as the dropdowns write it ("75 min", "2 hr", "2 day"); null when
/// it is not one.
String? tidyLength(String s) {
  final m = RegExp(r'^\s*([\d.]+)\s*([a-z]*)\s*$').firstMatch(s.toLowerCase());
  final n = m == null ? null : num.tryParse(m.group(1)!);
  if (n == null || n <= 0) return null;
  final unit = m!.group(2)!;
  final u = unit.isEmpty || unit.startsWith('m') ? 'min' : unit.startsWith('h') ? 'hr' : unit.startsWith('d') ? 'day' : null;
  if (u == null) return null;
  return '${n % 1 == 0 ? n.toInt() : n} $u';
}

/// What "+ Add" asks for: any words, a length (a number and min / hr / day) or a count (digits only).
enum OwnInput {
  text,
  length, // a number and Minutes / Hours / Days
  count, // a whole number
  days, // "45" → "45 days ahead"
  nights, // "3" → "3 nights"
  minutes, // "20" → "Every 20 min"
  km, // "8" → "Within 8 km"
  percent, // "18" → "18%"
  hours, // "6" → "Free until 6 hr before"
}

/// A typed whole number above zero, or null.
String? tidyCount(String s) {
  final n = int.tryParse(s.trim());
  return n == null || n < 1 ? null : '$n';
}

/// The choices for a dropdown, opened right under the box that was tapped (as wide as it, scrolling when long); [groups] puts headings over
/// them (Doctors, Salon ...). Without a box (called from elsewhere) they come up in a sheet. Returns the one picked.
///
/// Every dropdown ends with "+ Add" (founder, 4 Nov 2026) unless [canAdd] is false: a small frosted box opens where the dropdown was
/// and asks for the new option ([input] says what it takes), keeps it for next time under [addKey] (the title by default) and returns it.
Future<String?> pickOne(BuildContext context, String title, List<String> options,
    {String? current, List<(String, List<String>)>? groups, bool canAdd = true, String? addKey, OwnInput input = OwnInput.text}) async {
  final anchor = PickBox.takeAnchor();
  if (!canAdd) return _pickFrom(context, anchor, title, options, current: current, groups: groups, add: false);
  final key = addKey ?? title;
  final all = {...options, for (final (_, names) in groups ?? const <(String, List<String>)>[]) ...names};
  final own = CustomOptions.of(key).where((x) => !all.contains(x)).toList();
  if (current != null && current.isNotEmpty && !all.contains(current) && !own.contains(current)) own.insert(0, current);
  final picked = await _pickFrom(context, anchor, title, groups != null ? options : [...options, ...own],
      current: current, groups: groups == null ? null : [...groups, if (own.isNotEmpty) ('Your own', own)], add: true);
  if (picked != _addValue) return picked;
  if (!context.mounted) return null;
  final value = await _askOwn(context, anchor, title, input);
  if (value == null) return null;
  // kept for next time in the background: the box fills at once, even when the device is slow to save (4 Nov 2026)
  if (!all.contains(value)) unawaited(CustomOptions.add(key, value));
  return value;
}

/// "+ Add your own" from a place that is not a dropdown (an amenity chip, a unit kind): the same frosted box, in the middle of the screen.
Future<String?> askOwn(BuildContext context, String title, {OwnInput input = OwnInput.text}) => _askOwn(context, null, title, input);

/// The "+ Add" box: frosted and see-through, opened right under the dropdown box (kept above the keyboard), not a sheet from the bottom.
Future<String?> _askOwn(BuildContext context, Rect? anchor, String title, OwnInput input) {
  final text = TextEditingController();
  var unit = 'min';
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x14000000),
    transitionDuration: const Duration(milliseconds: 160),
    transitionBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)), alignment: Alignment.topCenter, child: child),
    ),
    pageBuilder: (ctx, _, _) => StatefulBuilder(builder: (ctx, setBox) {
      final mq = MediaQuery.of(ctx);
      final screen = mq.size;
      final width = math.min(math.max(anchor?.width ?? 0, 280.0), screen.width - 32);
      final height = input == OwnInput.length ? 222.0 : 176.0;
      final left = ((anchor?.left ?? (screen.width - width) / 2)).clamp(16.0, screen.width - width - 16);
      final room = screen.height - mq.viewInsets.bottom - height - 12;
      final top = math.max(mq.padding.top + 8, math.min(anchor == null ? room / 2 : anchor.bottom + 6, room));
      String? value() {
        final t = text.text.trim();
        if (t.isEmpty) return null;
        final n = int.tryParse(t);
        if (input != OwnInput.text && input != OwnInput.length && (n == null || n < 1)) return input == OwnInput.percent && n == 0 ? '0%' : null;
        return switch (input) {
          OwnInput.length => tidyLength('$t $unit'),
          OwnInput.count => tidyCount(t),
          OwnInput.days => '$n ${n == 1 ? 'day' : 'days'} ahead',
          OwnInput.nights => '$n ${n == 1 ? 'night' : 'nights'}',
          OwnInput.minutes => 'Every $n min',
          OwnInput.km => 'Within $n km',
          OwnInput.percent => n! > 100 ? null : '$n%',
          OwnInput.hours => 'Free until $n hr before',
          OwnInput.text => t,
        };
      }

      void done() {
        final v = value();
        if (v != null) Navigator.pop(ctx, v);
      }

      final field = TextField(
        key: const ValueKey('ask-text'),
        controller: text,
        autofocus: true,
        keyboardType: switch (input) {
          OwnInput.length => const TextInputType.numberWithOptions(decimal: true),
          OwnInput.text => TextInputType.text,
          _ => TextInputType.number,
        },
        inputFormatters: switch (input) {
          OwnInput.length => [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,4}(\.\d{0,1})?'))],
          OwnInput.text => [LengthLimitingTextInputFormatter(60)],
          _ => [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
        },
        textCapitalization: input == OwnInput.text ? TextCapitalization.sentences : TextCapitalization.none,
        style: inter(15, 600),
        onChanged: (_) => setBox(() {}),
        onSubmitted: (_) => done(),
        decoration: formBox(
            hint: switch (input) {
              OwnInput.length => 'e.g. 75',
              OwnInput.count => 'e.g. 12',
              OwnInput.days => 'Days ahead, e.g. 45',
              OwnInput.nights => 'Nights, e.g. 3',
              OwnInput.minutes => 'Minutes, e.g. 20',
              OwnInput.km => 'Kilometres, e.g. 8',
              OwnInput.percent => 'Percent, e.g. 18',
              OwnInput.hours => 'Hours before, e.g. 6',
              OwnInput.text => 'Type your own',
            },
            suffix: switch (input) { OwnInput.days => 'days', OwnInput.nights => 'nights', OwnInput.minutes => 'min', OwnInput.km => 'km', OwnInput.percent => '%', OwnInput.hours => 'hr', _ => null }),
      );
      return Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            type: MaterialType.transparency,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  key: const ValueKey('own-box'),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
                    boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0, 8))],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      const Icon(LucideIcons.plus, size: 16, color: kGreenText),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Add ${title.toLowerCase()}', style: inter(14, 700))),
                      InkWell(onTap: () => Navigator.pop(ctx), child: const Padding(padding: EdgeInsets.all(2), child: Icon(LucideIcons.x, size: 18, color: kMuted))),
                    ]),
                    const SizedBox(height: 10),
                    if (input == OwnInput.length)
                      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        field,
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(color: const Color(0x14000000), borderRadius: BorderRadius.circular(10)),
                          child: Row(children: [
                            for (final (u, l) in const [('min', 'Minutes'), ('hr', 'Hours'), ('day', 'Days')])
                              Expanded(
                                child: GestureDetector(
                                  key: ValueKey('own-unit-$u'),
                                  onTap: () => setBox(() => unit = u),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: unit == u ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: unit == u ? const [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))] : null,
                                    ),
                                    child: Text(l, style: inter(13, unit == u ? 700 : 500, color: unit == u ? kInk : kMuted)),
                                  ),
                                ),
                              ),
                          ]),
                        ),
                      ])
                    else
                      field,
                    const SizedBox(height: 10),
                    FilledButton(
                      key: const ValueKey('own-add'),
                      style: FilledButton.styleFrom(
                          backgroundColor: kInk, minimumSize: const Size.fromHeight(42), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      onPressed: value() == null ? null : done,
                      child: Text(value() == null ? 'Add' : 'Add "${value()}"', style: inter(14, 700, color: kChipGreen)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]);
    }),
  ); // the controller is left to the garbage collector: the box still draws it while it fades out
}

Future<String?> _pickFrom(BuildContext context, Rect? anchor, String title, List<String> options,
    {String? current, List<(String, List<String>)>? groups, required bool add}) {
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  if (anchor == null || overlay is! RenderBox) return _pickSheet(context, title, options, current: current, groups: groups, add: add);
  final at = overlay.globalToLocal(anchor.bottomLeft) & Size(anchor.width, 0);
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at.shift(const Offset(0, 4)), Offset.zero & overlay.size),
    constraints: BoxConstraints(minWidth: anchor.width, maxWidth: math.max(anchor.width, 240), maxHeight: 340),
    color: Colors.white,
    surfaceTintColor: Colors.white,
    elevation: 8,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kLine)),
    items: [
      for (final (group, names) in groups ?? [('', options)]) ...[
        if (group.isNotEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 30,
            child: Text(group.toUpperCase(), style: inter(11, 800, color: kMuted).copyWith(letterSpacing: 0.6)),
          ),
        for (final x in names)
          PopupMenuItem<String>(
            key: ValueKey('opt-$x'),
            value: x,
            height: 40,
            child: Row(children: [
              Expanded(child: Text(x, style: inter(14, current == x ? 700 : 500, color: kInk))),
              if (current == x) const Icon(LucideIcons.check, size: 16, color: kGreenText),
            ]),
          ),
      ],
      if (add) ...[
        const PopupMenuDivider(height: 8),
        PopupMenuItem<String>(key: const ValueKey('opt-add'), value: _addValue, height: 42, child: _addRow(title)),
      ],
    ],
  );
}

Widget _addRow(String title) => Row(children: [
      const Icon(LucideIcons.plus, size: 16, color: kGreenText),
      const SizedBox(width: 8),
      Expanded(child: Text('Add ${title.toLowerCase()}', style: inter(14, 700, color: kGreenText))),
    ]);

Future<String?> _pickSheet(BuildContext context, String title, List<String> options,
        {String? current, List<(String, List<String>)>? groups, bool add = false}) =>
    showOrderSheet<String>(
      context,
      title: title,
      body: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (group, names) in groups ?? [('', options)]) ...[
              if (group.isNotEmpty)
                Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 2), child: Text(group.toUpperCase(), style: inter(11.5, 800, color: kMuted).copyWith(letterSpacing: 0.6))),
              for (final x in names)
                ListTile(
                  key: ValueKey('opt-$x'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(x, style: inter(14.5, current == x ? 700 : 500)),
                  trailing: current == x ? const Icon(LucideIcons.check, size: 18, color: kGreenText) : null,
                  onTap: () => Navigator.pop(ctx, x),
                ),
            ],
            if (add)
              ListTile(
                key: const ValueKey('opt-add'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: _addRow(title),
                onTap: () => Navigator.pop(ctx, _addValue),
              ),
          ]),
        ),
      ),
    );

/// A section card (founder, 4 Nov 2026: "these coloured icons ... make them illustration outlines, these colours don't go here"): a plain
/// white card with a thin line, an outline icon in a soft round frame, the title in ink and one muted line under it.
class FormCard extends StatelessWidget {
  const FormCard({super.key, required this.title, required this.line, required this.icon, required this.child, this.trailing});
  final String title, line;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kLine),
          boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
            child: Row(children: [
              // the bar's look: a navy circle, the icon in neon lime with a soft glow (founder, 4 Nov 2026)
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(0xFF111827),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x59A1FE2F), blurRadius: 12, offset: Offset(0, 3))],
                ),
                child: Icon(icon, size: 18, color: kLime),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(14.5, 700)),
                  Text(line, style: inter(12, 400, color: kMuted)),
                ]),
              ),
              ?trailing,
            ]),
          ),
          // a thin lime accent under the heading, fading out
          Container(
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: const LinearGradient(colors: [kLime, Color(0x33A1FE2F), Color(0x00A1FE2F)], stops: [0, 0.45, 1]),
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 4), child: child),
        ]),
      );
}

/// Lays fields out by width: a short one takes a column (two on a phone, three on a wide screen), a long one the whole row.
class FieldGrid extends StatelessWidget {
  const FieldGrid({super.key, required this.children});
  final List<(bool short, Widget field)> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final cols = box.maxWidth >= 620 ? 3 : box.maxWidth >= 300 ? 2 : 1;
        final w = (box.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(spacing: 10, runSpacing: 2, children: [
          for (final (short, f) in children) SizedBox(width: short ? w : box.maxWidth, child: Padding(padding: const EdgeInsets.only(bottom: 10), child: f)),
        ]);
      });
}

// ============================================================================================================ what it needs

/// The kinds of thing a service can need, and what each picks from.
const kNeedTypes = ['Person', 'Place', 'Tool', 'Material', 'Other'];

/// What the row editors pick from: the team, places, tools and materials (`svc_listing_view`).
class NeedsOptions {
  const NeedsOptions({this.team = const [], this.places = const [], this.tools = const [], this.materials = const []});
  NeedsOptions.of(ListingData d) : this(team: d.team, places: d.places, tools: d.tools, materials: d.materials);
  final List<SvcData> team, places, tools, materials;

  /// The choices for a row of [type]: (id or null, name, unit).
  List<(String?, String, String?)> itemsFor(String type) => switch (type) {
        // "Who can do it": anyone, anyone with a role from Team (the design's roles and skills), or a named person
        'person' => [
            (null, 'Any staff', null),
            for (final role in {for (final t in team) if (t.s('title').isNotEmpty) t.s('title')}) (null, 'Any ${role.toLowerCase()}', null),
            for (final t in team) (t.s('staff_id'), t.s('title').isEmpty ? t.s('name') : '${t.s('name')} · ${t.s('title')}', null),
          ],
        'place' => [(null, 'Any free place', null), for (final p in places) (p.s('id'), p.s('name'), null)],
        'tool' => [for (final p in tools) (p.s('id'), p.s('name'), null)],
        'material' => [for (final p in materials) (p.s('id'), p.s('name'), p.so('unit'))],
        _ => const [],
      };
}

/// How often a material is used (the design's "Per", where it applies).
const kNeedPer = ['booking', 'guest', 'night', 'guest per night'];

String needType(String label) => label.toLowerCase();
String needLabel(String type) => kNeedTypes.firstWhere((t) => t.toLowerCase() == type, orElse: () => 'Other');

/// "1 person · 1 tool · 2 materials" for a list of needs.
String needsSummary(List<Map<String, dynamic>> rows) {
  final counts = <String, int>{};
  for (final r in rows) {
    counts[r['type'] as String? ?? 'other'] = (counts[r['type'] as String? ?? 'other'] ?? 0) + 1;
  }
  String part(String type, String one, String many) => counts[type] == null ? '' : '${counts[type]} ${counts[type] == 1 ? one : many}';
  return [
    part('person', 'person', 'people'),
    part('place', 'place', 'places'),
    part('tool', 'tool', 'tools'),
    part('material', 'material', 'materials'),
    part('other', 'other item', 'other items'),
  ].where((s) => s.isNotEmpty).join(' · ');
}

/// What a service needs, row by row like a recipe's ingredients: type, item (from the team, places, tools or materials; typed for
/// Other), how many, and the unit. [onChanged] gets the whole list each time.
class NeedsEditor extends StatelessWidget {
  const NeedsEditor({super.key, required this.rows, required this.options, required this.onChanged, this.keyPrefix = 'need'});
  final List<Map<String, dynamic>> rows;
  final NeedsOptions options;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  final String keyPrefix;

  void _put(int i, Map<String, dynamic> row) => onChanged([...rows]..[i] = row);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < rows.length; i++) _row(context, i),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('$keyPrefix-add'),
            onPressed: () => onChanged([...rows, {'type': 'person', 'name': 'Any staff', 'qty': 1}]),
            icon: const Icon(LucideIcons.plus, size: 16, color: kGreenText),
            label: Text('Add', style: inter(13.5, 700, color: kGreenText)),
          ),
        ),
      ]);

  Widget _row(BuildContext context, int i) {
    final r = rows[i];
    final type = r['type'] as String? ?? 'other';
    final items = options.itemsFor(type);
    final unitOn = type == 'material' || type == 'other';
    final typeBox = PickBox(
      fieldKey: ValueKey('$keyPrefix-$i-type'),
      label: 'Type',
      value: needLabel(type),
      onTap: () async {
        final p = await pickOne(context, 'Type', kNeedTypes, current: needLabel(type), canAdd: false);
        if (p == null) return;
        final t = needType(p);
        final first = options.itemsFor(t).firstOrNull;
        _put(i, {'type': t, 'item_id': first?.$1, 'name': first?.$2 ?? '', 'qty': rows[i]['qty'] ?? 1, if (t == 'material' || t == 'other') 'unit': first?.$3 ?? 'pcs'});
      },
    );
    final itemBox = type == 'other' || items.isEmpty
        ? TextFormField(
            key: ValueKey('$keyPrefix-$i-name'),
            initialValue: '${r['name'] ?? ''}',
            style: inter(14, 500),
            decoration: formBox(label: items.isEmpty && type != 'other' ? 'Add ${needLabel(type).toLowerCase()}s in Inventory, or type' : 'Item'),
            onChanged: (s) => rows[i] = {...rows[i], 'name': s, 'item_id': null},
          )
        : PickBox(
            fieldKey: ValueKey('$keyPrefix-$i-item'),
            label: needLabel(type),
            value: r['name'] as String?,
            onTap: () async {
              final p = await pickOne(context, needLabel(type), [for (final x in items) x.$2], current: r['name'] as String?, addKey: 'need-$type');
              if (p == null) return;
              final it = items.where((x) => x.$2 == p).firstOrNull;
              _put(i, it == null ? {...rows[i], 'item_id': null, 'name': p} : {...rows[i], 'item_id': it.$1, 'name': it.$2, if (it.$3 != null && kUnits.contains(it.$3)) 'unit': it.$3});
            },
          );
    final qtyBox = TextFormField(
      key: ValueKey('$keyPrefix-$i-qty'),
      initialValue: '${r['qty'] ?? ''}',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: numberOnly(const TextInputType.numberWithOptions(decimal: true)),
      style: inter(14, 500),
      decoration: formBox(label: 'Qty'),
      onChanged: (s) => rows[i] = {...rows[i], 'qty': num.tryParse(s) ?? s},
    );
    final unitBox = PickBox(
      fieldKey: ValueKey('$keyPrefix-$i-unit'),
      label: 'Unit',
      value: r['unit'] as String? ?? 'pcs',
      onTap: () async {
        final p = await pickOne(context, 'Unit', kUnits, current: r['unit'] as String?);
        if (p != null) _put(i, {...rows[i], 'unit': p});
      },
    );
    final perOn = type == 'material';
    final perBox = PickBox(
      fieldKey: ValueKey('$keyPrefix-$i-per'),
      label: 'Per',
      value: r['per'] as String? ?? 'booking',
      onTap: () async {
        final p = await pickOne(context, 'Per', kNeedPer, current: r['per'] as String? ?? 'booking', canAdd: false);
        if (p != null) _put(i, {...rows[i], 'per': p});
      },
    );
    final remove = IconButton(
      key: ValueKey('$keyPrefix-$i-remove'),
      tooltip: 'Remove',
      onPressed: () => onChanged([...rows]..removeAt(i)),
      icon: const Icon(LucideIcons.trash2, size: 17, color: kError),
    );
    return Padding(
      key: ValueKey('$keyPrefix-row-$i'),
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(builder: (context, box) {
        // one line on a wide screen (like the recipe master); two lines on a phone
        if (box.maxWidth >= 560) {
          return Row(children: [
            Expanded(flex: 3, child: typeBox),
            const SizedBox(width: 8),
            Expanded(flex: 5, child: itemBox),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: qtyBox),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: unitOn ? unitBox : const SizedBox.shrink()),
            if (perOn) ...[const SizedBox(width: 8), Expanded(flex: 2, child: perBox)],
            remove,
          ]);
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
          decoration: BoxDecoration(color: const Color(0xFFF9FAF9), borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
          child: Column(children: [
            Row(children: [Expanded(flex: 2, child: typeBox), const SizedBox(width: 8), Expanded(flex: 3, child: itemBox), remove]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: qtyBox),
              const SizedBox(width: 8),
              Expanded(child: unitOn ? unitBox : const SizedBox.shrink()),
              if (perOn) ...[const SizedBox(width: 8), Expanded(child: perBox)],
              const SizedBox(width: 48),
            ]),
          ]),
        );
      }),
    );
  }
}

// ============================================================================================================ rules

/// The categories a rule can be about, and the conditions each offers (the design's rule builder: gender, age, group type, number of
/// people; and any other the publisher wants: day, time of day, custom). Custom takes typed words.
const kRuleCategories = <String, List<String>>{
  'Gender': ['Women', 'Men'],
  'Age': ['Under 8', 'Under 12', 'Under 18', '18 and above', 'Senior (60+)'],
  'Group type': ['Single', 'Couple', 'Family', 'Group'],
  'Number of people': ['1', '2', '2 or more', '5 or more', '10 or more'],
  'Day': ['Weekdays', 'Weekends', 'Holidays'],
  'Time of day': ['Morning', 'Afternoon', 'Evening', 'Night'],
  'Custom': [],
};
const kRuleResults = ['Allowed', 'Not allowed', 'Needs an adult', 'Women-only slots', 'Needs approval', 'Different price'];
const kRulePer = ['each', 'per group'];

/// When more than one rule fits a booking (kept with the listing).
const kRuleOrder = ['Use the first rule, top to bottom', 'Charge the lower price', 'Charge the higher price'];

/// A rule's conditions; an older rule (one category and condition) reads as one condition.
List<Map<String, dynamic>> ruleConditions(Map<String, dynamic> r) => r['conditions'] is List
    ? [for (final c in r['conditions'] as List) Map<String, dynamic>.from(c as Map)]
    : [if (r['category'] != null || r['condition'] != null) {'category': r['category'] ?? 'Custom', 'condition': r['condition'] ?? ''}];

/// "Women + 18 and above → ₹300 each", "Under 8 → Not allowed".
String ruleSummary(Map<String, dynamic> r) {
  final when = [for (final c in ruleConditions(r)) '${c['condition'] ?? ''}'].where((x) => x.isNotEmpty).join(' + ');
  final price = r['price'] == null || '${r['price']}'.isEmpty ? null : '₹${r['price']} ${r['per'] ?? 'each'}';
  final result = r['result'] as String? ?? 'Allowed';
  final then = result == 'Different price' ? (price ?? '₹?') : price == null || result == 'Not allowed' ? result : '$result · $price';
  return '${when.isEmpty ? 'Everyone' : when} → $then';
}

/// Rules like the design's builder: each rule combines conditions (+ and), then a result and a price each or per group. Anyone not
/// matched books at the base price. [onChanged] gets the whole list each time.
class RulesEditor extends StatelessWidget {
  const RulesEditor({super.key, required this.rows, required this.onChanged, this.keyPrefix = 'rule'});
  final List<Map<String, dynamic>> rows;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  final String keyPrefix;

  void _put(int i, Map<String, dynamic> row) => onChanged([...rows]..[i] = row);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (rows.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('No rules: anyone can book at the base price.', style: inter(12.5, 400, color: kMuted))),
        for (var i = 0; i < rows.length; i++) _rule(context, i),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('$keyPrefix-add'),
            onPressed: () => onChanged([
              ...rows,
              {
                'conditions': [
                  {'category': 'Gender', 'condition': 'Women'}
                ],
                'result': 'Allowed',
                'per': 'each',
              }
            ]),
            icon: const Icon(LucideIcons.plus, size: 16, color: kGreenText),
            label: Text('Add rule', style: inter(13.5, 700, color: kGreenText)),
          ),
        ),
      ]);

  Widget _rule(BuildContext context, int i) {
    final r = rows[i];
    final conds = ruleConditions(r);
    // what was typed since the rule was drawn (a price, a custom condition) lives in rows[i]: always start from it
    void putConds(List<Map<String, dynamic>> c) => _put(i, {...rows[i]..remove('category')..remove('condition'), 'conditions': c});
    List<Map<String, dynamic>> nowConds() => ruleConditions(rows[i]);
    // the first condition keeps the plain keys ('rule-0-category'); the others add their place ('rule-0-1-category')
    String k(int j, String what) => j == 0 ? '$keyPrefix-$i-$what' : '$keyPrefix-$i-$j-$what';
    Widget condition(int j) {
      final c = conds[j];
      final cat = c['category'] as String? ?? 'Custom';
      final options = kRuleCategories[cat] ?? const [];
      final catBox = PickBox(
        fieldKey: ValueKey(k(j, 'category')),
        label: j == 0 ? 'When' : 'And',
        value: cat,
        onTap: () async {
          final p = await pickOne(context, 'Rule about', kRuleCategories.keys.toList(), current: cat);
          if (p != null) putConds(nowConds()..[j] = {'category': p, 'condition': (kRuleCategories[p] ?? const []).firstOrNull ?? ''});
        },
      );
      final condBox = options.isEmpty
          ? TextFormField(
              key: ValueKey(k(j, 'condition')),
              initialValue: '${c['condition'] ?? ''}',
              style: inter(14, 500),
              decoration: formBox(label: 'Condition'),
              onChanged: (v) => rows[i] = {...rows[i]..remove('category')..remove('condition'), 'conditions': nowConds()..[j] = {...c, 'condition': v}},
            )
          : PickBox(
              fieldKey: ValueKey(k(j, 'condition')),
              label: cat,
              value: c['condition'] as String?,
              onTap: () async {
                final p = await pickOne(context, cat, options, current: c['condition'] as String?, canAdd: cat != 'Number of people');
                if (p != null) putConds(nowConds()..[j] = {...c, 'condition': p});
              },
            );
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Expanded(child: catBox),
          const SizedBox(width: 8),
          Expanded(child: condBox),
          if (conds.length > 1)
            IconButton(
              key: ValueKey(k(j, 'off')),
              tooltip: 'Take off this condition',
              visualDensity: VisualDensity.compact,
              onPressed: () => putConds(nowConds()..removeAt(j)),
              icon: const Icon(LucideIcons.x, size: 16, color: kMuted),
            ),
        ]),
      );
    }

    final result = r['result'] as String? ?? 'Allowed';
    final resultBox = PickBox(
      fieldKey: ValueKey('$keyPrefix-$i-result'),
      label: 'Then',
      value: result,
      onTap: () async {
        final p = await pickOne(context, 'Then', kRuleResults, current: result);
        if (p != null) _put(i, {...rows[i], 'result': p});
      },
    );
    final priced = result != 'Not allowed';
    final priceBox = TextFormField(
      key: ValueKey('$keyPrefix-$i-price'),
      initialValue: '${r['price'] ?? ''}',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: numberOnly(const TextInputType.numberWithOptions(decimal: true)),
      style: inter(14, 500),
      decoration: formBox(label: result == 'Different price' ? 'Price' : 'Price (optional)', prefix: '₹ '),
      onChanged: (v) => rows[i] = {...rows[i], 'price': num.tryParse(v) ?? (v.isEmpty ? null : v)},
    );
    final perBox = PickBox(
      fieldKey: ValueKey('$keyPrefix-$i-per'),
      label: 'Paid',
      value: r['per'] as String? ?? 'each',
      onTap: () async {
        final p = await pickOne(context, 'Paid', kRulePer, current: r['per'] as String? ?? 'each', canAdd: false);
        if (p != null) _put(i, {...rows[i], 'per': p});
      },
    );
    return Container(
      key: ValueKey('$keyPrefix-row-$i'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      decoration: BoxDecoration(color: const Color(0xFFF9FAF9), borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Rule ${i + 1}', style: inter(13, 700))),
          IconButton(
            key: ValueKey('$keyPrefix-$i-remove'),
            tooltip: 'Remove rule',
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged([...rows]..removeAt(i)),
            icon: const Icon(LucideIcons.trash2, size: 17, color: kError),
          ),
        ]),
        for (var j = 0; j < conds.length; j++) condition(j),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('$keyPrefix-$i-and'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4)),
            onPressed: () => putConds([
              ...nowConds(),
              {'category': 'Age', 'condition': '18 and above'}
            ]),
            icon: const Icon(LucideIcons.plus, size: 15, color: kGreenText),
            label: Text('And another condition', style: inter(12.5, 700, color: kGreenText)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: Row(children: [
            Expanded(flex: 4, child: resultBox),
            if (priced) ...[const SizedBox(width: 8), Expanded(flex: 3, child: priceBox), const SizedBox(width: 8), Expanded(flex: 3, child: perBox)],
          ]),
        ),
      ]),
    );
  }
}

/// The summary box under the needs, like the recipe master's cost box: what the template or service needs, and its rules.
Widget needsTotal(List<Map<String, dynamic>> needs, List<Map<String, dynamic>> rules, {Key? key}) => Container(
      key: key,
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF4F6F3), borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Needs per booking', style: inter(13, 600, color: kMuted))),
          Text(needs.isEmpty ? 'Nothing yet' : needsSummary(needs), style: inter(13.5, 800)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text('Rules', style: inter(13, 600, color: kMuted))),
          Text(rules.isEmpty ? 'None' : '${rules.length} ${rules.length == 1 ? 'rule' : 'rules'}', style: inter(13.5, 800, color: kGreenText)),
        ]),
      ]),
    );

/// The places, tools and materials [needs] picks, in the shape svc_listing_save marks as used for the service.
Map<String, Object?> usesOf(List<Map<String, dynamic>> needs) => {
      'place_ids': [for (final r in needs) if (r['type'] == 'place' && r['item_id'] != null) r['item_id']],
      'tool_ids': [for (final r in needs) if (r['type'] == 'tool' && r['item_id'] != null) r['item_id']],
      'materials': [
        for (final r in needs)
          if (r['type'] == 'material' && r['item_id'] != null) {'id': r['item_id'], 'qty': r['qty'], 'unit': r['unit'], if (r['per'] != null) 'per': r['per']},
      ],
    };

/// Shows [message] from a refused call, or the error itself.
void showServiceError(BuildContext context, Object e) => showToast(context, e is ServiceApiException ? e.message : e.toString());

// ============================================================================================================ form pieces

/// One column of [RowsEditor]: a typed name, a price, a length, or a dropdown of [options].
class RowColumn {
  const RowColumn(this.key, this.label, {this.kind = 'text', this.options = const [], this.flex = 3, this.hint = '', this.input = OwnInput.text});
  final String key, label, kind, hint; // kind: text | money | count | pick
  final List<String> options;
  final int flex;

  /// For a pick: what its "+ Add" takes (null: no "+ Add", the list is complete, e.g. times).
  final OwnInput? input;
}

/// Rows the publisher adds (the design's "Types and prices", "Parts and prices", "Add-ons", "Your units", "Time bands"): each row a few
/// boxes side by side (two lines on a phone when there are more than three), a remove button, and "+ Add".
class RowsEditor extends StatelessWidget {
  const RowsEditor({super.key, required this.rows, required this.columns, required this.onChanged, required this.keyPrefix, this.addLabel = 'Add', this.starter = const {}});
  final List<Map<String, dynamic>> rows;
  final List<RowColumn> columns;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;
  final String keyPrefix, addLabel;
  final Map<String, dynamic> starter;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < rows.length; i++) _row(context, i),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('$keyPrefix-add'),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4)),
            onPressed: () => onChanged([...rows, {...starter}]),
            icon: const Icon(LucideIcons.plus, size: 15, color: kGreenText),
            label: Text(addLabel, style: inter(13, 700, color: kGreenText)),
          ),
        ),
      ]);

  Widget _row(BuildContext context, int i) {
    final r = rows[i];
    Widget box(RowColumn c) {
      if (c.kind == 'pick') {
        return PickBox(
          fieldKey: ValueKey('$keyPrefix-$i-${c.key}'),
          label: c.label,
          value: r[c.key] as String?,
          hint: c.hint.isEmpty ? 'Choose' : c.hint,
          onTap: () async {
            final p = await pickOne(context, c.label, c.options, current: r[c.key] as String?, canAdd: c.input != null, input: c.input ?? OwnInput.text);
            if (p != null) onChanged([...rows]..[i] = {...rows[i], c.key: p});
          },
        );
      }
      final numeric = c.kind == 'money' || c.kind == 'count';
      return TextFormField(
        key: ValueKey('$keyPrefix-$i-${c.key}'),
        initialValue: '${r[c.key] ?? ''}',
        keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        inputFormatters: numeric ? numberOnly(TextInputType.numberWithOptions(decimal: c.kind == 'money')) : null,
        style: inter(14, 500),
        decoration: formBox(label: c.label, hint: c.hint.isEmpty ? null : c.hint, prefix: c.kind == 'money' ? '₹ ' : null),
        onChanged: (v) => rows[i] = {...rows[i], c.key: numeric ? (num.tryParse(v) ?? (v.isEmpty ? null : v)) : v},
      );
    }

    final remove = IconButton(
      key: ValueKey('$keyPrefix-$i-remove'),
      tooltip: 'Remove',
      visualDensity: VisualDensity.compact,
      onPressed: () => onChanged([...rows]..removeAt(i)),
      icon: const Icon(LucideIcons.trash2, size: 17, color: kError),
    );
    return Padding(
      key: ValueKey('$keyPrefix-row-$i'),
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(builder: (context, b) {
        // one line only when there is room: on a phone three or more boxes go on two lines, so no label is squeezed
        if (columns.length <= 2 || b.maxWidth >= 560) {
          return Row(children: [
            for (final (j, c) in columns.indexed) ...[if (j > 0) const SizedBox(width: 8), Expanded(flex: c.flex, child: box(c))],
            remove,
          ]);
        }
        final half = (columns.length / 2).ceil();
        Widget line(Iterable<RowColumn> cs) => Row(children: [for (final (j, c) in cs.indexed) ...[if (j > 0) const SizedBox(width: 8), Expanded(flex: c.flex, child: box(c))]]);
        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
          decoration: BoxDecoration(color: const Color(0xFFF9FAF9), borderRadius: BorderRadius.circular(12), border: Border.all(color: kLine)),
          child: Column(children: [
            Row(children: [Expanded(child: line(columns.take(half))), remove]),
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.only(right: 48), child: line(columns.skip(half))),
          ]),
        );
      }),
    );
  }
}

/// Pick any number (the design's amenities): the chosen are green; "+ Add" takes the publisher's own.
class MultiChips extends StatelessWidget {
  const MultiChips({super.key, required this.options, required this.selected, required this.onChanged, required this.keyPrefix, this.addTitle = 'Add your own'});
  final List<String> options, selected;
  final ValueChanged<List<String>> onChanged;
  final String keyPrefix, addTitle;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final o in {...options, ...selected})
          FilterChip(
            key: ValueKey('$keyPrefix-$o'),
            label: Text(o),
            selected: selected.contains(o),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            labelStyle: inter(12.5, 600, color: selected.contains(o) ? kGreenText : kInk),
            selectedColor: kChipGreen,
            backgroundColor: Colors.white,
            side: BorderSide(color: selected.contains(o) ? kGreenText : kLine),
            // the brackets matter: without them the remove ran on both branches and a tap never stuck (fixed 4 Nov 2026)
            onSelected: (on) => onChanged(on ? [...selected, o] : ([...selected]..remove(o))),
          ),
        ActionChip(
          key: ValueKey('$keyPrefix-add'),
          label: Text('+ Add', style: inter(12.5, 700, color: kGreenText)),
          visualDensity: VisualDensity.compact,
          backgroundColor: Colors.white,
          side: const BorderSide(color: kGreenText),
          onPressed: () async {
            final t = await askOwn(context, addTitle);
            if (t != null && !selected.contains(t)) onChanged([...selected, t]);
          },
        ),
      ]);
}

/// A switch with its label and a short line under it (the design's toggles).
Widget switchRow({required Key key, required String label, String line = '', required bool value, required ValueChanged<bool> onChanged}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: inter(14, 600)),
            if (line.isNotEmpty) Text(line, style: inter(12, 400, color: kMuted)),
          ]),
        ),
        Switch(key: key, value: value, activeTrackColor: kGreenText, onChanged: onChanged),
      ]),
    );
