# BO-1696: Extracts a user's role keys from an OIDC token's raw claims. Brite's
# Zitadel emits granted roles in three shapes, and super-admin mapping must work
# from any of them:
#   - a flat `groups` claim (set by the AddGroupsClaim action; also consumed by
#     ArgoCD),
#   - the generic `urn:zitadel:iam:org:project:roles` claim (the app's own
#     project), and
#   - project-id-specific `urn:zitadel:iam:org:project:{id}:roles` claims, which
#     is how a cross-project grant (e.g. argocd-* on the separate "Brite Third
#     Party Tools" project) arrives once the audience scope and the
#     `urn:zitadel:iam:org:projects:roles` scope are both requested.
# Each project-roles value is a Hash of role_key => { org_id => primary_domain },
# so the Hash keys are the role names.
class Brite::Oidc::RoleClaimExtractor
  PROJECT_ROLES_PREFIX = 'urn:zitadel:iam:org:project:'.freeze
  PROJECT_ROLES_SUFFIX = ':roles'.freeze

  def initialize(extra)
    @raw = (extra && extra['raw_info']) || {}
  end

  def role_keys
    log_claims if ENV['OIDC_LOG_ROLES'] == 'true'

    (group_keys + project_role_keys).uniq
  end

  private

  def group_keys
    Array(@raw['groups']).map(&:to_s)
  end

  def project_role_keys
    @raw.each_with_object([]) do |(claim, value), keys|
      keys.concat(value.keys.map(&:to_s)) if project_roles_claim?(claim) && value.is_a?(Hash)
    end
  end

  # Matches both the generic `urn:zitadel:iam:org:project:roles` claim and the
  # project-id-specific `urn:zitadel:iam:org:project:{id}:roles` claim.
  def project_roles_claim?(claim)
    key = claim.to_s
    key.start_with?(PROJECT_ROLES_PREFIX) && key.end_with?(PROJECT_ROLES_SUFFIX)
  end

  # Dev-only debug (gated by OIDC_LOG_ROLES): log the claim keys present in the
  # token so cross-project role assertion can be verified. Only keys are logged-
  # never claim values- to avoid leaking PII.
  def log_claims
    present = @raw.keys.map(&:to_s).select { |k| project_roles_claim?(k) }
    Rails.logger.info("[oidc] raw_info claim keys: #{@raw.keys.map(&:to_s).sort.inspect}")
    Rails.logger.info("[oidc] role claim keys present: #{present.inspect}")
  end
end
