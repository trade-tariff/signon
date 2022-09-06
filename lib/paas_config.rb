class PaasConfig
  def self.redis
    url = begin
      # TODO: !Important
      # need to fetch by service name if we use multiple redis services
      JSON.parse(ENV["VCAP_SERVICES"])["redis"][0]["credentials"]["uri"]
    rescue StandardError
      ENV["REDIS_URL"]
    end

    { url: url, db: Rails.env.test? ? 1 : 0, id: nil }
  end
end
