class PaasConfig
  def self.redis
    url = begin
      JSON.parse(ENV["VCAP_SERVICES"])["redis"][0]["credentials"]["uri"]
    rescue StandardError
      ENV["REDIS_URL"]
    end

    { url: url, db: Rails.env.test? ? 1 : 0, id: nil }
  end
end
