// The customer's online bill (founder, 2 Nov 2026): GET /b/<code> answers the bill as a page, with a Print button. "Send by WhatsApp" on the
// till sends a short note with this link instead of the whole bill as text. Nobody is signed in here: the 12-letter code is the only key,
// pub_bill_view (service role only) reads the bill, and the page shows no phone number of the customer. The page is plain HTML with its
// own small style: it opens fast on any phone and prints cleanly.
import { createHash } from 'node:crypto';
import { db, mapDbError } from './db.ts';
import { clientIp, HttpError, limit } from './http.ts';

const CODE = /^[A-Za-z0-9]{12}$/;

type Row = Record<string, unknown>;
const num = (v: unknown) => Number(v ?? 0) || 0;
const esc = (v: unknown) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** ₹1,23,456.50 (Indian grouping; whole rupees drop the paise). */
export function rupees(v: unknown): string {
  const n = num(v), neg = n < 0, abs = Math.abs(Math.round(n * 100)) / 100;
  const [r, p] = abs.toFixed(2).split('.');
  const grouped = r.length <= 3 ? r : `${r.slice(0, -3).replace(/\B(?=(\d{2})+(?!\d))/g, ',')},${r.slice(-3)}`;
  return `${neg ? '−' : ''}₹${grouped}${p === '00' ? '' : `.${p}`}`;
}

const qty = (v: unknown) => { const n = num(v); return Number.isInteger(n) ? String(n) : String(+n.toFixed(3)); };

/** "Sun, 1 Nov 2026 · 2:54 PM", India time. */
function when(iso: unknown): string {
  const d = new Date(String(iso ?? ''));
  if (Number.isNaN(d.getTime())) return '';
  const part = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', ...o }).format(d);
  return `${part({ weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })} · ${part({ hour: 'numeric', minute: '2-digit', hour12: true }).toUpperCase()}`;
}

const METHODS: Record<string, string> = { cash: 'Cash', card: 'Card', upi: 'UPI', online: 'Online', wallet: 'Wallet', credit: 'Credit' };
const STATUS: Record<string, [string, string]> = {
  paid: ['Paid', 'ok'], part_paid: ['Part paid', 'warn'], unpaid: ['Not paid yet', 'warn'], cancelled: ['Cancelled', 'bad'],
};

const STYLE = `
:root{--ink:#14171c;--muted:#6b7280;--line:#e6e8e3;--bg:#f3f4f0;--card:#fff;--lime:#c6f432;--deep:#0f1a12;--ok:#1b7f3b;--okbg:#e7f6ec;--warn:#b45309;--warnbg:#fff4e0;--bad:#c62828;--badbg:#fdecec}
*{box-sizing:border-box}html,body{margin:0}
body{background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Inter,sans-serif;-webkit-text-size-adjust:100%}
.bar{background:var(--deep);color:#fff;padding:12px 16px}
.bar div{max-width:520px;margin:0 auto;display:flex;align-items:center;justify-content:space-between}
.brand{font-weight:800;font-size:17px;letter-spacing:-.01em}.brand i{font-style:normal;color:var(--lime)}
.bar small{color:#b8bcc4;font-size:12px}
.hero{background:linear-gradient(180deg,var(--deep) 0,var(--deep) 62%,var(--bg) 62%);padding:8px 16px 0}
.hero-card{max-width:520px;margin:0 auto;background:var(--card);border-radius:24px;padding:22px 20px;text-align:center;box-shadow:0 8px 24px rgba(15,26,18,.12)}
.logo{width:60px;height:60px;border-radius:16px;object-fit:cover;margin:0 auto 10px;display:block}
.mark{width:60px;height:60px;border-radius:16px;background:var(--lime);color:var(--deep);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:22px;margin:0 auto 10px}
.hello{font-size:15px;color:var(--muted);margin:0}
h1{font-size:20px;margin:2px 0 0;font-weight:800}
.amt{font-size:38px;font-weight:800;letter-spacing:-.02em;margin:14px 0 4px}
.chip{display:inline-block;padding:4px 12px;border-radius:99px;font-size:12.5px;font-weight:700}
.chip.ok{background:var(--okbg);color:var(--ok)}.chip.warn{background:var(--warnbg);color:var(--warn)}.chip.bad{background:var(--badbg);color:var(--bad)}
.facts{display:flex;justify-content:center;gap:8px;flex-wrap:wrap;margin-top:12px;color:var(--muted);font-size:13px}
.facts b{color:var(--ink)}
.wrap{max-width:520px;margin:0 auto;padding:14px 16px 40px}
.actions{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.btn{border:0;border-radius:14px;padding:14px 10px;font:700 14.5px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:8px}
.btn.dark{background:var(--ink);color:#fff}.btn.light{background:#fff;color:var(--ink);border:1px solid var(--line)}
.btn.wide{grid-column:1/-1}
.btn svg{width:18px;height:18px}
.card{background:var(--card);border-radius:20px;padding:20px;margin-top:14px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:0 0 6px}
.store{font-size:13px;color:var(--muted);margin:2px 0 0}
table{width:100%;border-collapse:collapse}
th{font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);font-weight:700;text-align:left;padding:10px 0 6px}
td{padding:9px 0;vertical-align:top;border-top:1px solid var(--line)}
.r{text-align:right;white-space:nowrap}.n{font-weight:600}.q{color:var(--muted);font-size:13px}
.row{display:flex;justify-content:space-between;padding:4px 0;font-size:14px}.row span{color:var(--muted)}
.total{display:flex;justify-content:space-between;align-items:baseline;margin-top:8px;padding-top:12px;border-top:2px solid var(--ink);font-weight:800;font-size:19px}
.thanks{text-align:center;margin-top:18px;font-size:15px;font-weight:700}
.thanks span{display:block;font-weight:400;color:var(--muted);font-size:13px;margin-top:2px}
.foot{text-align:center;color:var(--muted);font-size:12px;margin-top:18px}
.foot b{color:var(--ink)}
.err{text-align:center;padding:48px 20px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--ink);color:#fff;padding:10px 16px;border-radius:12px;font-size:14px;display:none}
@media print{body{background:#fff}.bar,.actions,.foot,.toast,.hello{display:none}.hero{background:none;padding:0}
  .hero-card{box-shadow:none;padding:0 0 10px;border-radius:0;border-bottom:1px dashed #999}.amt{font-size:26px}
  .wrap{padding:0;max-width:none}.card{padding:10px 0;margin:0}.chip{border:1px solid currentColor}@page{margin:12mm}}
`;

