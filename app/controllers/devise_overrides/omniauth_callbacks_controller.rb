class DeviseOverrides::OmniauthCallbacksController < DeviseTokenAuth::OmniauthCallbacksController
  include EmailHelper

  def omniauth_success
    get_resource_from_auth_hash

    return redirect_to login_page_url(error: 'no-dealer-access') if oidc_provider? && oidc_login_blocked?

    if @resource.present?
      sync_super_admin_from_oidc if oidc_provider?
      sign_in_user
    elsif oidc_provider? && oidc_auto_provision_enabled?
      auto_provision_oidc_user
    else
      sign_up_user
    end
  end

  # /omniauth/:provider/callback. devise_token_auth's redirect_callbacks stashes
  # the auth hash into the session WITHOUT the `extra` section (it strips it to
  # avoid CookieOverflow) and 307-redirects to /auth/:provider/callback. Since
  # the OIDC role/group claims live in `extra.raw_info`, they never reach
  # omniauth_success. Capture them here, while `extra` is still present, so the
  # super-admin mapping has something to work with.
  def redirect_callbacks
    stash_oidc_role_keys
    stash_oidc_dealer_user_id
    super
  end

  private

  def sign_in_user
    # Capture before skip_confirmation! sets confirmed_at, which would
    # make oauth_user_needs_password_reset? return false and skip the
    # password reset for persisted unconfirmed users.
    needs_password_reset = oauth_user_needs_password_reset?
    @resource.skip_confirmation! if confirmable_enabled?
    set_random_password_if_oauth_user if needs_password_reset

    # once the resource is found and verified
    # we can just send them to the login page again with the SSO params
    # that will log them in
    encoded_email = ERB::Util.url_encode(@resource.email)
    redirect_to login_page_url(email: encoded_email, sso_auth_token: @resource.generate_sso_auth_token)
  end

  def sign_in_user_on_mobile
    # See comment in sign_in_user for why this is captured before skip_confirmation!
    needs_password_reset = oauth_user_needs_password_reset?
    @resource.skip_confirmation! if confirmable_enabled?
    set_random_password_if_oauth_user if needs_password_reset

    # once the resource is found and verified
    # we can just send them to the login page again with the SSO params
    # that will log them in
    encoded_email = ERB::Util.url_encode(@resource.email)
    params = { email: encoded_email, sso_auth_token: @resource.generate_sso_auth_token }.to_query

    mobile_deep_link_base = GlobalConfigService.load('MOBILE_DEEP_LINK_BASE', 'chatwootapp')
    redirect_to "#{mobile_deep_link_base}://auth/saml?#{params}", allow_other_host: true
  end

  def sign_up_user
    return redirect_to login_page_url(error: 'no-account-found') unless account_signup_allowed?
    return redirect_to login_page_url(error: 'business-account-only') unless validate_signup_email_is_business_domain?

    create_account_for_user
    set_random_password_if_oauth_user
    token = @resource.send(:set_reset_password_token)
    frontend_url = ENV.fetch('FRONTEND_URL', nil)
    redirect_to "#{frontend_url}/app/auth/password/edit?config=default&reset_password_token=#{token}"
  end

  def login_page_url(error: nil, email: nil, sso_auth_token: nil)
    frontend_url = ENV.fetch('FRONTEND_URL', nil)
    params = { email: email, sso_auth_token: sso_auth_token }.compact
    params[:error] = error if error.present?

    "#{frontend_url}/app/login?#{params.to_query}"
  end

  def account_signup_allowed?
    GlobalConfigService.account_signup_enabled?
  end

  def resource_class(_mapping = nil)
    User
  end

  def get_resource_from_auth_hash # rubocop:disable Naming/AccessorMethodName
    email = auth_hash.dig('info', 'email')
    @resource = resource_class.from_email(email)
  end

  def validate_signup_email_is_business_domain?
    # return true if the user is a business account, false if it is a blocked domain account
    Account::SignUpEmailValidationService.new(auth_hash['info']['email']).perform
  rescue CustomExceptions::Account::InvalidEmail
    false
  end

  def create_account_for_user
    @resource, @account = AccountBuilder.new(
      account_name: extract_domain_without_tld(auth_hash['info']['email']),
      user_full_name: auth_hash['info']['name'],
      email: auth_hash['info']['email'],
      locale: I18n.locale,
      confirmed: auth_hash['info']['email_verified']
    ).perform
    Avatar::AvatarFromUrlJob.perform_later(@resource, auth_hash['info']['image'])
  end

  def oauth_user_needs_password_reset?
    @resource.present? && (@resource.new_record? || !@resource.confirmed?)
  end

  def set_random_password_if_oauth_user
    # Password must satisfy secure_password requirements (uppercase, lowercase, number, special char)
    @resource.update(password: "#{SecureRandom.hex(16)}aA1!") if @resource.persisted?
  end

  def oidc_provider?
    # OmniAuth registers the strategy with `name: :openid_connect`, so the auth
    # hash carries the provider as the Symbol `:openid_connect`. Hashie::Mash
    # stringifies keys but leaves symbol values intact, so compare via `to_s`.
    auth_hash['provider'].to_s == 'openid_connect'
  end

  def oidc_auto_provision_enabled?
    ENV['OIDC_AUTO_PROVISION'] == 'true'
  end

  def auto_provision_oidc_user
    is_admin = oidc_user_is_admin?
    account = resolve_oidc_account(is_admin)
    return redirect_to login_page_url(error: 'no-account-found') if account.nil?

    @resource = build_oidc_user(is_admin)
    AccountUser.create!(account_id: account.id, user_id: @resource.id, role: is_admin ? :administrator : :agent)

    encoded_email = ERB::Util.url_encode(@resource.email)
    redirect_to login_page_url(email: encoded_email, sso_auth_token: @resource.generate_sso_auth_token)
  end

  # BO-1696: With the Brite dealer integration enabled, a provisioned OIDC user
  # is assigned to the Account named after their top-level dealer (resolved from
  # the dealers API by the dealer_user_id in their Zitadel metadata). With the
  # integration disabled (no API base URL), everyone lands on the first account-
  # the upstream behaviour- so local/non-Brite setups are unaffected.
  def resolve_oidc_account(is_admin)
    return Account.first unless brite_dealer_integration_enabled?

    Brite::Dealers::AccountAssignmentService.new(dealer_user_id: oidc_dealer_user_id, is_admin: is_admin).perform
  end

  def build_oidc_user(is_admin)
    user = User.new(
      email: auth_hash['info']['email'],
      name: auth_hash['info']['name'] || auth_hash['info']['email'].split('@').first,
      password: "#{SecureRandom.hex(16)}aA1!"
    )
    user.confirm
    user.type = 'SuperAdmin' if is_admin
    user.save!
    user
  end

  def sync_super_admin_from_oidc
    should_be_admin = oidc_user_is_admin?
    is_admin = @resource.type == 'SuperAdmin'
    return if should_be_admin == is_admin

    @resource.update!(type: should_be_admin ? 'SuperAdmin' : 'User')
  end

  def oidc_user_is_admin?
    oidc_user_role_keys.any? { |key| key.start_with?('argocd-') }
  end

  # BO-1696: When the Brite dealer integration is enabled, an OIDC user must
  # either be a super admin (argocd-*) or carry a dealer_user_id in their
  # Zitadel metadata. Everyone else is blocked from logging in. The integration
  # is off (and this gate is a no-op) unless the dealers API base URL is set, so
  # local/non-Brite setups are unaffected.
  def oidc_login_blocked?
    return false unless brite_dealer_integration_enabled?
    return false if oidc_user_is_admin?

    oidc_dealer_user_id.blank?
  end

  def brite_dealer_integration_enabled?
    ENV['BRITE_DEALERS_API_BASE_URL'].present?
  end

  # Roles are stashed by redirect_callbacks (before `extra` is stripped) and
  # read back here in omniauth_success after the redirect bounce.
  def oidc_user_role_keys
    keys = Array(session['oidc.role_keys']).map(&:to_s)
    Rails.logger.info("[oidc] resolved role keys: #{keys.inspect}") if ENV['OIDC_LOG_ROLES'] == 'true'
    keys
  end

  def stash_oidc_role_keys
    auth = request.env['omniauth.auth']
    # Match the Symbol-or-String provider value (see oidc_provider?).
    return unless auth.present? && auth['provider'].to_s == 'openid_connect'

    session['oidc.role_keys'] = extract_oidc_role_keys(auth['extra'])
  rescue StandardError => e
    Rails.logger.error("[oidc] failed to stash role keys: #{e.class}: #{e.message}")
  end

  # Brite's Zitadel emits a user's granted roles as a flat `groups` claim (see
  # the AddGroupsClaim action in the zitadel terraform) - the same claim ArgoCD
  # consumes. Zitadel also asserts them under project roles claims: the generic
  # `urn:zitadel:iam:org:project:roles` for the app's own project, and the
  # project-id-specific `urn:zitadel:iam:org:project:{id}:roles` for audience
  # projects requested via the roles scope (this is how the cross-project
  # argocd-* grant on "Brite Third Party Tools" arrives). Each value is a Hash
  # of role_key => { org_id => primary_domain }, so the Hash keys are the role
  # names. Read every shape so super-admin mapping is robust.
  def extract_oidc_role_keys(extra)
    raw = (extra && extra['raw_info']) || {}

    log_oidc_raw_claims(raw) if ENV['OIDC_LOG_ROLES'] == 'true'

    keys = Array(raw['groups']).map(&:to_s)
    raw.each do |claim, value|
      next unless project_roles_claim?(claim) && value.is_a?(Hash)

      keys.concat(value.keys.map(&:to_s))
    end

    keys.uniq
  end

  # Matches both the generic `urn:zitadel:iam:org:project:roles` claim and the
  # project-id-specific `urn:zitadel:iam:org:project:{id}:roles` claim.
  def project_roles_claim?(claim)
    key = claim.to_s
    key.start_with?('urn:zitadel:iam:org:project:') && key.end_with?(':roles')
  end

  # Dev-only debug (gated by OIDC_LOG_ROLES): log the claim keys present in the
  # token so we can confirm whether the cross-project role assertion landed.
  # Only keys are logged- never claim values- to avoid leaking PII.
  def log_oidc_raw_claims(raw)
    role_claim_keys = raw.keys.map(&:to_s).select { |k| project_roles_claim?(k) }
    Rails.logger.info("[oidc] raw_info claim keys: #{raw.keys.map(&:to_s).sort.inspect}")
    Rails.logger.info("[oidc] role claim keys present: #{role_claim_keys.inspect}")
  end

  # Stashed by redirect_callbacks (before `extra` is stripped) and read back in
  # omniauth_success after the redirect bounce, mirroring the role-key handling.
  def oidc_dealer_user_id
    session['oidc.dealer_user_id'].presence
  end

  def stash_oidc_dealer_user_id
    auth = request.env['omniauth.auth']
    return unless auth.present? && auth['provider'].to_s == 'openid_connect'

    session['oidc.dealer_user_id'] = extract_oidc_dealer_user_id(auth['extra'])
  rescue StandardError => e
    Rails.logger.error("[oidc] failed to stash dealer_user_id: #{e.class}: #{e.message}")
  end

  # Zitadel surfaces user metadata under the urn:zitadel:iam:user:metadata claim
  # as a Hash of base64-encoded values (the dealer_user_id is stored as metadata
  # by the dealers service). Decode it back to the raw UUID string.
  def extract_oidc_dealer_user_id(extra)
    raw = (extra && extra['raw_info']) || {}
    metadata = raw['urn:zitadel:iam:user:metadata']
    return nil unless metadata.is_a?(Hash)

    encoded = metadata['dealer_user_id']
    return nil if encoded.blank?

    Base64.decode64(encoded.to_s).strip.presence
  end

  def default_devise_mapping
    'user'
  end
end

DeviseOverrides::OmniauthCallbacksController.prepend_mod_with('DeviseOverrides::OmniauthCallbacksController')
