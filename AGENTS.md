# Repository rules for coding agents

These rules apply throughout this repository unless the user explicitly requests
otherwise. Preserve unrelated local changes and work within the requested scope.

## Reuse the existing structure

- Inspect existing implementations before editing. Extend the current files and
  established extension points rather than creating duplicate implementations.
- Do not introduce extra configuration files, helper folders, example services,
  or scaffolding merely for convenience. Create a new file only when the feature
  requires it and no existing file provides an appropriate home.
- The root `.env` is the single source of truth for environment values. Do not
  add backend `.env` files or `.env.example` files. Do not commit or print secrets.

## Keep shared architecture generic

- `backend/config/`, `dev.sh`, `dev.ps1`, and `dev.yml` are shared template
  infrastructure. Modify them only for reusable structural changes or generic
  infrastructure fixes that apply across projects using this template.
- A structural change improves shared behavior such as discovery, bootstrap,
  routing infrastructure, settings loading, container setup, or template sync.
  It must work without knowing this project's name, apps, integrations, or data.
- Do not add project names, domains, local IP addresses, business rules, database
  table names, integration-specific credentials, or app-specific startup logic
  to shared infrastructure. Making a project-specific branch configurable does
  not by itself make that branch appropriate for shared configuration.
- Apply the same boundary to shared Dockerfiles, backend entry points, template
  tools, and the core sections of shared requirements files. Consult
  `SHARED_PATHS` in `backend/config/project_config.py` for the sync boundary.
- Every project route on the shared proxy must match that project's explicit
  hostname. Do not add hostless catch-all frontend/API/admin/static/media routes.
  The sole development web origin is `https://dev.<project-domain>`. Resolve
  it with `development_hostname(root)` using root `.env` DEV_DOMAIN, a literal
  project.py DEV_DOMAIN, or the repository name, preserving dots and hyphens.
  A non-domain repository name uses `dev.<slug>.localhost` for computer-only
  development. Domain ownership and Cloudflare are not prerequisites for local
  development. Do not add compact spelling aliases or publish frontend/API
  host ports. Keep simulator bridges and Metro ports limited to their tooling.
  LAN is controlled per project: preserve separate loopback and LAN
  entrypoints, bounded local relay sources, and immediate revocation on off.
  Never expose database, Redis, Docker/Podman sockets or the proxy dashboard.
  Keep DEV_RESOURCE_NAMESPACE in project.py when renaming a project with data.
  Tunnel routes must match their assigned hostname too. Keep container, volume,
  service, router, and middleware names scoped to the project, and preserve the
  startup collision check before Compose can reuse another checkout's resources.

- `frontend/web/next.config.shared.ts` contains shared frontend development
  infrastructure and is included in template sync. Keep its behavior generic.
  Each project's existing `frontend/web/next.config.ts` wraps its own options
  with `withSharedDevConfig`; preserve its routes, plugins, upload limits, and
  other app settings. Do not sync entire frontend config files across projects.

## Put project-specific behavior in its existing home

- Use `backend/project.py` for settings overrides, extra installed apps, custom
  URL prefixes, integration configuration, optional `COMPOSE_SERVICES`, mobile
  ordering and metadata, and additional `SYNC_PROJECT_PATHS`.
- Declare optional environment inputs for new checkouts in a literal `ENV_DEFAULTS`
  mapping in `backend/project.py`. Do not place secrets in this mapping. Bootstrap
  scans active code only; existing root `.env` files are never template-synced.
- Keep bootstrap options consumed by `project_config.py` as literal strings,
  lists, or dictionaries. Do not make dev tooling execute project integrations
  just to read these options.
- Declare project-only developer commands in a literal `DEV_COMMANDS` mapping
  in `backend/project.py` (command name to function name). Implement those
  functions there; shared launchers discover the mapping without importing the
  project and execute a handler only when that command is explicitly requested.
- Keep business logic, models, views, migrations, and management commands in
  their existing Django apps. Use app management commands for app startup hooks.
- Declare optional application workers and drive mounts only in the project's
  literal `COMPOSE_SERVICES` and `OPTIONAL_BIND_MOUNTS`. Shared Compose contains
  core infrastructure and generic developer tools; never copy an application's
  mount paths, worker command, or integration environment into it.
- Declare legacy project-file moves in a literal `SYNC_RELOCATIONS` mapping
  (old relative path to new relative path) in `backend/project.py`. Sync validates
  paths and refuses to replace a different existing destination.
- Keep service implementation and custom Dockerfiles alongside the service,
  such as `backend/ml_service/Dockerfile`; do not place them in `backend/config/`.
  Declare a service in `project.py` only when that project actually needs it.