// the buttons: print (also "Save as PDF" from the print screen) and share the link with the phone's own share sheet
const SCRIPT = `document.addEventListener('click',function(e){var b=e.target.closest('[data-do]');if(!b)return;var d=b.getAttribute('data-do');
if(d==='print'||d==='pdf'){window.print();return}
if(d==='share'){var u=location.href,t=document.title;if(navigator.share){navigator.share({title:t,url:u}).catch(function(){})}
else if(navigator.clipboard){navigator.clipboard.writeText(u).then(function(){var x=document.getElementById('toast');x.style.display='block';setTimeout(function(){x.style.display='none'},1800)})}}});`;
const SCRIPT_HASH = createHash('sha256').update(SCRIPT).digest('base64');

const ICON = {
  print: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9V2h12v7"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="8"/></svg>',
  pdf: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/></svg>',
  share: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="M8.6 13.5l6.8 4M15.4 6.5l-6.8 4"/></svg>',
};

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><meta name="theme-color" content="#0f1a12"><title>${esc(title)}</title><style>${STYLE}</style></head>
<body><header class="bar"><div><span class="brand">One<i>Local</i></span><small>Digital bill</small></div></header>${body}<script>${SCRIPT}</script></body></html>`;
}

/** The bill's landing page: who it is from and what was paid at the top, the buttons, then the bill itself. */
export function billHtml(b: Row): string {
  const store = (b.store ?? {}) as Row;
  const addr = store.address && typeof store.address === 'object' ? (store.address as Row).line : store.address;
  const name = String(store.name ?? 'Your bill');
  const branch = store.branch && store.branch !== name ? String(store.branch) : '';
  const [statusText, tone] = STATUS[String(b.status)] ?? ['', 'ok'];
  const items = (Array.isArray(b.items) ? b.items : []) as Row[];
  const units = items.reduce((n, i) => n + num(i.qty), 0);
  const payments = (Array.isArray(b.payments) ? b.payments : []) as Row[];
  const methods = [...new Set(payments.map(p => METHODS[String(p.method)] ?? String(p.method)))].join(' + ');
  const gstPct = num(b.gst_pct);
  const rows = [
    ['Subtotal', rupees(b.subtotal)],
    num(b.discount) > 0 ? [`Discount${b.coupon ? ` (${esc(b.coupon)})` : ''}`, `−${rupees(b.discount)}`] : null,
    num(b.service_charge) > 0 ? ['Service charge', rupees(b.service_charge)] : null,
    num(b.gst) > 0 ? [`GST${gstPct ? ` (${+gstPct.toFixed(2)}%)` : ''}`, rupees(b.gst)] : null,
    num(b.round_off) !== 0 ? ['Round off', `${num(b.round_off) < 0 ? '−' : '+'}${rupees(Math.abs(num(b.round_off)))}`] : null,
  ].filter(Boolean) as string[][];
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map(w => w[0]).join('').toUpperCase();
  const logo = typeof store.logo_url === 'string' && /^https:\/\//.test(store.logo_url)
    ? `<img class="logo" src="${esc(store.logo_url)}" alt="">` : `<div class="mark">${esc(initials)}</div>`;
  const who = b.customer ? `Hi ${esc(String(b.customer).split(/\s+/)[0])}, thanks for shopping at` : 'Thanks for shopping at';
  return page(`Bill ${b.bill_no ?? ''} · ${name}`, `<section class="hero"><div class="hero-card">${logo}
  <p class="hello">${who}</p><h1>${esc(name)}</h1>
  <div class="amt">${rupees(b.total)}</div>${statusText ? `<span class="chip ${tone}">${esc(statusText)}${methods && b.status === 'paid' ? ` · ${esc(methods)}` : ''}</span>` : ''}
  <div class="facts"><span>Bill <b>${esc(b.bill_no)}</b></span><span>·</span><span>${esc(when(b.at))}</span></div></div></section>
