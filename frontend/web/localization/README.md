# Automatic interface translation

The template root mounts `AutomaticTranslationProvider` once for all routes.
Browser/device language priorities choose one of 71 supported languages, with
English as the fallback. Arabic, Hebrew, Persian and Urdu set right-to-left
document direction. A project's existing language selector can pass `language`
and its reviewed dictionary as hashed `reviewed` messages; these take priority.
Language does not change routes, authentication, money, dates or stored content.

The shared webpack loader discovers authored JSX text, literal alternatives,
template phrases and native `title`, `placeholder`, `alt` and accessibility labels.
New pages and nested layouts inherit the provider and compiler without a route list.
React renders localized text; no DOM mutation or browser translation widget is used.
Each project owns `messages/automatic-source.json`; template sync never copies
another application's phrases or preferences. Startup/build prepares this manifest,
and development compilation updates it for newly added text.

Dynamic data is preserved. For public UI data such as a navigation registry, add
its JSON path to `package.json`'s `localization.catalogs` and render its authored
labels through `AutoText`. New entries in that registry are discovered automatically.
`localization.preserve` lists brands or technical labels that must stay unchanged.
Use `translate="no"` or `data-no-translate` on containers holding original prose.
Code, scripts, SVG/math content, textareas and editable content are not transformed.
Canvas text, imperative alerts, dynamic backend errors and application data need
the application's existing localization API or explicit `AutoText` integration.

Clients request only manifest IDs and the selected language through `/ui-localization`.
The endpoint validates IDs against compiled application source. It cannot accept
arbitrary text, names, passwords, form values or messages for translation.
Interpolation values stay in the browser; only authored static phrase fragments
are eligible for translation. Unknown/private values are never sent to the provider.

The server batches missing phrases, shares in-flight work, uses Next's persistent
data cache, and bounds the in-process cache. Existing reviewed translations win.
Cold uncached text initially displays its original wording; cached responses are
reused across pages. Provider failures retain original text and trigger bounded
retries. The default endpoint matches the existing catalog generation tooling;
set `TRANSLATION_BUILD_ENDPOINT` in the root environment to use a compatible
managed endpoint. A redeployment/platform cache reset can require translations
to be fetched again. Machine wording remains subject to language review.

Run `node --test localization/tests.cjs` from `frontend/web`. The shared CI workflow
runs these tests in every receiving project. Production and development currently
use `--webpack`, as configured by the template scripts.
