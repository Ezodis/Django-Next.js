import 'server-only';
import {cookies, headers} from 'next/headers';
import {unstable_cache} from 'next/cache';
import source from '../messages/automatic-source.json';
import {prepareCatalog} from './catalog.cjs';
import {createService} from './service.cjs';
import {detectHeaderLocale, matchLocale, locales} from './core.cjs';
import type {LocalizationSnapshot} from './client';

const translate = createService({source, cache: unstable_cache});
// Built dictionaries travel with the application; a new development phrase is
// resolved on the server before rendering, never after displaying source text.
const catalogs = new Map<string, Promise<Record<string, string>>>();
export function getInterfaceCatalog(language: string): Promise<Record<string, string>> {
  const locale = matchLocale(language);
  if (!locale) return Promise.reject(Error('Unsupported interface language'));
  if (catalogs.has(locale)) return catalogs.get(locale)!;
  const resolveMissing = process.env.NODE_ENV === 'production'
    ? async () => {throw Error('Missing compiled interface dictionary; rebuild this project');} : translate;
  const task = prepareCatalog(process.cwd(), locale, source, {translate: resolveMissing, persist: false})
    .catch(error => {catalogs.delete(locale); throw error;});
  catalogs.set(locale, task);
  return task;
}

export async function getInitialLocalization(language?: string): Promise<LocalizationSnapshot> {
  const [cookieStore, headerStore] = await Promise.all([cookies(), headers()]);
  const manual = matchLocale(cookieStore.get('UI_LANGUAGE')?.value);
  const locale = matchLocale(language) ?? manual ?? detectHeaderLocale(headerStore.get('accept-language'));
  return {language: locale, catalog: await getInterfaceCatalog(locale), manual: Boolean(language || manual)};
}

// Migrate older browser-only manual preferences before the document body paints.
export function manualLanguageBootstrap(storageKey: string, cookieName: string, automaticValue?: string): string {
  const options = JSON.stringify({storageKey, cookieName, automaticValue, locales}).replaceAll('<', '\\u003c');
  return `(function(){try{var o=${options},v=localStorage.getItem(o.storageKey);if(!o.locales.includes(v)&&v!==o.automaticValue)return;var expected=v===o.automaticValue?'':v;var read=function(){var c=document.cookie.split('; ').find(function(x){return x.startsWith(o.cookieName+'=');});return c?decodeURIComponent(c.slice(o.cookieName.length+1)):'';};if(read()===expected)return;document.cookie=o.cookieName+'='+expected+'; Path=/; Max-Age='+(expected?'31536000':'0')+'; SameSite=Lax';if(read()===expected)location.reload();}catch(e){}})();`;
}