- Keep integration dependencies in the project's existing requirements files
  or below `# Project-specific integrations` in shared requirements files.
  Do not replace other projects' dependency additions with this project's ones.

## Verify and synchronize structural changes

- Before changing a shared file, identify why the change belongs in the template
  and how it stays independent of this project's implementation.
- Preserve project apps, migrations, frontend content, root `.env`, and project
  settings when updating shared architecture.
- Run checks appropriate to the change. For shared dev/config changes, check
  shell/PowerShell syntax, Python syntax, and sync previews as applicable. Do
  not add a separate permanent test file merely to verify a small reversible edit.
- `./dev.sh sync --dry-run` previews pulling shared architecture from the template.
  `./dev.sh sync push --dry-run` previews copying shared changes back to the local
  template checkout. Review the preview before applying a sync operation.
- `Django-Next.js` is the template for the projects maintained in this workspace.
  Sync configuration belongs in `backend/project.py` or the root `.env`, rather
  than a hardcoded repository name in shared dev scripts.
- Do not claim a structural update has reached other projects or GitHub unless
  it was actually synchronized or published. Report any remaining propagation
  or runtime verification work.

## Local network access

- Configured owned domains use `dev.<project-domain>` and publicly trusted TLS. The same
  HTTPS address is used with LAN off (computer only) and LAN on (trusted subnet).
  Keep the computer hosts override at loopback and publish DNS-only A records
  to the selected LAN IPv4. Do not expose production traffic through development.
- `dev.sh lan on|off|status` and `dev.ps1 lan on|off|status` control only this
  project's ingress. LAN defaults on for running projects on trusted networks;
  remember explicit global/per-project off choices. Tunnel state is independent. Revoking access
  must also close existing relay connections. Never share application ports.
- The monitor's Infrastructure LAN button controls running checkouts in its workspace;
  each project's LAN button controls only that project. Red/green reflects actual
  sharing, not the saved preference. Startup defaults never bypass network trust
  checks or repeatedly request elevation after a failure. An explicit Windows
  LAN toggle may start a Public-network session using --allow-public: retain
  the Public profile, bind only the selected interface/address, scope firewall
  rules to that interface's exact subnet and the Python listener, and expose
  only project HTTPS. Never change the Windows network category or
  enable Public sharing from remembered/startup preferences. Pin the session
  to interface, profile, prefix and gateway; revoke on network change.
  Controls are handled inside the terminal: Tab/arrows select, Space/Enter toggle,
  Ctrl+C exits, and VT mouse clicks activate the displayed hit regions. The
  Infrastructure button is the master control; do not bind letter keys L or Q. Keep
  keyboard control available when a terminal has no mouse support. Restore terminal
  modes on exit and keep slow rendering separate from responsive input handling.
  The native host controller uses authenticated file IPC in the private monitor
  directory; never emit LAN browser links or accept arbitrary commands/paths.
  Serialize changes across monitors, fail closed on enable errors, and retain
  Windows trust/firewall checks. Windows LAN commands reuse the already-running
  WSL workspace; never bootstrap or spawn source copiers for a toggle. Capture
  launcher output in files so inherited background handles cannot hang completion.
  On Unix, foreground password prompts must occur
  outside raw input mode; background workers must never read terminal passwords.
- Ordinary development defaults to local TLS and works without an owned domain
  or DNS credentials. Reuse the existing computer-only mkcert/Traefik setup.
  `dev.sh lan setup` / `dev.ps1 lan setup` enrolls a private host DNS credential
  once and marks the selected project public only after its zone is validated.
  `DEV_TLS_MODE=public` uses public DNS and ACME DNS-01. Local mode never claims
  profile-free phone access. Never require phone profiles, mDNS, certificate
  warning bypasses, or silently substitute a local certificate in public mode.
  Keep the Cloudflare DNS credential outside Git in the private host credential
  file. Scope Zone Read and DNS Edit to authorized domains; new domains require
  matching authorization. Only update exact owned dev A records, never production
  records, foreign records, wildcard records, or unimplemented IPv6 records.
  Keep ACME state in a durable private volume with one shared Traefik writer.
  Every public TLS router must explicitly use the dev certificate resolver. Verify the
  public certificate chain and hostname before reporting public HTTPS/LAN ready.
  Windows startup verifies the owned helper readiness marker and bound HTTPS
  socket before reusing its PID. Turning LAN off revokes routes/connections
  immediately without waiting for DNS TTLs. Remove obsolete mDNS and profile
  bootstrap firewall rules during migration. Do not disable Wi-Fi client
  isolation or router DNS rebinding protection; report such network limitations.
  Use host-only, distinct development session/CSRF cookies so production cookies
  on a parent domain cannot be mistaken for development authentication.
  On a new computer, repeat host credential enrollment; keep tokens out of Git,
  preserve the same development URLs, and revoke retired computer tokens.
  Local-only projects must stay runnable without internet or a Cloudflare token.

