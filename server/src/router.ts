// A tiny router: exact segments and `:param` segments, matched by method. 404 for no path, 405 when the path exists for other methods.
import { fail, route, type Handler } from './http.ts';

type Entry = { method: string; parts: string[]; handler: Handler };
const entries: Entry[] = [];

export function add(method: string, pattern: string, handler: Handler) {
  entries.push({ method, parts: pattern.split('/').filter(Boolean), handler: route(handler) });
}

export async function dispatch(request: Request): Promise<Response> {
  const parts = new URL(request.url).pathname.split('/').filter(Boolean);
  let pathSeen = false;
  for (const e of entries) {
    if (e.parts.length !== parts.length) continue;
    const params: Record<string, string> = {};
    let ok = true;
    for (let i = 0; i < parts.length && ok; i++) {
      if (e.parts[i].startsWith(':')) { try { params[e.parts[i].slice(1)] = decodeURIComponent(parts[i]); } catch { ok = false; } }
      else ok = e.parts[i] === parts[i];
    }
    if (!ok) continue;
    pathSeen = true;
    if (e.method === request.method) return e.handler(request, params);
  }
  return pathSeen ? fail(405, 'Method not allowed') : fail(404, 'Not found');
}
