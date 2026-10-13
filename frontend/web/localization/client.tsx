'use client';
import {Fragment, createContext, createElement, useCallback, useContext, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode} from 'react';
import {detectLocale, direction, matchLocale, textKey, matchAuthoredPhrase} from './core.cjs';
import sources from '../messages/automatic-source.json';

type Catalog = Record<string, string>;
export type LocalizationSnapshot = {language: string; catalog: Catalog; sourceVersion?: string; manual?: boolean};
type TranslationContext = {language: string; catalog: Catalog};
const EMPTY: Catalog = {};
const SOURCE_VERSION = textKey(Object.keys(sources).sort().join(','));
const currentSource = (snapshot: LocalizationSnapshot) => !snapshot.sourceVersion || snapshot.sourceVersion === SOURCE_VERSION;
const Context = createContext<TranslationContext>({language: 'en', catalog: EMPTY});
const loaded = new Map<string, Catalog>();
const inflight = new Map<string, Promise<Catalog>>();
const subscribeDevice = (notify: () => void) => {window.addEventListener('languagechange', notify); return () => window.removeEventListener('languagechange', notify);};
const deviceLanguage = () => detectLocale(navigator.languages?.length ? navigator.languages : [navigator.language]);

export function preloadInterfaceLanguage(language: string): Promise<Catalog> {
  const locale = matchLocale(language);
  if (!locale) return Promise.reject(Error('Unsupported language'));
  if (loaded.has(locale)) return Promise.resolve(loaded.get(locale)!);
  if (inflight.has(locale)) return inflight.get(locale)!;
  const task = fetch('/ui-localization?language=' + encodeURIComponent(locale), {headers: {Accept: 'application/json'}})
    .then(async response => {
      if (!response.ok) throw Error('Interface dictionary unavailable');
      const data = await response.json() as {language: string; translations: Catalog};
      if (data.language !== locale || !data.translations) throw Error('Invalid interface dictionary');
      loaded.set(locale, data.translations);
      return data.translations;
    }).finally(() => inflight.delete(locale));
  inflight.set(locale, task);
  return task;
}

export function AutomaticTranslationProvider({children, initial, language, reviewed = EMPTY}: {children: ReactNode; initial?: LocalizationSnapshot; language?: string; reviewed?: Catalog}) {
  const serverLanguage = initial?.language ?? matchLocale(language) ?? 'en';
  const device = useSyncExternalStore(subscribeDevice, deviceLanguage, () => serverLanguage);
  const desired = matchLocale(language) ?? (initial?.manual ? serverLanguage : device);
  const [snapshot, setSnapshot] = useState<LocalizationSnapshot>(() => {
    if (typeof window !== 'undefined' && initial && currentSource(initial)) loaded.set(initial.language, initial.catalog);
    return initial ?? {language: serverLanguage, catalog: EMPTY};
  });
  // Keep the last complete language current when returning to the server snapshot.
  if (initial?.language === desired && currentSource(initial) && snapshot !== initial) setSnapshot(initial);
  const base = initial?.language === desired && currentSource(initial) ? initial : snapshot;
  const ready = (base.language !== desired || !currentSource(base)) && typeof window !== 'undefined' && loaded.has(desired)
    ? {language: desired, catalog: loaded.get(desired)!, sourceVersion: SOURCE_VERSION} : base;
  useEffect(() => {
    if (initial && currentSource(initial)) loaded.set(initial.language, initial.catalog);
  }, [initial]);
  const baseCurrent = currentSource(base);
  useEffect(() => {
    if (base.language === desired && baseCurrent) return;
    let active = true;
    preloadInterfaceLanguage(desired).then(catalog => {if (active) setSnapshot({language: desired, catalog, sourceVersion: SOURCE_VERSION});}).catch(() => {});
    return () => {active = false;};
  }, [desired, base.language, baseCurrent]);
  const catalog = useMemo(() => ({...ready.catalog, ...(ready.language === desired ? reviewed : EMPTY)}), [ready.catalog, ready.language, desired, reviewed]);
  useEffect(() => {
    document.documentElement.lang = ready.language;
    document.documentElement.dir = direction(ready.language);
  }, [ready.language]);
  const value = useMemo(() => ({language: ready.language, catalog}), [ready.language, catalog]);
  return <Context.Provider value={value}>{children}</Context.Provider>;
}

function translatedText(catalog: Catalog, language: string, source: string): string {
  const translated = catalog[textKey(source)];
  // Known authored text never flashes in the source language while a new dictionary loads.
  return translated ?? (language === 'en' || !Object.hasOwn(sources, textKey(source)) ? source : '');
}
export function useInterfaceLanguage(): string {
  return useContext(Context).language;
}
export function useAutomaticTranslation(source: string): string {
  const {language, catalog} = useContext(Context);
  return translatedText(catalog, language, source);
}
export function useInterfaceTranslator() {
  const {language, catalog} = useContext(Context);
  return useCallback((source: string) => translatedText(catalog, language, source), [language, catalog]);
}
export function AutoText({source, values, candidates}: {source: string; values?: ReactNode[]; candidates?: string[]}) {
  const matched = candidates ? matchAuthoredPhrase(source, candidates) : undefined;
  const translated = useAutomaticTranslation(matched?.source ?? (typeof source === 'string' ? source : ''));
  if (candidates && !matched) return source ?? '';
  const interpolations = values ?? matched?.values;
  if (!interpolations) return translated;
  return translated.split(/(\{v\d+\})/g).map((part, index) => {
    const match = /^\{v(\d+)\}$/.exec(part);
    return <Fragment key={index}>{match ? interpolations[Number(match[1])] : part}</Fragment>;
  });
}
export function AutoElement({as, translationAttributes = [], translationTemplates = {}, translationCandidates = {}, ...props}: {as: string; translationAttributes?: string[]; translationTemplates?: Record<string, {source: string; values: unknown[]}>; translationCandidates?: Record<string, string[]>; [key: string]: unknown}) {
  const {language, catalog} = useContext(Context);
  const localized = {...props};
  translationAttributes.forEach(key => {if (typeof props[key] === 'string') localized[key] = translatedText(catalog, language, props[key]);});
  Object.entries(translationCandidates).forEach(([key, candidates]) => {
    const matched = matchAuthoredPhrase(props[key], candidates);
    if (matched) localized[key] = translatedText(catalog, language, matched.source).replace(/\{v(\d+)\}/g, (_token, index) => String(matched.values?.[Number(index)] ?? ''));
  });
  Object.entries(translationTemplates).forEach(([key, template]) => {
    localized[key] = translatedText(catalog, language, template.source).replace(/\{v(\d+)\}/g, (_token, index) => String(template.values[Number(index)] ?? ''));
  });
  return createElement(as, localized);
}
