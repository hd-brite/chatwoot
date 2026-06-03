require 'rails_helper'

RSpec.describe Brite::Zitadel::MachineTokenService do
  subject(:service) do
    described_class.new(issuer_url: issuer, project_id: project_id, machine_key_json: machine_key_json)
  end

  let(:issuer) { 'https://auth.test.example.com' }
  let(:project_id) { '319057286905463843' }
  let(:rsa_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:machine_key_json) do
    {
      type: 'serviceaccount',
      keyId: 'kid-123',
      key: rsa_key.to_pem,
      userId: 'machine-user-1'
    }.to_json
  end
  let(:token_url) { "#{issuer}/oauth/v2/token" }
  let(:token_response) { { access_token: 'access-token-abc', expires_in: 3600 }.to_json }
  let(:expected_scope) do
    [
      'openid', 'profile', 'roles',
      'urn:zitadel:iam:org:projects:roles',
      'urn:zitadel:iam:org:project:id:zitadel:aud',
      "urn:zitadel:iam:org:project:id:#{project_id}:aud"
    ].join(' ')
  end

  before { Rails.cache.clear }

  describe '#token' do
    context 'when Zitadel responds successfully' do
      before do
        stub_request(:post, token_url).to_return(
          status: 200,
          body: token_response,
          headers: { 'Content-Type' => 'application/json' }
        )
      end

      it 'returns the access token' do
        expect(service.token).to eq('access-token-abc')
      end

      it 'uses the JWT-bearer grant with the reserved Brite project audience scope' do
        service.token

        expect(WebMock).to have_requested(:post, token_url).with(
          body: hash_including(
            'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'scope' => expected_scope
          )
        )
      end

      it 'signs the assertion with the machine key and the expected claims' do
        captured_body = nil
        stub_request(:post, token_url).with { |req| captured_body = req.body }.to_return(
          status: 200, body: token_response, headers: { 'Content-Type' => 'application/json' }
        )

        service.token

        assertion = Rack::Utils.parse_nested_query(captured_body)['assertion']
        payload, header = JWT.decode(assertion, rsa_key.public_key, true, { algorithm: 'RS256' })
        expect(header['kid']).to eq('kid-123')
        expect(payload).to include('iss' => 'machine-user-1', 'sub' => 'machine-user-1', 'aud' => issuer)
      end

      it 'caches the token and does not refetch on subsequent calls' do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

        2.times { service.token }

        expect(WebMock).to have_requested(:post, token_url).once
      end
    end

    context 'when configuration is missing' do
      it 'raises when the machine key is blank' do
        svc = described_class.new(issuer_url: issuer, project_id: project_id, machine_key_json: nil)
        expect { svc.token }.to raise_error(described_class::ConfigurationError, /MACHINE_KEY/)
      end

      it 'raises when the project id is blank' do
        svc = described_class.new(issuer_url: issuer, project_id: nil, machine_key_json: machine_key_json)
        expect { svc.token }.to raise_error(described_class::ConfigurationError, /PROJECT_ID/)
      end

      it 'raises when the issuer url is blank' do
        svc = described_class.new(issuer_url: '', project_id: project_id, machine_key_json: machine_key_json)
        expect { svc.token }.to raise_error(described_class::ConfigurationError, /issuer/)
      end

      it 'raises when the machine key json is invalid' do
        svc = described_class.new(issuer_url: issuer, project_id: project_id, machine_key_json: 'not-json')
        expect { svc.token }.to raise_error(described_class::ConfigurationError, /valid JSON/)
      end
    end

    context 'when Zitadel returns an error' do
      it 'raises a TokenError on a non-2xx response' do
        stub_request(:post, token_url).to_return(status: 401, body: 'unauthorized')
        expect { service.token }.to raise_error(described_class::TokenError, /401/)
      end

      it 'raises a TokenError when the response has no access_token' do
        stub_request(:post, token_url).to_return(
          status: 200,
          body: { token_type: 'Bearer' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
        expect { service.token }.to raise_error(described_class::TokenError, /missing access_token/)
      end
    end
  end
end
