require 'rails_helper'

RSpec.describe Brite::Oidc::RoleClaimExtractor do
  def extra_with(raw_info)
    { 'raw_info' => raw_info }
  end

  describe '#role_keys' do
    it 'returns an empty array when extra is nil' do
      expect(described_class.new(nil).role_keys).to eq([])
    end

    it 'returns an empty array when raw_info is missing' do
      expect(described_class.new({}).role_keys).to eq([])
    end

    it 'reads roles from the flat groups claim' do
      extra = extra_with('groups' => %w[argocd-admins lms-admin])

      expect(described_class.new(extra).role_keys).to contain_exactly('argocd-admins', 'lms-admin')
    end

    it 'reads roles from the generic project-roles claim (Hash keyed by role)' do
      extra = extra_with(
        'urn:zitadel:iam:org:project:roles' => {
          'argocd-admins' => { '12345' => 'brite-devops.example.com' }
        }
      )

      expect(described_class.new(extra).role_keys).to contain_exactly('argocd-admins')
    end

    it 'reads roles from the project-id-specific roles claim (cross-project grant)' do
      extra = extra_with(
        'urn:zitadel:iam:org:project:348444441574376526:roles' => {
          'argocd-admins' => { '12345' => 'brite-devops.example.com' }
        }
      )

      expect(described_class.new(extra).role_keys).to contain_exactly('argocd-admins')
    end

    it 'merges and de-duplicates roles across all claim shapes' do
      extra = extra_with(
        'groups' => %w[argocd-admins],
        'urn:zitadel:iam:org:project:roles' => { 'argocd-admins' => {} },
        'urn:zitadel:iam:org:project:348444441574376526:roles' => { 'dealer-admin' => {} }
      )

      expect(described_class.new(extra).role_keys).to contain_exactly('argocd-admins', 'dealer-admin')
    end

    it 'ignores project-roles claims whose value is not a Hash' do
      extra = extra_with('urn:zitadel:iam:org:project:roles' => 'not-a-hash')

      expect(described_class.new(extra).role_keys).to eq([])
    end

    it 'does not treat unrelated claims as roles' do
      extra = extra_with(
        'urn:zitadel:iam:user:metadata' => { 'dealer_user_id' => 'abc' },
        'email' => 'user@example.com'
      )

      expect(described_class.new(extra).role_keys).to eq([])
    end

    context 'when OIDC_LOG_ROLES is enabled' do
      it 'logs the claim keys (never values) without altering the result' do
        extra = extra_with(
          'urn:zitadel:iam:org:project:348444441574376526:roles' => { 'argocd-admins' => {} }
        )
        allow(Rails.logger).to receive(:info)

        with_modified_env OIDC_LOG_ROLES: 'true' do
          result = described_class.new(extra).role_keys
          expect(result).to contain_exactly('argocd-admins')
        end

        expect(Rails.logger).to have_received(:info).with(/raw_info claim keys/)
        expect(Rails.logger).to have_received(:info).with(/role claim keys present/)
      end
    end
  end
end
