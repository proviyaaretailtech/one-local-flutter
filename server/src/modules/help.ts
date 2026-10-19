// Static help content for Support & Help (Figma section P). Content, not business data: the FAQ, the help categories and the support hours.
// Served by the gateway's `local` entry pos_help_content; nothing here touches the database.
export function helpContent() {
  return {
    hours: '9 AM–9 PM',
    faq: [
      { id: 'accept-order', question: 'How do I accept a new order?', answer: 'Open Online orders, tap the new order, check the items and press Accept. The customer is told straight away. If you cannot make it, press Reject and pick a reason.' },
      { id: 'payout-timing', question: 'When will my payout reach my bank?', answer: 'Payouts are settled to the bank account in Settings > Bank details. Settlement timing is shown in Money > Settlements. If the account says Unverified, payouts wait until it is verified.' },
      { id: 'update-stock', question: 'How do I update my stock?', answer: 'Open Stock, choose the item and record a receipt, an adjustment or a transfer. Large adjustments may need an approval.' },
      { id: 'change-hours', question: 'How do I change my opening hours?', answer: 'Open Settings > Opening & closing timings, choose the times and press Save.' },
      { id: 'bank-details', question: 'Why must my bank details match the Shop Act?', answer: 'The account holder name must match the name on your Shop Act licence so payouts can be verified and released.' },
    ],
    categories: [
      { id: 'orders', title: 'Orders', hint: 'Accept, cancel or deliver', topic: 'orders' },
      { id: 'payments', title: 'Payments', hint: 'Payments and bank payouts', topic: 'payments' },
      { id: 'inventory', title: 'Inventory', hint: 'Add items and update stock', topic: 'inventory' },
      { id: 'account', title: 'Account', hint: 'Store details and verification', topic: 'account' },
    ],
  };
}
