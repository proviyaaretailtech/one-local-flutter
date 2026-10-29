// Order views shaped like the server's (One Local server/partner-orders-pos.ts shapeView / shapeCard), for tests and the visual preview.

const orderId = '11111111-1111-1111-1111-111111111111';

/// Items as the server returns them for the Figma bill (5 lines, 9 units).
List<Map<String, dynamic>> _items(String state, {int picked = 0}) => [
      for (final (i, name, qty, amount) in const [
        (1, 'Amul Butter 500g', 2, 640),
        (2, 'Britannia Good Day 600g', 1, 280),
        (3, 'Parle Monaco 200g', 3, 180),
        (4, 'Horlicks 500g', 1, 320),
        (5, 'Kinley Mineral Water 1L', 2, 180),
      ])
        {
          'order_item_id': '0000000$i-0000-0000-0000-000000000000',
          'menu_item_id': 'm$i',
          'name': name,
          'qty': qty,
          'picked_qty': picked == 0 ? 0 : qty,
          'missing_qty': 0,
          'amount': amount,
          'sub': '$qty ${qty == 1 ? 'unit' : 'units'} ordered · $state',
        },
    ];

/// One order view shaped like the server's (server/partner-orders-pos.ts shapeView), per stage.
/// [photo]: the packed-bag photo ({id, has_photo, skip_reason, at}); [photoRequired]: the store asks for one.
Map<String, dynamic> view(String stage, {int version = 2, Map<String, dynamic>? photo, bool photoRequired = true, bool online = false}) {
  const titles = {
    'checkout': 'Checkout', 'pending': 'Order Confirmation', 'preparing': 'Order Preparing', 'picked': 'Order Picked', 'ready': 'Order Ready',
    'in_transit': 'Order In Transit', 'exception': 'Order Exception', 'cancelled': 'Order Cancelled', 'completed': 'Order Completed',
  };
  const status = {
    'checkout': 'Held · awaiting payment', 'pending': 'Pending', 'preparing': 'Preparing', 'picked': 'Preparing', 'ready': 'Ready',
    'in_transit': 'Dispatched', 'exception': 'Ready', 'cancelled': 'Cancelled', 'completed': 'Completed',
  };
  const fulfil = {
    'checkout': 'Not started', 'pending': 'Awaiting store acceptance', 'preparing': 'Picking items · 0 of 9 checked', 'picked': '9 of 9 units picked · not packed',
    'ready': '9 of 9 units ready for handover', 'in_transit': 'In transit · delivery not confirmed', 'exception': 'Dispatch blocked · not handed over',
    'cancelled': 'Stopped · no units fulfilled', 'completed': 'Handed over · 16 Oct · 6:40 PM',
  };
  const actions = {
    'checkout': [['pay', 'Complete Payment', 'primary'], ['cancel', 'Cancel bill', 'secondary']],
    'pending': [['accept', 'Accept order', 'primary'], ['whatsapp', 'Send receipt on WhatsApp', 'link']],
    'preparing': [['pack_order', 'Pack order', 'primary'], ['report_missing', 'Something missing?', 'link']],
    'picked': [['pack_order', 'Pack order', 'primary'], ['report_missing', 'Something missing?', 'link']],
    'ready': [['handover', 'Customer collected it', 'primary'], ['dispatch', 'Send for delivery', 'secondary'], ['receipt', 'View receipt', 'link']],
    'in_transit': [['delivery_status', 'Mark delivered', 'primary'], ['report_delivery_issue', 'Report a delivery problem', 'secondary'], ['receipt', 'View receipt', 'link']],
    'exception': [['set_delivery_info', 'Resolve missing information', 'primary'], ['choose_collection', 'Arrange store collection', 'secondary'], ['exception_details', 'Review exception details', 'link']],
    'cancelled': [['review_cancellation', 'Review cancellation', 'primary'], ['new_cart', 'Create new cart from items', 'secondary'], ['receipt', 'View original bill', 'link']],
    'completed': [['print', 'Print receipt', 'primary'], ['whatsapp', 'Send by WhatsApp', 'secondary'], ['receipt', 'View receipt', 'link']],
  };
  final paid = stage == 'checkout' || stage == 'cancelled' ? 0 : 1840;
  final states = {'checkout': 'ready for checkout', 'pending': 'placed', 'preparing': 'awaiting pick check', 'picked': 'picked', 'ready': 'ready',
    'in_transit': 'in transit', 'exception': 'ready · dispatch blocked', 'cancelled': 'cancelled · retained in bill', 'completed': 'handed over'};
  return {
    'id': orderId,
    'display_no': 'P-01087',
    'stage': stage,
    'title': titles[stage],
    'danger': stage == 'exception',
    'channel_label': 'Store Checkout',
    'place_label': null,
    'customer': 'Guest',
    'placed_at': '6:23 PM',
    'order_status': status[stage],
    'fulfilment': fulfil[stage],
    'payment_chip': paid > 0 ? 'Paid · Cash' : (stage == 'cancelled' ? 'Not captured' : 'Awaiting payment'),
    'note': stage == 'exception'
        ? {'tone': 'bad', 'title': 'Delivery information is missing', 'body': 'Address and contact details unavailable. Confirm the handover method to proceed.'}
        : {'tone': stage == 'preparing' ? 'warn' : 'info', 'title': 'Note for $stage', 'body': 'Body for $stage'},
    'version': stage == 'checkout' || stage == 'cancelled' ? '2026-10-16T12:53:00.000Z' : version,
    'online': online,
    'steps': const {'pending': 0, 'preparing': 1, 'picked': 1, 'ready': 2, 'exception': 2, 'in_transit': 3, 'completed': 4}[stage] == null
        ? null
        : {'labels': ['Accept', 'Pack', online ? 'Rider' : 'Hand over', 'Done'], 'current': const {'pending': 0, 'preparing': 1, 'picked': 1, 'ready': 2, 'exception': 2, 'in_transit': 3, 'completed': 4}[stage]},
    'packed_photo': photo,
    'photo_required': photoRequired,
    'items': _items(states[stage]!, picked: stage == 'picked' ? 1 : 0),
    'summary': '5 lines · 9 units',
    'adjustments': 'No coupon · No tip added',
    'bill': {'subtotal': 1600, 'gst_pct': 5, 'gst': 80, 'service_charge': 160, 'discount': 0, 'round_off': 0, 'total': 1840},
    'payment': {
      'label': paid > 0 ? 'Cash tendered · settled amount ₹1,840' : 'Amount received · not yet captured',
      'settled': paid, 'due': 1840 - paid, 'method': paid > 0 ? 'Cash' : 'Not chosen', 'tendered': paid > 0 ? 2000 : 0, 'change': paid > 0 ? 160 : 0,
      'record': stage == 'checkout'
          ? null
          : paid > 0
              ? {'title': 'Cash payment', 'value': '₹1,840 settled', 'second': 'Balance due', 'second_value': '₹0', 'footer': 'Payment complete. Duplicate charging is disabled.'}
              : {'title': 'Cash payment', 'value': '₹0 captured', 'second': 'Refund due', 'second_value': '₹0', 'footer': 'No cash collected. No refund required.'},
    },
    'delivery': null,
    'exception': stage == 'exception' ? {'kind': 'delivery_info_missing', 'note': 'Address and contact details unavailable'} : null,
    'cancel_reason': stage == 'cancelled' ? 'Customer left' : null,
    'actions': [for (final a in actions[stage]!) {'id': a[0], 'label': a[1], 'style': a[2]}],
    'events': [{'message': 'P-01087 placed', 'at': '16 Oct · 6:23 PM'}],
    'receipt_text': 'Receipt P-01087\nTotal ₹1,840',
  };
}

Map<String, dynamic> card(String id, String status, String label, {String? state, String delivery = 'Not started · bill unpaid'}) => {
      'id': id, 'display_no': 'P-$id', 'channel_label': 'Store Checkout', 'customer': 'Rahul Mehta', 'placed_at': '09 Oct 2026 · 5:15 PM',
      'status': status, 'status_label': label, 'total': 980, 'items': '3 lines · 5 units', 'payment_status': 'Unpaid · ₹980 due', 'payment_mode': 'Not chosen',
      'delivery_status': delivery, 'delivery_time': 'Not delivered', 'refund_damages': 'None', 'state': ?state,
    };

