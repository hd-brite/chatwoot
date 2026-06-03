# OmniAuth configuration
# Sets the full host URL for callbacks and proper redirect handling
OmniAuth.config.full_host = ENV.fetch('FRONTEND_URL', 'http://localhost:3000')

# Allow GET requests for SSO initiation - the Vue SPA cannot send POST
# requests with CSRF tokens via anchor tags. The OIDC flow's own `state`
# parameter provides equivalent CSRF protection.
OmniAuth.config.allowed_request_methods = %i[get post]

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, ENV.fetch('GOOGLE_OAUTH_CLIENT_ID', nil), ENV.fetch('GOOGLE_OAUTH_CLIENT_SECRET', nil), {
    provider_ignores_state: true
  }

  if ENV['OIDC_ISSUER_URL'].present?
    # The brite-chatwoot Zitadel app lives in its own project, so the user's
    # argocd-* grants (on the separate "Brite Third Party Tools" project) are
    # NOT in the default token audience and the super-admin mapping never sees
    # them. Adding that project to the audience via Zitadel's reserved
    # `urn:zitadel:iam:org:project:id:{id}:aud` scope makes Zitadel assert its
    # roles under the `urn:zitadel:iam:org:project:roles` claim, which
    # OmniauthCallbacksController#extract_oidc_role_keys reads. Driven by env so
    # non-Brite/local setups are unaffected.
    oidc_scope = %i[openid email profile]
    tpt_project_id = ENV['OIDC_TPT_PROJECT_ID'].presence
    oidc_scope << "urn:zitadel:iam:org:project:id:#{tpt_project_id}:aud" if tpt_project_id

    provider :openid_connect,
             name: :openid_connect,
             scope: oidc_scope,
             response_type: :code,
             issuer: ENV['OIDC_ISSUER_URL'],
             discovery: true,
             client_options: {
               identifier: ENV.fetch('OIDC_CLIENT_ID', nil),
               secret: ENV.fetch('OIDC_CLIENT_SECRET', nil),
               redirect_uri: "#{ENV.fetch('FRONTEND_URL', 'http://localhost:3000')}/omniauth/openid_connect/callback"
             }
  end
end
