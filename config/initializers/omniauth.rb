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
    # The brite-chatwoot Zitadel app lives in its own project, so a user's
    # argocd-* grants (on the separate "Brite Third Party Tools" project) are
    # NOT asserted in the default token and the super-admin mapping never sees
    # them. Per Zitadel's cross-project role model surfacing them requires BOTH
    # scopes below: the reserved `urn:zitadel:iam:org:project:id:{id}:aud` scope
    # adds that project to the token audience, and `urn:zitadel:iam:org:projects:roles`
    # requests the roles for every audience project. Zitadel then asserts the
    # grant under the project-id-specific claim `urn:zitadel:iam:org:project:{id}:roles`,
    # which OmniauthCallbacksController#extract_oidc_role_keys reads. The audience
    # scope alone is NOT sufficient. Driven by env so non-Brite/local setups are
    # unaffected.
    oidc_scope = %i[openid email profile]
    # BO-1696: request the user's Zitadel metadata so the dealer_user_id claim
    # (urn:zitadel:iam:user:metadata) is present in the token. The callback
    # controller reads it to resolve the user's top-level dealer for account
    # assignment and to gate non-super-admin logins.
    oidc_scope << 'urn:zitadel:iam:user:metadata'
    tpt_project_id = ENV['OIDC_TPT_PROJECT_ID'].presence
    if tpt_project_id
      oidc_scope << "urn:zitadel:iam:org:project:id:#{tpt_project_id}:aud"
      oidc_scope << 'urn:zitadel:iam:org:projects:roles'
    end

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
