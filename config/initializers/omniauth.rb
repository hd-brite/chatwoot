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
    provider :openid_connect,
             name: :openid_connect,
             scope: %i[openid email profile],
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
