# Automatic interface translation

The template root mounts `AutomaticTranslationProvider` once for all routes.
Browser/device language priorities choose one of 71 supported languages, with
English as the fallback. Arabic, Hebrew, Persian and Urdu set right-to-left
document direction. A project's existing language selector can pass `language`
and its reviewed dictionary as hashed `reviewed` messages; these take priority.
Language does not change routes, authentication, money, dates or stored content.

The shared webpack loader discovers authored JSX text, literal alternatives,
template phrases and native `title`, `placeholder`, `alt` and accessibility labels.
Conditional branches, fragments and mapped JSX are traversed too; dynamic
attribute captions keep interpolation values separate from translation requests.
New pages and nested layouts inherit the provider and compiler without a route list.
React renders localized text; no DOM mutation or browser translation widget is used.
Each project owns `messages/automatic-source.json`; template sync never copies
another application's phrases or preferences. Startup/build prepares this manifest,
and development compilation updates it for newly added text.

Helper-generated UI labels need `useInterfaceTranslator()` (name the returned
function `translate`) around their authored phrases. Keep original field IDs,
option values and backend data separate from the translated display labels.
`useInterfaceLanguage()` exposes the currently rendered locale for built-in
`Intl.DisplayNames`, date or number formatting without translation requests.

Dynamic data is preserved. For public UI data such as a navigation registry, add
its JSON path to `package.json`'s `localization.catalogs` and render its authored
labels through `AutoText`. New entries in that registry are discovered automatically.
`localization.preserve` lists brands or technical labels that must stay unchanged.
Use `translate="no"` or `data-no-translate` on containers holding original prose.
Code, scripts, SVG/math content, textareas and editable content are not transformed.
Canvas text, imperative alerts, dynamic backend errors and application data need
the application's existing localization API or explicit `AutoText` integration.

The root server layout selects language from the request's weighted Accept-Language
header or a project's manual preference cookie. It awaits the complete dictionary
and passes the same snapshot into the client provider. The initial HTML and
hydration therefore use the same translated text, including accessibility labels.
Existing reviewed dictionaries still take priority.

Production builds generate all supported dictionaries into project-owned
`messages/automatic/<language>.json`. Each entry records its authored source so
unchanged translations are reused and only new or changed text needs generation.
Never template-sync these dictionaries across applications. Next output tracing
includes them in standalone deployments. Incomplete generation fails the build
instead of shipping a partial dictionary. Keep these files in version control.

Development scans new authored text and resolves any missing entries on the server
before rendering. Source manifests are written atomically, and dictionary caches
are keyed by manifest version so newly authored phrases invalidate stale results.
Clients request a complete internal dictionary when the language or source changes; they keep the previous complete language until it is ready.
OldBook persists manual choices in a cookie as well as its existing local storage;
legacy local-storage-only preferences migrate on the first visit. EliteCar retains
its existing preference cookies and regional settings. EDY stays automatic.

Only authored manifest phrases are eligible for machine translation. Dynamic
names, passwords, form values, private content and interpolation values never go
to the provider. `/ui-localization` cannot accept arbitrary text. The default
provider matches the existing catalog tooling; set `TRANSLATION_BUILD_ENDPOINT`
in the root environment for a compatible managed endpoint. Published dictionaries
need no live translation provider. Machine wording still needs language review.

Run `node --test localization/tests.cjs` from `frontend/web`. The shared CI workflow
runs these tests in every receiving project. Production and development currently
use `--webpack`, as configured by the template scripts.
