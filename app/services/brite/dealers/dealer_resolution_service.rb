# BO-1696: Resolves a Brite dealer user's top-level dealer via the dealers
# REST API (GetDealerUser). Used at OIDC provisioning time to assign a new
# Chatwoot user to the Account named after their top-level dealer.
#
#   GET {BRITE_DEALERS_API_BASE_URL}/v1/dealers-service/dealer-users/{id}
#   Authorization: Bearer <brite-chatwoot machine-user token>
#
# Returns a Result with the top-level dealer id/name, or nil when the
# dealer_user_id is blank or the response carries no user.
module Brite
  module Dealers
    class DealerResolutionService
      class ApiError < StandardError; end

      Result = Struct.new(:top_level_dealer_id, :top_level_dealer_name, keyword_init: true)

      PATH_TEMPLATE = '/v1/dealers-service/dealer-users/%s'.freeze
      REQUEST_TIMEOUT = 10

      def initialize(dealer_user_id, base_url: nil, token_service: nil)
        @dealer_user_id = dealer_user_id
        @base_url = (base_url || ENV.fetch('BRITE_DEALERS_API_BASE_URL', nil)).to_s.chomp('/')
        @token_service = token_service || Brite::Zitadel::MachineTokenService.new
      end

      def perform
        return nil if @dealer_user_id.blank?
        raise ApiError, 'BRITE_DEALERS_API_BASE_URL is not configured' if @base_url.blank?

        response = HTTParty.get(
          request_url,
          headers: {
            'Authorization' => "Bearer #{@token_service.token}",
            'Accept' => 'application/json'
          },
          timeout: REQUEST_TIMEOUT
        )

        raise ApiError, "GetDealerUser failed: #{response.code} #{response.body}" unless response.success?

        build_result(response.parsed_response)
      end

      private

      def request_url
        "#{@base_url}#{format(PATH_TEMPLATE, ERB::Util.url_encode(@dealer_user_id))}"
      end

      # grpc-gateway emits default proto JSON (camelCase), wrapped in `user`.
      def build_result(body)
        user = body.is_a?(Hash) ? body['user'] : nil
        return nil if user.blank?

        Result.new(
          top_level_dealer_id: user['topLevelDealerId'],
          top_level_dealer_name: user['topLevelDealerName']
        )
      end
    end
  end
end
