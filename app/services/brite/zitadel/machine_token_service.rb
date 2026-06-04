# BO-1696: Fetches a Brite (Zitadel) access token for the brite-chatwoot
# machine user using the OAuth2 JWT-bearer / "service user" flow. The signed
# assertion is built from a Zitadel KEY_TYPE_JSON machine key (provisioned in
# the brite-chatwoot service account- see the zitadel terraform). The returned
# token carries the d:u:r role on the Brite project and is used as a Bearer
# token against the dealers REST API.
#
# Mirrors libs/go-modules/authentication/zitadelauth in the brite monorepo:
# same assertion claims, token endpoint, and reserved project-audience scope.
class Brite::Zitadel::MachineTokenService
  class ConfigurationError < StandardError; end
  class TokenError < StandardError; end

  TOKEN_PATH = '/oauth/v2/token'.freeze
  GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer'.freeze
  # Assertion lifetime. Short-lived- it is only used to mint the access token.
  ASSERTION_TTL = 60 * 60
  CACHE_KEY = 'brite:zitadel:machine_token'.freeze
  # Refresh a little before the real expiry to avoid handing out a token that
  # expires mid-request.
  EXPIRY_SKEW = 60
  REQUEST_TIMEOUT = 10

  def initialize(issuer_url: nil, project_id: nil, machine_key_json: nil)
    @issuer_url = (issuer_url || ENV.fetch('BRITE_ZITADEL_ISSUER_URL', nil).presence || ENV.fetch('OIDC_ISSUER_URL', nil)).to_s.chomp('/')
    @project_id = project_id || ENV.fetch('BRITE_ZITADEL_PROJECT_ID', nil)
    @machine_key_json = machine_key_json || ENV.fetch('BRITE_ZITADEL_MACHINE_KEY', nil)
  end

  def token
    cached = Rails.cache.read(CACHE_KEY)
    return cached if cached.present?

    access_token, expires_in = fetch_token
    Rails.cache.write(CACHE_KEY, access_token, expires_in: cache_ttl(expires_in))
    access_token
  end

  private

  def fetch_token
    validate_config!

    response = HTTParty.post(
      "#{@issuer_url}#{TOKEN_PATH}",
      body: token_request_body,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
      timeout: REQUEST_TIMEOUT
    )

    raise TokenError, "Zitadel token request failed: #{response.code} #{response.body}" unless response.success?

    parsed = response.parsed_response
    access_token = parsed.is_a?(Hash) ? parsed['access_token'] : nil
    raise TokenError, "Zitadel token response missing access_token: #{response.body}" if access_token.blank?

    [access_token, (parsed['expires_in'] if parsed.is_a?(Hash))]
  end

  def token_request_body
    {
      grant_type: GRANT_TYPE,
      assertion: assertion,
      scope: scopes
    }
  end

  # Scopes mirror the Go zitadelauth client: request role assertion plus the
  # reserved Brite project audience so the issued access token both carries
  # d:u:r and is scoped to the Brite project.
  def scopes
    [
      'openid',
      'profile',
      'roles',
      'urn:zitadel:iam:org:projects:roles',
      'urn:zitadel:iam:org:project:id:zitadel:aud',
      "urn:zitadel:iam:org:project:id:#{@project_id}:aud"
    ].join(' ')
  end

  def assertion
    now = Time.now.to_i
    claims = {
      iss: key_data['userId'],
      sub: key_data['userId'],
      aud: @issuer_url,
      iat: now,
      exp: now + ASSERTION_TTL,
      jti: SecureRandom.uuid
    }

    JWT.encode(claims, private_key, 'RS256', { kid: key_data['keyId'] })
  end

  def private_key
    OpenSSL::PKey::RSA.new(key_data['key'])
  rescue OpenSSL::PKey::RSAError => e
    raise ConfigurationError, "BRITE_ZITADEL_MACHINE_KEY contains an invalid RSA key: #{e.message}"
  end

  def key_data
    @key_data ||= JSON.parse(@machine_key_json)
  rescue JSON::ParserError => e
    raise ConfigurationError, "BRITE_ZITADEL_MACHINE_KEY is not valid JSON: #{e.message}"
  end

  def cache_ttl(expires_in)
    ttl = expires_in.to_i - EXPIRY_SKEW
    ttl.positive? ? ttl : EXPIRY_SKEW
  end

  def validate_config!
    raise ConfigurationError, 'Zitadel issuer URL is not configured (BRITE_ZITADEL_ISSUER_URL/OIDC_ISSUER_URL)' if @issuer_url.blank?
    raise ConfigurationError, 'BRITE_ZITADEL_PROJECT_ID is not configured' if @project_id.blank?
    raise ConfigurationError, 'BRITE_ZITADEL_MACHINE_KEY is not configured' if @machine_key_json.blank?
  end
end
