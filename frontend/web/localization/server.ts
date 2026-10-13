import 'server-only';
import {cookies, headers} from 'next/headers';
import {unstable_cache} from 'next/cache';
import initialSource from '../messages/automatic-source.json';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {prepareCatalog} from './catalog.cjs';
import {createService} from './service.cjs';
import {detectHeaderLocale, matchLocale, locales, textKey} from './core.cjs';
import type {LocalizationSnapshot} from './client';


// Built dictionaries travel with the application; a new development phrase is
// resolved on the server before rendering, never after displaying source text.
const catalogs = new Map<string, Promise<Record<string, string>>>();
export function getInterfaceCatalog(language: string): Promise<Record<string, string>> {
  const locale = matchLocale(language);
  if (!locale) return Promise.reject(Error('Unsupported interface language'));
  // The compiler can discover phrases after this module has loaded in development.
  const manifest = process.env.NODE_ENV === 'production' ? JSON.stringify(initialSource)
    : readFileSync(join(process.cwd(), 'messages/automatic-source.json'), 'utf8');
  const source = JSON.parse(manifest) as Record<string, string>;
  const key = locale + ':' + createHash('sha256').update(manifest).digest('hex');
  if (catalogs.has(key)) return catalogs.get(key)!;
  const translate = createService({source, cache: unstable_cache});
  const resolveMissing = process.env.NODE_ENV === 'production'
    ? async () => {throw Error('Missing compiled interface dictionary; rebuild this project');} : translate;
  const task = prepareCatalog(process.cwd(), locale, source, {translate: resolveMissing, persist: false})
    .catch(error => {catalogs.delete(key); throw error;});
  // Bound cache versions as developers continue adding interface text.
  if (catalogs.size >= 100) catalogs.delete(catalogs.keys().next().value!);
  catalogs.set(key, task);
  return task;
}

export async function getInitialLocalization(language?: string): Promise<LocalizationSnapshot> {
  const [cookieStore, headerStore] = await Promise.all([cookies(), headers()]);
  const manual = matchLocale(cookieStore.get('UI_LANGUAGE')?.value);
  const locale = matchLocale(language) ?? manual ?? detectHeaderLocale(headerStore.get('accept-language'));
  const catalog = await getInterfaceCatalog(locale);
  return {language: locale, catalog, sourceVersion: textKey(Object.keys(catalog).sort().join(',')), manual: Boolean(language || manual)};
}

// Migrate older browser-only manual preferences before the document body paints.
export function manualLanguageBootstrap(storageKey: string, cookieName: string, automaticValue?: string): string {
  const options = JSON.stringify({storageKey, cookieName, automaticValue, locales}).replaceAll('<', '\\u003c');
  return `(function(){try{var o=${options},v=localStorage.getItem(o.storageKey);if(!o.locales.includes(v)&&v!==o.automaticValue)return;var expected=v===o.automaticValue?'':v;var read=function(){var c=document.cookie.split('; ').find(function(x){return x.startsWith(o.cookieName+'=');});return c?decodeURIComponent(c.slice(o.cookieName.length+1)):'';};if(read()===expected)return;document.cookie=o.cookieName+'='+expected+'; Path=/; Max-Age='+(expected?'31536000':'0')+'; SameSite=Lax';if(read()===expected)location.reload();}catch(e){}})();`;
}
