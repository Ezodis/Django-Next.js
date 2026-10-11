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
  The sole local web origin is `https://<repository-name>.localhost`, preserving
  dots and hyphens. Do not add compact spelling aliases or publish frontend/API
  host ports. Keep simulator bridges and Metro ports limited to their tooling.
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

## Backup and recovery

- Shared portable exports live in `backend/config/backups.py`. Use the project's
  configured Django storage rather than assuming uploaded files are on disk.
- `dev.sh backup [full|db|index|media]` creates verified archives in
  `backend/backup/`; it must never delete or automatically replace startup seeds.
  `index` means the complete database, including metadata; it excludes media.
- Restore only trusted archives into empty database/media destinations. Preserve
  legacy SQL/tar startup seeds, but fail on SQL errors rather than accepting a
  partial restore. Existing user tables prevent automatic startup replay.
- Production backups are encrypted with `age` before leaving the recovery host.
  Keep private identities outside Git and deployment variables; only configure
  the public recipient on exporters. Keep a second independent identity copy.
- The optional daily `production-backup.yml` workflow writes to the separate
  `production-backups` branch. Enable with `PRODUCTION_BACKUP_ENABLED`, the public
  `BACKUP_AGE_RECIPIENT` variable, and `PRODUCTION_BACKUP_ENV` Actions secret
  containing `DATABASE_URL`, project identity and `BACKUP_SOURCE_STORAGE` JSON.
  Treat its database/storage credentials as secrets with minimum permissions.
  Seven archives remain visible; Git history retains older encrypted copies and
  grows. The workflow refuses archives over 90 MiB; use object storage for growth.
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

- The template owns core backend requirements and the frontend framework/tool
  versions. Template sync merges these versions into project manifests while
  retaining project packages, identity, routes, environment files and custom
  commands. Regenerate the project's web lockfile with `npm install` after a
  manual sync; lockfiles are never copied across different projects.
- Dependabot checks npm, Python, container images and Actions weekly. Major
  upgrades are separate pull requests. Prefer the latest compatible patched
  versions and supported runtimes; do not override peer dependency conflicts.
- `.github/workflows/template-sync.yml` checks after default-branch pushes and
  hourly for shared updates, opening a project pull request from
  the configured `SYNC_TEMPLATE_REPO`. This activates after these files are
  committed and pushed to each repository's default branch.
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
  Keep Dependency checks running after pushes, but do not configure required
  status checks or PR-only protection unless the owner explicitly requests it.
  Automatic dependency/template PR merges still require successful `frontend`
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
  with write permissions. A scheduled merge sweep also picks up bot-created
  template PRs whose checks were explicitly dispatched; it verifies the same
  current-commit checks and base ancestry. Without this setup, update PRs remain
  for review.
- Audio/ML dependency restructuring is deferred. Keep its current requirements,
  compatibility constraints and worker layout intact.
