# Bridges a verified OIDC super admin (argocd-*) into the separate :super_admin
# Devise scope that the /super_admin console authenticates against, and decides
# whether to route them straight to that console. Mixed into the OIDC callbacks
# controller, which provides oidc_provider?/oidc_user_is_admin?/oidc_dealer_user_id.
module OidcSuperAdminBridge
  private

  # Sign the admin into the :super_admin cookie session so the console works
  # without a second password login. Gated on argocd-* - the same check that
  # governs SuperAdmin promotion.
  def bridge_super_admin_session_from_oidc
    return unless oidc_provider? && oidc_user_is_admin? && @resource&.persisted?

    sign_in(:super_admin, SuperAdmin.find(@resource.id))
  end

  # Route admins straight to /super_admin when they have no dealer/agent context
  # (no dealer_user_id) or initiated SSO from the console sign-in page (its
  # button sends ?origin=/super_admin, stashed by stash_oidc_origin).
  def oidc_redirect_to_super_admin?
    return false unless oidc_provider? && oidc_user_is_admin?

    session['oidc.origin'].to_s.start_with?('/super_admin') || oidc_dealer_user_id.blank?
  end

  # Stashed in redirect_callbacks before the devise_token_auth bounce strips it.
  def stash_oidc_origin
    auth = request.env['omniauth.auth']
    return unless auth.present? && auth['provider'].to_s == 'openid_connect'

    session['oidc.origin'] = request.env['omniauth.origin'].presence
  rescue StandardError => e
    Rails.logger.error("[oidc] failed to stash origin: #{e.class}: #{e.message}")
  end
end
