require 'rails_helper'

RSpec.describe Brite::Dealers::AccountAssignmentService do
  let(:dealer_user_id) { 'du-123' }
  let(:dealer) do
    Brite::Dealers::DealerResolutionService::Result.new(
      top_level_dealer_id: 'top-dealer-1', top_level_dealer_name: 'Acme Window Co'
    )
  end

  def stub_resolution(result)
    resolver = instance_double(Brite::Dealers::DealerResolutionService, perform: result)
    allow(Brite::Dealers::DealerResolutionService).to receive(:new).and_return(resolver)
  end

  describe '#perform' do
    it 'creates and returns the account named after the top-level dealer' do
      stub_resolution(dealer)

      account = described_class.new(dealer_user_id: dealer_user_id, is_admin: false).perform

      expect(account).to be_persisted
      expect(account.name).to eq('Acme Window Co')
    end

    it 'reuses an existing account with the same dealer name' do
      stub_resolution(dealer)
      existing = create(:account, name: 'Acme Window Co')

      account = described_class.new(dealer_user_id: dealer_user_id, is_admin: false).perform

      expect(account.id).to eq(existing.id)
      expect(Account.where(name: 'Acme Window Co').count).to eq(1)
    end

    it 'returns nil for a non-admin whose dealer cannot be resolved' do
      stub_resolution(nil)

      account = described_class.new(dealer_user_id: 'du-404', is_admin: false).perform

      expect(account).to be_nil
    end

    it 'falls back to the first account for a super admin without a dealer' do
      stub_resolution(nil)
      first_account = create(:account)

      account = described_class.new(dealer_user_id: nil, is_admin: true).perform

      expect(account).to eq(first_account)
    end

    it 'falls back to the first account for a super admin when resolution raises' do
      first_account = create(:account)
      resolver = instance_double(Brite::Dealers::DealerResolutionService)
      allow(resolver).to receive(:perform).and_raise(Brite::Dealers::DealerResolutionService::ApiError, 'boom')
      allow(Brite::Dealers::DealerResolutionService).to receive(:new).and_return(resolver)

      account = described_class.new(dealer_user_id: dealer_user_id, is_admin: true).perform

      expect(account).to eq(first_account)
    end
  end
end
