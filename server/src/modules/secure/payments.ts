// Payment provider hook (Razorpay / Cashfree). NOT CONNECTED: no provider account or webhook secret exists yet, so these answer 501 and
// change nothing. When a provider is connected, this is the only place that may hold its secret and the only code that verifies a
// webhook signature; it must then hand the verified event to a database function (which decides what it means), never write tables itself.
// Env names reserved: RAZORPAY_WEBHOOK_SECRET, CASHFREE_WEBHOOK_SECRET. See ENDPOINTS.md "secret-bearing".
import { json, fail } from '../../http.ts';

export function webhook(provider: 'razorpay' | 'cashfree') {
  return async (_request: Request): Promise<Response> => {
    const secret = provider === 'razorpay' ? process.env.RAZORPAY_WEBHOOK_SECRET : process.env.CASHFREE_WEBHOOK_SECRET;
    if (!secret) return fail(501, 'Payment provider is not connected.', undefined, 'not_configured');
    // Signature verification and the hand-off to the database go here once a provider is connected.
    return json({ received: false }, { status: 501 });
  };
}
