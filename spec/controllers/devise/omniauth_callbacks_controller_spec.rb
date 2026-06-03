require 'rails_helper'

RSpec.describe 'DeviseOverrides::OmniauthCallbacksController', type: :request do
  let(:account_builder) { double }
  let(:user_double) { object_double(:user) }
  let(:email_validation_service) { instance_double(Account::SignUpEmailValidationService) }

  def set_omniauth_config(for_email = 'test@example.com')
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google',
      uid: '123545',
      info: {
        name: 'test',
        email: for_email,
        image: 'https://example.com/image.jpg'
      }
    )
  end

  before do
    allow(Account::SignUpEmailValidationService).to receive(:new).and_return(email_validation_service)
  end

  describe '#omniauth_sucess' do
    before do
      GlobalConfig.clear_cache
    end

    it 'allows signup' do
      with_modified_env ENABLE_ACCOUNT_SIGNUP: 'true', FRONTEND_URL: 'http://www.example.com' do
        set_omniauth_config('test_not_preset@example.com')
        allow(AccountBuilder).to receive(:new).and_return(account_builder)
        allow(account_builder).to receive(:perform).and_return(user_double)
        allow(Avatar::AvatarFromUrlJob).to receive(:perform_later).and_return(true)
        allow(email_validation_service).to receive(:perform).and_return(true)

        get '/omniauth/google_oauth2/callback'

        # expect a 302 redirect to auth/google_oauth2/callback
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
        follow_redirect!

        expect(AccountBuilder).to have_received(:new).with({
                                                             account_name: 'example',
                                                             user_full_name: 'test',
                                                             email: 'test_not_preset@example.com',
                                                             locale: I18n.locale,
                                                             confirmed: nil
                                                           })
        expect(account_builder).to have_received(:perform)
      end
    end

    it 'blocks personal accounts signup' do
      with_modified_env ENABLE_ACCOUNT_SIGNUP: 'true', FRONTEND_URL: 'http://www.example.com' do
        set_omniauth_config('personal@gmail.com')
        allow(email_validation_service).to receive(:perform).and_raise(CustomExceptions::Account::InvalidEmail.new({ valid: false, disposable: nil }))

        get '/omniauth/google_oauth2/callback'

        # expect a 302 redirect to auth/google_oauth2/callback
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
        follow_redirect!

        # expect a 302 redirect to app/login with error disallowing personal accounts
        expect(response).to redirect_to(%r{/app/login\?error=business-account-only$})
      end
    end

    it 'blocks personal accounts signup with different Gmail case variations' do
      with_modified_env ENABLE_ACCOUNT_SIGNUP: 'true', FRONTEND_URL: 'http://www.example.com' do
        # Test different case variations of Gmail
        ['personal@Gmail.com', 'personal@GMAIL.com', 'personal@Gmail.COM'].each do |email|
          set_omniauth_config(email)
          allow(email_validation_service).to receive(:perform).and_raise(CustomExceptions::Account::InvalidEmail.new({ valid: false,
                                                                                                                       disposable: nil }))

          get '/omniauth/google_oauth2/callback'

          # expect a 302 redirect to auth/google_oauth2/callback
          expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
          follow_redirect!

          # expect a 302 redirect to app/login with error disallowing personal accounts
          expect(response).to redirect_to(%r{/app/login\?error=business-account-only$})
        end
      end
    end

    # This test does not affect line coverage, but it is important to ensure that the logic
    # does not allow any signup if the ENV explicitly disables it
    it 'blocks signup if ENV disabled' do
      with_modified_env ENABLE_ACCOUNT_SIGNUP: 'false', FRONTEND_URL: 'http://www.example.com' do
        set_omniauth_config('does-not-exist-for-sure@example.com')
        allow(email_validation_service).to receive(:perform).and_return(true)

        get '/omniauth/google_oauth2/callback'

        # expect a 302 redirect to auth/google_oauth2/callback
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
        follow_redirect!

        # expect a 302 redirect to app/login with error disallowing signup
        expect(response).to redirect_to(%r{/app/login\?error=no-account-found$})
      end
    end

    it 'blocks signup if config is stored as boolean false' do
      GlobalConfig.clear_cache
      InstallationConfig.where(name: 'ENABLE_ACCOUNT_SIGNUP').delete_all
      InstallationConfig.create!(name: 'ENABLE_ACCOUNT_SIGNUP', value: false, locked: false)

      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        set_omniauth_config('does-not-exist-for-sure@example.com')
        allow(email_validation_service).to receive(:perform).and_return(true)

        get '/omniauth/google_oauth2/callback'

        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
        follow_redirect!
        expect(response).to redirect_to(%r{/app/login\?error=no-account-found$})
      end
    ensure
      InstallationConfig.where(name: 'ENABLE_ACCOUNT_SIGNUP').delete_all
      GlobalConfig.clear_cache
    end

    it 'allows login' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        create(:user, email: 'test@example.com')
        set_omniauth_config('test@example.com')

        get '/omniauth/google_oauth2/callback'
        # expect a 302 redirect to auth/google_oauth2/callback
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')

        follow_redirect!
        expect(response).to redirect_to(%r{/app/login\?email=.+&sso_auth_token=.+$})

        # expect app/login page to respond with 200 and render
        follow_redirect!
        expect(response).to have_http_status(:ok)
      end
    end

    # from a line coverage point of view this may seem redundant
    # but to ensure that the logic allows for existing users even if they have a gmail account
    # we need to test this explicitly
    it 'allows personal account login' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        create(:user, email: 'personal-existing@gmail.com')
        set_omniauth_config('personal-existing@gmail.com')

        get '/omniauth/google_oauth2/callback'
        # expect a 302 redirect to auth/google_oauth2/callback
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')

        follow_redirect!
        expect(response).to redirect_to(%r{/app/login\?email=.+&sso_auth_token=.+$})

        # expect app/login page to respond with 200 and render
        follow_redirect!
        expect(response).to have_http_status(:ok)
      end
    end

    it 'resets password for an unconfirmed persisted user on OAuth login' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'unconfirmed-oauth@example.com', skip_confirmation: false)
        original_password_digest = user.encrypted_password
        set_omniauth_config('unconfirmed-oauth@example.com')

        get '/omniauth/google_oauth2/callback'
        expect(response).to redirect_to('http://www.example.com/auth/google_oauth2/callback')
        follow_redirect!

        user.reload
        expect(user).to be_confirmed
        expect(user.encrypted_password).not_to eq(original_password_digest)
      end
    end
  end

  describe '#omniauth_success with OpenID Connect (Zitadel)' do
    # Brite's Zitadel emits a user's granted roles via a flat `groups` claim in
    # `extra.raw_info`. devise_token_auth strips `extra` during the callback
    # bounce, so the controller stashes role keys in redirect_callbacks; these
    # tests exercise that end-to-end through the bounce.
    #
    # The `openid_connect` provider is only registered when OIDC_ISSUER_URL is
    # set (see config/initializers/omniauth.rb), so it is absent from the
    # OmniAuth middleware in the test env. We therefore drive the flow through
    # the always-registered google_oauth2 transport while crafting the auth
    # hash with provider :openid_connect and the `groups` claim - the
    # controller branches on auth_hash['provider'], so the exercised code path
    # is identical to a real OIDC callback.
    #
    # The provider defaults to the Symbol :openid_connect because that is what
    # OmniAuth actually emits at runtime (the strategy is registered with
    # `name: :openid_connect`). Mocking it as a String previously hid a bug
    # where the controller compared the Symbol value against a String literal.
    # `project_roles` mimics Zitadel's `urn:zitadel:iam:org:project:roles` claim,
    # a Hash keyed by role name. Chatwoot's brite-chatwoot app lives in a
    # different Zitadel project than the argocd-* roles, so the flat `groups`
    # claim arrives empty; the audience scope added in omniauth.rb instead
    # surfaces those roles under this project-roles claim. extract_oidc_role_keys
    # reads both shapes, so super-admin mapping must work from either one.
    # `dealer_user_id` mimics Zitadel's urn:zitadel:iam:user:metadata claim, a
    # Hash of base64-encoded metadata values. The controller decodes it back to
    # the raw UUID to resolve the user's top-level dealer and gate logins.
    def set_oidc_omniauth(email:, groups: [], project_roles: nil, dealer_user_id: nil, provider: :openid_connect)
      OmniAuth.config.test_mode = true
      raw_info = { 'groups' => groups }
      raw_info['urn:zitadel:iam:org:project:roles'] = project_roles unless project_roles.nil?
      raw_info['urn:zitadel:iam:user:metadata'] = { 'dealer_user_id' => Base64.strict_encode64(dealer_user_id) } unless dealer_user_id.nil?
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: provider,
        uid: "oidc-#{email}",
        info: { name: 'OIDC User', email: email, email_verified: true },
        credentials: { token: 'access-token' },
        extra: { raw_info: raw_info }
      )
    end

    before do
      GlobalConfig.clear_cache
      allow(email_validation_service).to receive(:perform).and_return(true)
    end

    after do
      OmniAuth.config.mock_auth[:google_oauth2] = nil
    end

    it 'promotes an existing user to super admin when they hold an argocd role' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'oidc-admin@example.com')
        set_oidc_omniauth(email: 'oidc-admin@example.com', groups: %w[argocd-admins])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).to eq('SuperAdmin')
      end
    end

    it 'keeps a non-argocd existing user as a normal user' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'oidc-user@example.com')
        set_oidc_omniauth(email: 'oidc-user@example.com', groups: %w[lms-admin])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).not_to eq('SuperAdmin')
      end
    end

    # BO-1696: the brite-chatwoot app is in its own Zitadel project, so the
    # flat `groups` claim is empty; argocd-* roles arrive via the
    # urn:zitadel:iam:org:project:roles claim once the Third Party Tools project
    # is added to the token audience. Lock that the super-admin mapping works
    # from the project-roles claim shape (Hash keyed by role name).
    it 'promotes an existing user to super admin from the project-roles claim' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'oidc-proj-admin@example.com')
        set_oidc_omniauth(
          email: 'oidc-proj-admin@example.com',
          groups: [],
          project_roles: { 'argocd-admins' => { '12345' => 'brite-devops.example.com' } }
        )

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).to eq('SuperAdmin')
      end
    end

    it 'keeps a user with only non-argocd project roles as a normal user' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'oidc-proj-user@example.com')
        set_oidc_omniauth(
          email: 'oidc-proj-user@example.com',
          groups: [],
          project_roles: { 'lms-admin' => { '12345' => 'brite-devops.example.com' } }
        )

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).not_to eq('SuperAdmin')
      end
    end

    it 'demotes a super admin who no longer holds an argocd role' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        create(:user, email: 'oidc-exadmin@example.com', type: 'SuperAdmin')
        set_oidc_omniauth(email: 'oidc-exadmin@example.com', groups: [])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(User.from_email('oidc-exadmin@example.com').type).to eq('User')
      end
    end

    it 'auto-provisions a new argocd user as a super admin administrator' do
      with_modified_env FRONTEND_URL: 'http://www.example.com', OIDC_AUTO_PROVISION: 'true' do
        account = create(:account)
        set_oidc_omniauth(email: 'new-admin@example.com', groups: %w[argocd-users])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        user = User.from_email('new-admin@example.com')
        expect(user).to be_present
        expect(user.type).to eq('SuperAdmin')
        expect(account.account_users.find_by(user_id: user.id).role).to eq('administrator')
      end
    end

    it 'auto-provisions a new non-argocd user as a normal agent' do
      with_modified_env FRONTEND_URL: 'http://www.example.com', OIDC_AUTO_PROVISION: 'true' do
        account = create(:account)
        set_oidc_omniauth(email: 'new-agent@example.com', groups: [])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        user = User.from_email('new-agent@example.com')
        expect(user).to be_present
        expect(user.type).not_to eq('SuperAdmin')
        expect(account.account_users.find_by(user_id: user.id).role).to eq('agent')
      end
    end

    # BO-1696: Brite dealer integration. Enabled only when
    # BRITE_DEALERS_API_BASE_URL is set; non-super-admins must carry a
    # dealer_user_id, and provisioned users are assigned to the account named
    # after their top-level dealer (resolved via the dealers API).
    describe 'dealer integration (BRITE_DEALERS_API_BASE_URL set)' do
      let(:dealer_env) do
        { FRONTEND_URL: 'http://www.example.com', BRITE_DEALERS_API_BASE_URL: 'https://dev.api.hdbrite.com' }
      end

      def stub_dealer_resolution(result)
        resolver = instance_double(Brite::Dealers::DealerResolutionService, perform: result)
        allow(Brite::Dealers::DealerResolutionService).to receive(:new).and_return(resolver)
      end

      it 'blocks a non-admin OIDC login that has no dealer_user_id' do
        with_modified_env(**dealer_env) do
          create(:user, email: 'no-dealer@example.com')
          set_oidc_omniauth(email: 'no-dealer@example.com', groups: [])

          get '/omniauth/google_oauth2/callback'
          follow_redirect!

          expect(response.location).to include('no-dealer-access')
        end
      end

      it 'allows a super admin to log in without a dealer_user_id' do
        with_modified_env(**dealer_env) do
          user = create(:user, email: 'admin-no-dealer@example.com')
          set_oidc_omniauth(email: 'admin-no-dealer@example.com', groups: %w[argocd-admins])

          get '/omniauth/google_oauth2/callback'
          follow_redirect!

          expect(response.location).not_to include('no-dealer-access')
          expect(response.location).to include('sso_auth_token')
          expect(user.reload.type).to eq('SuperAdmin')
        end
      end

      it 'assigns a provisioned dealer user to their top-level dealer account' do
        with_modified_env(**dealer_env, OIDC_AUTO_PROVISION: 'true') do
          stub_dealer_resolution(
            Brite::Dealers::DealerResolutionService::Result.new(
              top_level_dealer_id: 'top-dealer-1', top_level_dealer_name: 'Acme Window Co'
            )
          )
          set_oidc_omniauth(email: 'dealer-user@example.com', groups: [], dealer_user_id: 'du-123')

          get '/omniauth/google_oauth2/callback'
          follow_redirect!

          account = Account.find_by(name: 'Acme Window Co')
          expect(account).to be_present
          user = User.from_email('dealer-user@example.com')
          expect(account.account_users.find_by(user_id: user.id).role).to eq('agent')
        end
      end

      it 'blocks a provisioned non-admin whose dealer lookup yields no dealer' do
        with_modified_env(**dealer_env, OIDC_AUTO_PROVISION: 'true') do
          stub_dealer_resolution(nil)
          set_oidc_omniauth(email: 'unresolved-dealer@example.com', groups: [], dealer_user_id: 'du-404')

          get '/omniauth/google_oauth2/callback'
          follow_redirect!

          expect(response.location).to include('no-account-found')
          expect(User.from_email('unresolved-dealer@example.com')).to be_nil
        end
      end
    end

    # Regression for BO-1795: OmniAuth emits the provider as the Symbol
    # :openid_connect, but the controller compared it against the String
    # 'openid_connect'. The Symbol != String mismatch silently skipped the
    # super-admin mapping for every real login. Lock both shapes.
    [:openid_connect, 'openid_connect'].each do |provider_value|
      it "promotes an argocd user when provider is #{provider_value.class}(#{provider_value.inspect})" do
        with_modified_env FRONTEND_URL: 'http://www.example.com' do
          user = create(:user, email: 'oidc-provider-shape@example.com')
          set_oidc_omniauth(email: 'oidc-provider-shape@example.com', groups: %w[argocd-admins], provider: provider_value)

          get '/omniauth/google_oauth2/callback'
          follow_redirect!

          expect(user.reload.type).to eq('SuperAdmin')
        end
      end
    end
  end
end
