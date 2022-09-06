require "sidekiq"
require "paas_config"

redis_config = PaasConfig.redis

Sidekiq.configure_server do |config|
  config.redis = redis_config
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
