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

## Put project-specific behavior in its existing home

- Use `backend/project.py` for settings overrides, extra installed apps, custom
  URL prefixes, integration configuration, optional `COMPOSE_SERVICES`, mobile
  ordering and metadata, and additional `SYNC_PROJECT_PATHS`.
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
