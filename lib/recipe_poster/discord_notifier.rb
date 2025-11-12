# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

require_relative "logging"

module RecipePoster
  module DiscordNotifier
    module_function

    def alert!(content: nil, embeds: nil, username: nil)
      url = webhook_url
      return unless url

      uri = URI.parse(url)
      payload = {}
      payload["content"] = content if content
      payload["username"] = username if username
      payload["embeds"] = embeds if embeds && !embeds.empty?

      return if payload["content"].nil? && payload["embeds"].nil?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
        Logging.warn("discord.alert.failed", status: response.code, body: response.body)
      end
      response
    rescue => e
      Logging.warn("discord.alert.error", error: e.class.name, message: e.message)
      nil
    end

    def alert_error!(error, meal: nil, context: nil)
      embed = build_error_embed(error, meal: meal, context: context)
      alert!(content: error_message_prefix(meal: meal, context: context), embeds: [embed])
    end

    def webhook_url
      url = ENV["DISCORD_WEBHOOK_URL"] || ENV["DISCORD_ALERT_WEBHOOK_URL"]
      url = url&.strip
      return nil if url.nil? || url.empty?

      url
    end
    private :webhook_url

    def build_error_embed(error, meal:, context:)
      fields = []
      fields << { name: "Meal", value: meal, inline: true } if meal
      fields << { name: "Context", value: context, inline: true } if context
      backtrace = Array(error.backtrace).first(10)
      fields << { name: "Backtrace", value: "```\n#{backtrace.join("\n")}\n```" } if backtrace.any?

      {
        title: "RecipePoster Error",
        description: "#{error.class}: #{error.message}",
        color: 0xE74C3C,
        fields: fields,
        timestamp: Time.now.utc.iso8601
      }
    end
    private :build_error_embed

    def error_message_prefix(meal:, context:)
      parts = ["RecipePoster workflow failed"]
      parts << "(meal=#{meal})" if meal
      parts << "[#{context}]" if context
      parts.join(" ")
    end
    private :error_message_prefix
  end
end
