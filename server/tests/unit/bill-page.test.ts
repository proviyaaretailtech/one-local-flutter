// The customer's online bill (2 Nov 2026): GET /b/<code>, a printable page from pub_bill_view.
import test from 'node:test';
import assert from 'node:assert/strict';
import { billHtml, billPage, rupees } from '../../src/bill-page.ts';

const bill = {
  store: { name: 'Sharma General Store', branch: 'Sharma General Store - Main', address: { line: '123, Kothrud, Pune' }, phone: '+917715956686', gstin: null, logo_url: null },
  bill_no: 'P-00027', at: '2026-11-01T09:24:00Z', customer: 'vaishnavi', status: 'paid',
  items: [{ name: 'Amul Butter 500g', qty: 1, price: 285, amount: 285 }, { name: '<script>x</script>', qty: 2, price: 1234.5, amount: 2469 }],
  subtotal: 2754, discount: 0, service_charge: 0, gst_pct: 0, gst: 0, round_off: 0, total: 2754, paid: 2754, payments: [{ method: 'cash', amount: 2754 }],
};

test('rupees: Indian grouping, paise only when there are any', () => {
  assert.equal(rupees(930), '₹930');
  assert.equal(rupees(123456.5), '₹1,23,456.50');
  assert.equal(rupees(-12), '−₹12');
});

test('the page: store, bill no, every item, total, paid status and a Print button; names are escaped', () => {
  const html = billHtml(bill);
  for (const s of ['Sharma General Store', 'Sharma General Store - Main', '123, Kothrud, Pune', 'P-00027', 'Amul Butter 500g', '2 × ₹1,234.50', '₹2,754', 'Paid', 'Paid by Cash', 'Print bill']) {
    assert.ok(html.includes(s), s);
  }
  assert.ok(html.includes('2:54 PM')); // India time
  assert.ok(!html.includes('<script>x'));
  assert.ok(html.includes('&lt;script&gt;x&lt;/script&gt;'));
  assert.ok(!html.includes('7715956686') || html.includes('Phone +917715956686')); // only the store's phone, never the customer's
});

test('a code that is not 12 letters and digits is "not found" without asking the database', async () => {
  const r = await billPage(new Request('http://x/b/nope'), { code: 'nope' });
  assert.equal(r.status, 404);
  assert.match(await r.text(), /Bill not found/);
  assert.equal(r.headers.get('X-Robots-Tag'), 'noindex, nofollow');
});