<main class="wrap">
  <div class="actions">
    <button class="btn dark" type="button" data-do="print">${ICON.print}Print bill</button>
    <button class="btn light" type="button" data-do="pdf">${ICON.pdf}Save as PDF</button>
    <button class="btn light wide" type="button" data-do="share">${ICON.share}Share bill</button>
  </div>
  <div class="card"><h2>Bill details</h2>
    <p class="store"><b style="color:var(--ink)">${esc(name)}</b>${branch ? ` · ${esc(branch)}` : ''}</p>
    ${addr ? `<p class="store">${esc(addr)}</p>` : ''}${store.phone ? `<p class="store">Phone ${esc(store.phone)}</p>` : ''}${store.gstin ? `<p class="store">GSTIN ${esc(store.gstin)}</p>` : ''}
    ${b.customer ? `<p class="store">Customer: ${esc(b.customer)}</p>` : ''}
    <table><thead><tr><th>Item</th><th class="r">Qty × Price</th><th class="r">Amount</th></tr></thead><tbody>
    ${items.map(i => `<tr><td class="n">${esc(i.name)}</td><td class="r q">${qty(i.qty)} × ${rupees(i.price)}</td><td class="r">${rupees(i.amount)}</td></tr>`).join('')}
    </tbody></table>
    <div style="border-top:1px dashed var(--line);margin-top:4px;padding-top:8px">${rows.map(([k, v]) => `<div class="row"><span>${k}</span><b>${v}</b></div>`).join('')}
      <div class="total"><span>Total</span><span>${rupees(b.total)}</span></div></div>
    <p class="store" style="margin-top:10px">${items.length} ${items.length === 1 ? 'item' : 'items'} · ${qty(units)} ${units === 1 ? 'unit' : 'units'}${methods ? ` · Paid by ${esc(methods)}` : ''}</p>
    <p class="thanks">Thank you for shopping with us!<span>We hope to see you again soon.</span></p>
  </div>
  <p class="foot">${esc(name)} is a <b>OneLocal</b> partner store · paperless bill</p>
</main><div class="toast" id="toast">Link copied</div>`);
}

const HEADERS = {
  'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'private, no-store', 'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY',
  'X-Robots-Tag': 'noindex, nofollow', 'X-Content-Type-Options': 'nosniff',
  // only its own inline style and its one script (by hash); the store's logo may come from any https address
  'Content-Security-Policy': `default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-${SCRIPT_HASH}'; img-src https:; base-uri 'none'; form-action 'none'`,
};

const notFound = (status = 404, text = 'This bill link is not valid. Ask the store to send it again.') =>
  new Response(page('Bill not found', `<main class="wrap"><div class="card err"><h1>Bill not found</h1><p class="store">${esc(text)}</p></div></main>`), { status, headers: HEADERS });

/** GET /b/:code */
export async function billPage(request: Request, params: Record<string, string>): Promise<Response> {
  const code = params.code ?? '';
  try {
    limit(clientIp(request, request.headers.get('x-ol-peer') ?? undefined), 'bill:page', 60, 60_000);
  } catch (e) {
    if (e instanceof HttpError) return notFound(429, 'Too many tries. Please wait a minute and open the link again.');
    throw e;
  }
  if (!CODE.test(code)) return notFound();
  const { data, error } = await db().rpc('pub_bill_view', { p: { code } });
  if (error) {
    try { mapDbError(error); } catch (e) { if (e instanceof HttpError && e.status === 404) return notFound(); }
    return notFound(503, 'The bill could not be opened just now. Please try again in a moment.');
  }
  return new Response(billHtml((data ?? {}) as Row), { status: 200, headers: HEADERS });
}
