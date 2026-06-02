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
    def set_oidc_omniauth(email:, groups: [], name: 'OIDC User', provider: :openid_connect)
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: provider,
        uid: "oidc-#{email}",
        info: { name: name, email: email, email_verified: true },
        credentials: { token: 'access-token' },
        extra: { raw_info: { 'groups' => groups } }
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

    # BO-1796: ArgoCD and Chatwoot live in different Zitadel projects, so a
    # Chatwoot login never carries argocd-* grants. A dedicated `chatwoot-admin`
    # role is granted on the brite_chatwoot project instead, and must also map
    # to SuperAdmin (alongside the default argocd-* prefix).
    it 'promotes an existing user to super admin when they hold the chatwoot-admin role' do
      with_modified_env FRONTEND_URL: 'http://www.example.com' do
        user = create(:user, email: 'chatwoot-admin@example.com')
        set_oidc_omniauth(email: 'chatwoot-admin@example.com', groups: %w[chatwoot-admin])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).to eq('SuperAdmin')
      end
    end

    it 'respects the OIDC_ADMIN_ROLE_KEYS override and ignores default prefixes' do
      with_modified_env FRONTEND_URL: 'http://www.example.com', OIDC_ADMIN_ROLE_KEYS: 'chatwoot-admin' do
        argocd_user = create(:user, email: 'argocd-only@example.com')
        set_oidc_omniauth(email: 'argocd-only@example.com', groups: %w[argocd-admins])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        # argocd- is no longer an admin prefix once the env var is overridden.
        expect(argocd_user.reload.type).not_to eq('SuperAdmin')
      end
    end

    it 'promotes via a custom OIDC_ADMIN_ROLE_KEYS prefix' do
      with_modified_env FRONTEND_URL: 'http://www.example.com', OIDC_ADMIN_ROLE_KEYS: 'chatwoot-admin' do
        user = create(:user, email: 'custom-admin@example.com')
        set_oidc_omniauth(email: 'custom-admin@example.com', groups: %w[chatwoot-admin])

        get '/omniauth/google_oauth2/callback'
        follow_redirect!

        expect(user.reload.type).to eq('SuperAdmin')
      end
    end
  end
end