## Backup and recovery

- Shared portable exports live in `backend/config/backups.py`. Use the project's
  configured Django storage rather than assuming uploaded files are on disk.
- `dev.sh backup [full|db|index|media]` creates verified archives in
  `backend/backup/`; it must never delete or automatically replace startup seeds.
  `index` means the complete database, including metadata; it excludes media.
- Uploads are explicit: `dev.sh backup --upload` creates and publishes, while
  `dev.sh backup upload [ARCHIVE]` publishes an existing snapshot. Only encrypted
  archives and checksums go into `snapshots/local` on `production-backups`;
  Railway exports remain in `snapshots/`. Use the checkout's GitHub origin and
  existing CLI login, never another project's settings or deployment branch.
- `dev.sh backup download [local|production]` downloads, checks and decrypts a
  recovery copy using the private identity outside Git. Downloaded local archives
  remain ignored. Download/upload never replaces startup seeds or live data;
  restore explicitly into empty destinations using `dev.sh backup restore`.
- `dev.sh backup restore [production|local]` explicitly refreshes development:
  pause this project's application services, preserve a local snapshot, restore
  into a fresh database, compare COPY row counts, apply migrations, then swap
  database names transactionally and retain previous media in backup storage.
  Retain the previous database and recovery journal; never drop it automatically.
  This operation refuses production mode, remote databases and cloud media.
- Profile-gated tools are not always-running monitor services, including tools
  that inherit profiles through Compose YAML anchors.
- Restore only trusted archives into empty database/media destinations. Preserve
  legacy SQL/tar startup seeds, but fail on SQL errors rather than accepting a
  partial restore. Existing user tables prevent automatic startup replay.
- Production backups are encrypted with `age` before leaving the recovery host.
  Keep private identities outside Git and deployment variables; only configure
  the public recipient on exporters. Keep a second independent identity copy.
- Backups are manual checkpoints and data-transfer tools. Do not add scheduled
  exports, backup services, or GitHub Actions backup jobs. Use `dev.sh backup`
  locally and upload only when explicitly requested. Preserve the live databases
  and existing encrypted archives; removing automation never removes user data.
  Seven uploaded archives remain visible; Git history retains older encrypted
  copies and grows. Uploads over 90 MiB require independent object storage.
- `BACKUP_DESTINATION_STORAGE` accepts a Django storage backend/options JSON
  (S3, GCS or another installed adapter); `BACKUP_DESTINATION_PREFIX` isolates each
  project. `BACKUP_COPY_DIRECTORY` adds a verified copy to a mounted personal or
  external drive. S3-only exporters may alternatively use `BACKUP_S3_*` options.
  Backup destination credentials are separate from production media credentials.
- Example recovery: `age -d -i <identity-file> -o snapshot.tar.gz <archive.age>`,
  `python -m config.backups verify snapshot.tar.gz`, then
  `python -m config.backups restore snapshot.tar.gz` in the target backend and run
  project migrations. Use PostgreSQL 18 or newer for the current GitHub exports;
  custom exporters require compatible client/server versions. Never point a
  recovery drill at the live production database.
- PostgreSQL exports are transactionally consistent; database and object storage
  do not share a transaction. Pause uploads/deletes for an exact recovery boundary.
  Redis queues/caches and external integrations are not included in these exports.
  Drill restores periodically; a successfully uploaded file alone is insufficient.

## Interface translation

- The template's `frontend/web/localization/` compiler and root provider cover
  authored JSX text and native accessibility/placeholder labels on all web routes.
  Preserve these generic files and the `/ui-localization` endpoint during sync.
- Keep `frontend/web/messages/automatic-source.json` project-owned. Never copy
  interface catalogs, manual language preferences or source phrases between apps.
- Root layouts await `getInitialLocalization()` and pass its snapshot to the client
  provider. Generate project-owned `messages/automatic/*.json` before production
  builds; never replace first-render localization with post-mount translation.
- Keep existing manual selectors and reviewed dictionaries. Pass their selected
  language and reviewed messages to `AutomaticTranslationProvider`; projects
  without a selector follow device language automatically.
- Public data-driven labels render through `AutoText`. Declare public JSON UI
  registries in the project's `package.json` `localization.catalogs`; new registry
  entries are then discovered automatically. Keep brands in `localization.preserve`.
- Preserve names, passwords, addresses, documents, messages and editable content.
  Do not register private data as a translation source or send it to providers.
  Use `translate="no"` or `data-no-translate` for original-content containers.
