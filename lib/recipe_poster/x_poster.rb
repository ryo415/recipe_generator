# frozen_string_literal: true
require "json"
require "faraday"
require "simple_oauth"
require_relative "config"

module RecipePoster
  module XPoster
    module_function

    API_BASE = "https://api.x.com"

    def post_tweet!(text)
      url = "\#{API_BASE}/2/tweets"
      creds = Config.x_credentials
      header = SimpleOAuth::Header.new(:post, url, {}, {
        consumer_key: creds[:consumer_key],
        consumer_secret: creds[:consumer_secret],
        token: creds[:token],
        token_secret: creds[:token_secret]
      })

      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = header.to_s
        r.headers["Content-Type"] = "application/json"
        r.body = JSON.dump({ text: text })
      end
      raise "X API error: \#{res.status} \#{res.body}" unless res.success?
      JSON.parse(res.body)
    end
  end
end
