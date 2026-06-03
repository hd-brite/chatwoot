# Brite fork developer guide

This repository is Brite's fork of [`chatwoot/chatwoot`](https://github.com/chatwoot/chatwoot). It tracks upstream Chatwoot **Community Edition** and adds a small set of Brite-specific customizations (mainly Zitadel OIDC SSO). The image built from this fork is deployed to AKS by the [`hd-brite/brite`](https://github.com/hd-brite/brite) monorepo (`tools/chatwoot/`).

- **Brite branch:** `master` (the image-publish workflow builds from here). `develop` is upstream's leftover default branch and is **not** what we deploy.
- **Deployed at:** `chat.dev.hdbrite.com` (dev) and `chat.hdbrite.com` (prod).
- **Base version:** upstream `v4.14.0`. Brite images are tagged `v4.14.0-brite.N`.

If you only need to *run* the deployed implementation locally (not edit the app), use the prebuilt-image compose in the monorepo instead: `tools/chatwoot/docker-compose.yml` (see its README). Use **this** repo when you need to change the Chatwoot app itself.

## What this fork customizes

All Brite changes are env-gated so the fork stays a clean superset of upstream CE (no behavior change when the env vars are unset).

1. **Zitadel OIDC SSO** (`config/initializers/omniauth.rb`) - registers an `openid_connect` OmniAuth provider when `OIDC_ISSUER_URL` is set, bypassing the enterprise SAML gate. Allows `GET` for SSO initiation because the Vue SPA links out via anchor tags (the OIDC `state` param provides CSRF protection).
2. **Auto-provision + super-admin mapping** (`app/controllers/devise_overrides/omniauth_callbacks_controller.rb`) - when `OIDC_AUTO_PROVISION=true`, first-time OIDC users are added to the first account (agent, or administrator if admin). Users whose Zitadel role claims contain any `argocd-*` role are promoted to Chatwoot **SuperAdmin**; role sync runs on every login. Role keys are read from both the flat `groups` claim and the `urn:zitadel:iam:org:project:roles` claim, and are stashed during the `devise_token_auth` redirect bounce (which otherwise strips `extra.raw_info`).
3. **Redis-backed session store in production** (`config/initializers/session_store.rb`) - the OIDC callback stashes the auth payload (incl. `id_token`) in the session; with the default cookie store that blows past the ~4KB cookie / nginx proxy header buffer and returns a 502. Deployed envs (`RAILS_ENV=production`) use a Redis cache session store; local/test keep the cookie store (no hard Redis dependency).

## Local development (source-editable)

The standard upstream Docker dev loop works as-is: Rails + Vite (hot reload) + Sidekiq + Postgres + Redis + Mailhog, with your working tree bind-mounted into the containers.

```bash
cp .env.example .env          # set SECRET_KEY_BASE, POSTGRES_PASSWORD, REDIS_PASSWORD
docker compose build          # first run only (or after Gemfile/package.json changes)
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up
```

Then open:

- App: <http://localhost:3000>
- Vite dev server: <http://localhost:3036>
- Mailhog (captured email): <http://localhost:8025>

Edits to Ruby and JS are picked up live (Rails reloader + Vite HMR). The `Makefile` wraps common tasks (`make db_reset`, `make console`, `make burn` to rebuild from scratch, etc.).

> Note: `docker-compose.yaml` runs `RAILS_ENV=development`, which keeps the **cookie** session store. The Redis session store only engages in `production`, so to reproduce the SSO 502 / Redis-session behavior locally you must run with `RAILS_ENV=production` (see below).

## Testing the Brite OIDC SSO flow locally

OIDC is off unless `OIDC_ISSUER_URL` is set. To exercise it against Zitadel:

1. In Zitadel, register (or reuse) a `brite-chatwoot` OIDC application (Authorization Code, with secret) and add this redirect URI:

   ```
   http://localhost:3000/omniauth/openid_connect/callback
   ```

