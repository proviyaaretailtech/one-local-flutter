// The guest menu web page (a Flutter web build of lib/guest_web_main.dart, built by ../tool/build_guest_web.sh into public/t/). A scanned
// table code opens <this server>/t/<code>; any path under /t/ that is not a built file answers with the page itself, which reads the code
// from its own address. Static files only: no data, no database. Nothing outside the build folder can be named (no dot segments).
import { readFile, stat } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fail } from './http.ts';

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json',
  '.css': 'text/css; charset=utf-8', '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2', '.bin': 'application/octet-stream', '.frag': 'application/octet-stream', '.txt': 'text/plain; charset=utf-8',
};
const SEGMENT = /^[A-Za-z0-9_@+-][A-Za-z0-9_.@+-]{0,127}$/;   // no "..", no hidden files, no separators

export const guestWebDir = () => resolve(process.env.GUEST_WEB_DIR?.trim() || fileURLToPath(new URL('../public/t', import.meta.url)));

const headers = (type: string) => ({ 'Content-Type': type, 'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY', 'Permissions-Policy': 'camera=(), microphone=(), geolocation=()' });

async function file(path: string): Promise<Buffer | null> {
  try { return (await stat(path)).isFile() ? await readFile(path) : null; } catch { return null; }
}

/** GET /t, /t/<code>, /t/<asset path> */
export async function guestWeb(request: Request): Promise<Response> {
  const parts = new URL(request.url).pathname.split('/').filter(Boolean).slice(1);
  let segs: string[];
  try { segs = parts.map(decodeURIComponent); } catch { return fail(404, 'Not found'); }
  if (segs.some(s => !SEGMENT.test(s) || s.startsWith('.'))) return fail(404, 'Not found');
  const dir = guestWebDir();
  if (segs.length) {
    const target = resolve(join(dir, ...segs));
    if (target.startsWith(dir + '/')) {
      const body = await file(target);
      if (body) return new Response(new Uint8Array(body), { status: 200, headers: headers(TYPES[extname(target).toLowerCase()] ?? 'application/octet-stream') });
    }
    // an asset that is not there is a 404; anything else is a page address (the table code) and gets the page
    if (segs.length > 1 || extname(segs[0])) return fail(404, 'Not found');
  }
  const page = await file(join(dir, 'index.html'));
  if (!page) return new Response('The guest menu is not built on this server yet.', { status: 503, headers: headers('text/plain; charset=utf-8') });
  return new Response(new Uint8Array(page), { status: 200, headers: headers('text/html; charset=utf-8') });
}