- Canvas/imperative text, SEO metadata and dynamic backend prose require explicit
  application localization; do not claim that the JSX compiler covers them.
- Run `node --test localization/tests.cjs` and project translation tests from
  `frontend/web` after changing this layer. Verify production builds because the
  shared webpack loader participates in both server and client compilation.

## Dependency maintenance

- Vercel publishes `main` through its native Git integration, independently of
  GitHub Actions billing availability. The shared `frontend/web/vercel.json`
  runs routing tests before the production build; localization coverage remains
  enforced by that build. Keep the Vercel Actions workflow manual-only to avoid
  duplicate deployments. Backup branches carry a disabled-deployment guard in
  the configured web root and must never deploy encrypted recovery archives.

- The template owns core backend requirements and the frontend framework/tool
  versions. Template sync merges these versions into project manifests while
  retaining project packages, identity, routes, environment files and custom
  commands. Regenerate the project's web lockfile with `npm install` after a
  manual sync; lockfiles are never copied across different projects.
- Dependabot checks npm, Python, container images and Actions weekly. Major
  upgrades are separate pull requests. Prefer the latest compatible patched
  versions and supported runtimes; do not override peer dependency conflicts.
- Shared maintenance workflows are manual-only: no schedules, push/PR triggers,
  or chained workflow triggers that consume hosted runner time automatically.
  Use local checks and `dev.sh sync` by default. Vercel and Railway retain native
  Git deployments; Vercel's build keeps its validation gates. A manually requested
  hosted workflow still depends on the owner's GitHub runner allowance.
- Local sync ignores LF/CRLF-only differences and locks each destination checkout
  during writes. Application edits do not block shared sync; conflicting unpublished
  shared edits do. Commit and review those changes, then offer them to the template
  with `sync push` before pulling. Never force-push the default branch to bypass a
  concurrent remote update; fetch and integrate it while preserving local work.
- Configure `TEMPLATE_SYNC_SSH_KEY` as a unique write-enabled deploy key for
  each receiving repository, with its private key stored only in that repository's
  Actions secret. The key publishes template branches, including shared workflows;
  the built-in GitHub token opens PRs and explicitly dispatches their checks.
  Enable Actions permission to create pull requests. For a private template,
  set `TEMPLATE_READ_TOKEN` with read access. Never store credentials in source
  or the root environment file. The template itself skips self-sync.
- Direct pushes to the default branch are allowed by the workspace owner.
  Keep Dependency checks available on explicit request, but do not configure required
  status checks or PR-only protection unless the owner explicitly requests it.
  Explicit dependency/template PR merges still require successful `frontend`
  and `backend` jobs on the current PR commit.
  Checks cover a clean npm install, lint, TypeScript, production build, Python
  dependency consistency, Django system checks and shared dependency-sync tests.
  Run each project's application regression suite before major framework updates;
  shared checks do not establish full application coverage.
- To enable checked automatic merging, set repository variable
  `DEPENDENCY_AUTO_MERGE=true` and enable squash merging. The workflow enforces
  successful `frontend` and `backend` jobs on the current PR commit and requires
  the current default branch to be included before merging. This also works on
  private repositories whose plan does not support branch protection. It only
  accepts successful checks on the exact current PR commit. Dependency major
  releases and backend/runtime updates still require review; template-sync PRs
  can merge after the receiving project's checks pass. It never runs PR code
  with write permissions. A manually requested merge sweep also picks up bot-created
  template PRs whose checks were explicitly dispatched; it verifies the same
  current-commit checks and base ancestry. Without this setup, update PRs remain
  for review.
- Audio/ML dependency restructuring is deferred. Keep its current requirements,
  compatibility constraints and worker layout intact.

## Interface localization

- New web UI must render through the shared localization compiler/provider.
  Ordinary JSX copy and supported local helper labels are discovered automatically.
  For custom widgets, imported registries or opaque data-driven UI labels, integrate
  `AutoText` or `useInterfaceTranslator` explicitly and register authored phrases
  or declare an interface catalog. Do not leave original-language helper text as
  an implicit fallback or add DOM mutation/browser-translation workarounds.
- Keep interpolation values separate from authored messages. Never translate or
  send user-entered text, personal values, stored content, credentials or private
  backend data to a translation provider. Preserve technical IDs, option values,
  routes and existing automatic/manual language preferences.
- After changing authored UI copy, run `node localization/prepare.cjs --translations`
  and `node localization/prepare.cjs --check` from `frontend/web`. Commit this
  project's generated source manifest and locale dictionaries with the feature.
  Do not copy another project's dictionaries. CI and production builds enforce
  complete coverage; report generation failures rather than weakening the gate.