2. Add the Brite env vars to your `.env`:

   ```bash
   # --- Brite OIDC SSO ---
   OIDC_ISSUER_URL=https://auth.dev.hdbrite.com   # presence enables OIDC
   OIDC_CLIENT_ID=<from Zitadel>
   OIDC_CLIENT_SECRET=<from Zitadel>
   OIDC_DISPLAY_NAME=Sign in with Brite SSO       # login button label
   OIDC_AUTO_PROVISION=true                        # create users on first login
   # Add the "Brite Third Party Tools" Zitadel project to the token audience so
   # the argocd-* role grants are asserted in the roles claim (super-admin map).
   OIDC_TPT_PROJECT_ID=<zitadel third-party-tools project id>
   OIDC_LOG_ROLES=true                             # log resolved role keys (debug)
   # REDIS_SESSION_POOL_SIZE=5                      # only used in production session store
   ```

3. Run with `RAILS_ENV=production` to exercise the Redis-backed session store (the path that previously 502'd):

   ```bash
   RAILS_ENV=production docker compose up
   ```

   (For a quick OIDC smoke test without the Redis-session behavior, the default `development` run is fine - the "Sign in with Brite SSO" button still appears once `OIDC_ISSUER_URL` is set.)

4. Click **Sign in with Brite SSO**. A user with an `argocd-*` grant should land as a SuperAdmin (`/super_admin`); check `OIDC_LOG_ROLES` output if the mapping does not fire.

### Brite OIDC env vars

| Var | Purpose |
| --- | --- |
| `OIDC_ISSUER_URL` | OIDC issuer; **presence enables** the provider |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | Zitadel client credentials |
| `OIDC_DISPLAY_NAME` | Label on the SSO login button |
| `OIDC_AUTO_PROVISION` | `true` to create users on first login |
| `OIDC_TPT_PROJECT_ID` | Zitadel "Brite Third Party Tools" project id, added to the token audience so `argocd-*` roles appear in the roles claim |
| `OIDC_LOG_ROLES` | `true` to log resolved role keys (debug super-admin mapping) |
| `REDIS_SESSION_POOL_SIZE` | Redis connection pool size for the production session store (default `5`) |

Relevant specs: `spec/controllers/devise/omniauth_callbacks_controller_spec.rb` (super-admin promotion/demotion + auto-provision through the redirect bounce).

## How the image is built and published

The Brite image is built by `.github/workflows/publish_brite_docker.yml`:

- Strips the `enterprise/` code and sets `CW_EDITION=ce`, then builds `docker/Dockerfile` for `linux/amd64`.
- Pushes the **same tag** to both registries:
  - `briteregistrydevelopment.azurecr.io/hd-brite/chatwoot`
  - `briteregistryproduction.azurecr.io/hd-brite/chatwoot`
- **Triggers:** push to `master` (tag `v4.14.0-brite.dev-<shortsha>`), tags matching `v*-brite.*` (uses the tag name), or manual `workflow_dispatch`.
- Requires GitHub secrets `ACR_DEV_USERNAME`, `ACR_DEV_PASSWORD`, `ACR_PROD_USERNAME`, `ACR_PROD_PASSWORD`.

The monorepo chart (`tools/chatwoot/iac/argocd/app-chart/values-common.yaml`) pins a `v4.14.0-brite.N` tag with `pullPolicy: Always` (the tag is mutable and re-pushed on each `master` merge).

### Cutting a new `-brite.N` release

1. Merge your change into `master` (the push build publishes a `…-brite.dev-<sha>` image you can test in dev).
2. Tag the release and push the tag:

   ```bash
   git tag v4.14.0-brite.2
   git push origin v4.14.0-brite.2
   ```

   The workflow builds and pushes `…:v4.14.0-brite.2` to both ACRs.
3. Bump the tag in the monorepo chart (`tools/chatwoot/iac/argocd/app-chart/values-common.yaml`) and let ArgoCD roll it out.

> When rebasing onto a newer upstream Chatwoot, bump the base version in the tag scheme accordingly (e.g. `v4.15.0-brite.1`).
