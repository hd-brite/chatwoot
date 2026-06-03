# BO-1696: Resolves which Chatwoot Account a newly provisioned OIDC user should
# join. Users are assigned to the Account named after their top-level dealer
# (resolved from the dealers API by their dealer_user_id). Super admins without
# a resolvable dealer fall back to the first account. Returns nil when a
# non-admin's dealer cannot be resolved, so the caller can refuse provisioning
# rather than drop them into an arbitrary account.
class Brite::Dealers::AccountAssignmentService
  def initialize(dealer_user_id:, is_admin:)
    @dealer_user_id = dealer_user_id
    @is_admin = is_admin
  end

  def perform
    dealer = resolve_top_level_dealer
    return find_or_create_dealer_account(dealer) if dealer&.top_level_dealer_name.present?

    @is_admin ? Account.first : nil
  end

  private

  def resolve_top_level_dealer
    return nil if @dealer_user_id.blank?

    Brite::Dealers::DealerResolutionService.new(@dealer_user_id).perform
  rescue StandardError => e
    Rails.logger.error("[oidc] dealer resolution failed for dealer_user_id=#{@dealer_user_id}: #{e.class}: #{e.message}")
    nil
  end

  def find_or_create_dealer_account(dealer)
    name = dealer.top_level_dealer_name.to_s.strip
    return nil if name.blank?

    Account.transaction do
      Account.lock.find_by(name: name) || Account.create!(
        name: name,
        locale: I18n.locale,
        custom_attributes: {
          'onboarding_step' => 'account_details',
          'brite_top_level_dealer_id' => dealer.top_level_dealer_id
        }
      )
    end
  end
end
