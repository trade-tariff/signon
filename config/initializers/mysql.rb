Mysql2::Client.default_query_options[:connect_flags] |= Mysql2::Client::SSL if Rails.env.production?
