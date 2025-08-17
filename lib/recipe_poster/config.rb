# frozen_string_literal: true
require "base64"

module RecipePoster
  module Config
    module_function

    def env!(key)
      ENV.fetch(key) { raise("#{key} is required") }
    end

    def ai_provider
      (ENV["AI_PROVIDER"] || "gemini").downcase
    end

    def tz
      ENV["TZ"] || "Asia/Tokyo"
    end

    def coords
      lat = (ENV["LAT"] || "35.6762").to_f
      lon = (ENV["LON"] || "139.6503").to_f
      [lat, lon]
    end

    def wp_base
      env!("WP_BASE_URL").sub(%r{/\z}, "")
    end

    def wp_user
      env!("WP_USERNAME")
    end

    def wp_app_password
      env!("WP_APP_PASSWORD")
    end

    def wp_basic_auth
      Base64.strict_encode64("\#{wp_user}:\#{wp_app_password}")
    end

    def x_credentials
      {
        consumer_key:    env!("X_API_KEY"),
        consumer_secret: env!("X_API_SECRET"),
        token:           env!("X_ACCESS_TOKEN"),
        token_secret:    env!("X_ACCESS_SECRET")
      }
    end

    def models
      case ai_provider
      when "gemini"
        { provider: "gemini", model: (ENV["GEMINI_MODEL"] || "gemini-2.5-flash") }
      else
        { provider: "openai", model: (ENV["OPENAI_MODEL"] || "gpt-4.1-mini") }
      end
    end
  end
end
