'use client';
import {Fragment, createContext, createElement, useCallback, useContext, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode} from 'react';
import {detectLocale, direction, matchLocale, textKey} from './core.cjs';
import sources from '../messages/automatic-source.json';

type Catalog = Record<string, string>;
type TranslationContext = {language: string; catalog: Catalog; register: (source: string) => void};
const Context = createContext<TranslationContext>({language: 'en', catalog: {}, register: () => {}});
const EMPTY: Catalog = {};
const subscribeDevice = (notify: () => void) => {window.addEventListener('languagechange', notify); return () => window.removeEventListener('languagechange', notify);};
const deviceLanguage = () => detectLocale(navigator.languages?.length ? navigator.languages : [navigator.language]);

// The root provider covers every route, including client navigation and newly added pages.
export function AutomaticTranslationProvider({children, language, reviewed = EMPTY}: {children: ReactNode; language?: string; reviewed?: Catalog}) {
  const device = useSyncExternalStore(subscribeDevice, deviceLanguage, () => 'en');
  const locale = matchLocale(language) ?? device;
  const [remote, setRemote] = useState<{language: string; messages: Catalog}>({language: '', messages: EMPTY});
  const catalog = useMemo(() => ({...(remote.language === locale ? remote.messages : EMPTY), ...reviewed}), [remote, locale, reviewed]);
  const pending = useRef(new Set<string>());
  const known = useRef<Catalog>({});
  const knownLanguage = useRef('');
  const controller = useRef<AbortController | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const flush = useRef<() => Promise<void>>(async () => {});
  const active = useRef(false);
  const failures = useRef(new Map<string, number>());
  const attempts = useRef(new Map<string, number>());

  useEffect(() => {
    document.documentElement.lang = locale;
    document.documentElement.dir = direction(locale);
    controller.current?.abort(); controller.current = new AbortController();
    known.current = reviewed; knownLanguage.current = locale; failures.current.clear(); attempts.current.clear();
    active.current = false;
    const signal = controller.current.signal;
    flush.current = async () => {
      if (active.current || signal.aborted) return;
      active.current = true;
      try {
        while (pending.current.size && !signal.aborted) {
          const ids = [...pending.current].slice(0, 35);
          ids.forEach(id => pending.current.delete(id));
          try {
            const response = await fetch('/ui-localization', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({language: locale, ids}), signal});
            if (!response.ok) throw Error('Translation unavailable');
            const data = await response.json() as {translations?: Catalog};
            if (signal.aborted) return;
            const additions = data.translations ?? {};
            known.current = {...known.current, ...additions};
            setRemote(current => ({language: locale, messages: {...(current.language === locale ? current.messages : EMPTY), ...additions}}));
          } catch {
            if (signal.aborted) return;
            ids.forEach(id => failures.current.set(id, Date.now()));
            const retryIds = ids.filter(id => (attempts.current.get(id) ?? 0) < 2);
            retryIds.forEach(id => attempts.current.set(id, (attempts.current.get(id) ?? 0) + 1));
            if (retryIds.length) {
              const retry = setTimeout(() => {if (!signal.aborted) {retryIds.forEach(id => pending.current.add(id)); void flush.current();}}, 30000);
              signal.addEventListener('abort', () => clearTimeout(retry), {once: true});
            }
          }
        }
      } finally {if (!signal.aborted) active.current = false;}
    };
    return () => {controller.current?.abort(); if (timer.current) clearTimeout(timer.current);};
  }, [locale, reviewed]);

  const register = useCallback((source: string) => {
    const id = textKey(source);
    if (!Object.hasOwn(sources, id)) return;
    if (Object.hasOwn(catalog, id) || knownLanguage.current === locale && (Object.hasOwn(known.current, id) || Date.now() - (failures.current.get(id) ?? 0) < 30000)) return;
    pending.current.add(id);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => {void flush.current();}, 30);
  }, [catalog, locale]);
  const value = useMemo(() => ({language: locale, catalog, register}), [locale, catalog, register]);
  return <Context.Provider value={value}>{children}</Context.Provider>;
}

export function useAutomaticTranslation(source: string): string {
  const {language, catalog, register} = useContext(Context);
  useEffect(() => {register(source);}, [source, language, catalog, register]);
  return catalog[textKey(source)] ?? source;
}

// Existing dictionary APIs can reuse the same cache without changing their selectors.
export function useInterfaceTranslator() {
  const {catalog, register} = useContext(Context);
  return useCallback((source: string) => {
    if (typeof window !== 'undefined' && !Object.hasOwn(catalog, textKey(source))) register(source);
    return catalog[textKey(source)] ?? source;
  }, [catalog, register]);
}

export function AutoText({source, values}: {source: string; values?: ReactNode[]}) {
  const translated = useAutomaticTranslation(source);
  if (!values) return translated;
  return translated.split(/(\{v\d+\})/g).map((part, index) => {
    const match = /^\{v(\d+)\}$/.exec(part);
    return <Fragment key={index}>{match ? values[Number(match[1])] : part}</Fragment>;
  });
}

export function AutoElement({as, translationAttributes, ...props}: {as: string; translationAttributes: string[]; [key: string]: unknown}) {
  const {language, catalog, register} = useContext(Context);
  const sources = translationAttributes.map(key => typeof props[key] === 'string' ? props[key] as string : '');
  const signature = JSON.stringify(sources);
  useEffect(() => {for (const source of JSON.parse(signature) as string[]) if (source) register(source);}, [signature, language, catalog, register]);
  const localized = {...props};
  translationAttributes.forEach((key, index) => {if (sources[index]) localized[key] = catalog[textKey(sources[index])] ?? sources[index];});
  return createElement(as, localized);
}
