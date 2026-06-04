# Be sure to restart your server when you modify this file.

# OIDC SSO stashes the auth payload into the session during the
# devise_token_auth redirect_callbacks bounce. With the default cookie store
# that payload (including the id_token) bloats the `_chatwoot_session` cookie
# past the ~4KB cookie limit and the nginx proxy header buffer, returning a
# 502 ("upstream sent too big header") and breaking SSO login.
#
# Use a Redis-backed cache store for sessions in deployed environments so the
# cookie only carries a small session id. Reuses the existing Redis config
# (see config/initializers/01_redis.rb and lib/redis/config.rb); no new gem.
# Local development and the test suite keep the cookie store to avoid a hard
# Redis dependency.
if Rails.env.production?
  session_redis_cache = ActiveSupport::Cache::RedisCacheStore.new(
    redis: -> { Redis.new(Redis::Config.app) },
    namespace: 'chatwoot_session',
    pool: { size: Integer(ENV.fetch('REDIS_SESSION_POOL_SIZE', 5)), timeout: 1 },
    error_handler: lambda do |method:, returning:, exception:|
      Rails.logger.error("[session-store] Redis error in #{method} (returning #{returning.inspect}): #{exception.class}: #{exception.message}")
    end
  )

  Rails.application.config.session_store :cache_store,
                                         cache: session_redis_cache,
                                         key: '_chatwoot_session',
                                         same_site: :lax,
                                         expire_after: 30.days
else
  Rails.application.config.session_store :cookie_store, key: '_chatwoot_session', same_site: :lax
end
