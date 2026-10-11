import {unstable_cache} from 'next/cache';
import source from '../../messages/automatic-source.json';
import {createService} from '../../localization/service.cjs';
import {matchLocale, textKey} from '../../localization/core.cjs';
import {getInterfaceCatalog} from '../../localization/server';

export const runtime = 'nodejs';
const translate = createService({source, cache: unstable_cache});
export async function GET(request: Request) {
  const language = matchLocale(new URL(request.url).searchParams.get('language'));
  if (!language) return Response.json({error: 'Invalid language'}, {status: 400});
  try {
    return Response.json({language, translations: await getInterfaceCatalog(language)}, {headers: {'Cache-Control': 'no-store'}});
  } catch {
    return Response.json({error: 'Interface dictionary unavailable'}, {status: 503});
  }
}
export async function POST(request: Request) {
  if (Number(request.headers.get('content-length') ?? 0) > 4096) return Response.json({error: 'Request too large'}, {status: 413});
  try {
    const reader = request.body?.getReader();
    if (!reader) return Response.json({error: 'Invalid request'}, {status: 400});
    const chunks: Uint8Array[] = []; let length = 0;
    while (true) {
      const {done, value} = await reader.read(); if (done) break;
      length += value.length;
      if (length > 4096) {await reader.cancel(); return Response.json({error: 'Request too large'}, {status: 413});}
      chunks.push(value);
    }
    const body = Buffer.concat(chunks).toString('utf8');
    const data = JSON.parse(body);
    if (!matchLocale(data.language) || !Array.isArray(data.ids) || !data.ids.length || data.ids.length > 35 || data.ids.some((id: unknown) => typeof id !== 'string' || !Object.hasOwn(source, id) || textKey(source[id as keyof typeof source]) !== id)) return Response.json({error: 'Invalid interface phrase IDs'}, {status: 400});
    const translations = await translate(data);
    return Response.json({translations}, {headers: {'Cache-Control': 'no-store'}});
  } catch {
    return Response.json({error: 'Translation temporarily unavailable'}, {status: 503, headers: {'Retry-After': '30'}});
  }
}
