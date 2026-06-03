require 'rails_helper'

RSpec.describe Brite::Dealers::DealerResolutionService do
  let(:base_url) { 'https://dev.api.hdbrite.com' }
  let(:dealer_user_id) { '11111111-2222-3333-4444-555555555555' }
  let(:request_url) { "#{base_url}/v1/dealers-service/dealer-users/#{dealer_user_id}" }
  let(:token_service) { instance_double(Brite::Zitadel::MachineTokenService, token: 'bearer-token-xyz') }

  subject(:service) do
    described_class.new(dealer_user_id, base_url: base_url, token_service: token_service)
  end

  describe '#perform' do
    context 'when the dealer user is found' do
      before do
        stub_request(:get, request_url).to_return(
          status: 200,
          body: {
            user: {
              id: dealer_user_id,
              topLevelDealerId: 'top-dealer-1',
              topLevelDealerName: 'Acme Window Co'
            }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
      end

      it 'returns the top-level dealer id and name' do
        result = service.perform
        expect(result.top_level_dealer_id).to eq('top-dealer-1')
        expect(result.top_level_dealer_name).to eq('Acme Window Co')
      end

      it 'sends the machine-user bearer token' do
        service.perform
        expect(WebMock).to have_requested(:get, request_url)
          .with(headers: { 'Authorization' => 'Bearer bearer-token-xyz' })
      end
    end

    context 'when the response carries no user' do
      it 'returns nil' do
        stub_request(:get, request_url).to_return(
          status: 200,
          body: {}.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        expect(service.perform).to be_nil
      end
    end

    context 'when the dealer_user_id is blank' do
      it 'returns nil without calling the API' do
        svc = described_class.new('', base_url: base_url, token_service: token_service)
        expect(svc.perform).to be_nil
        expect(WebMock).not_to have_requested(:get, %r{/v1/dealers-service/dealer-users/})
      end
    end

    context 'when the base url is not configured' do
      it 'raises an ApiError' do
        svc = described_class.new(dealer_user_id, base_url: '', token_service: token_service)
        expect { svc.perform }.to raise_error(described_class::ApiError, /BRITE_DEALERS_API_BASE_URL/)
      end
    end

    context 'when the dealers API returns an error' do
      it 'raises an ApiError on a non-2xx response' do
        stub_request(:get, request_url).to_return(status: 404, body: 'not found')
        expect { service.perform }.to raise_error(described_class::ApiError, /404/)
      end
    end
  end
end
