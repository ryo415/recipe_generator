# frozen_string_literal: true

require "logger"

module RecipePoster
  module Logging
    module_function

    def logger
      @logger ||= ::Logger.new($stdout, progname: "RecipePoster").tap do |log|
        log.level = log_level
        log.formatter = proc do |severity, datetime, progname, msg|
          ts = datetime.getlocal.strftime("%Y-%m-%d %H:%M:%S")
          label = progname ? "#{progname} " : ""
          formatted = format_message(msg)
          "#{ts} [#{severity}] #{label}#{formatted}\n"
        end
      end
    end

    def debug(message = nil, **fields)
      logger.debug(compose(message, fields))
    end

    def info(message = nil, **fields)
      logger.info(compose(message, fields))
    end

    def warn(message = nil, **fields)
      logger.warn(compose(message, fields))
    end

    def error(message = nil, **fields)
      logger.error(compose(message, fields))
    end

    def with_level(level)
      old = logger.level
      logger.level = level
      yield
    ensure
      logger.level = old
    end

    def compose(message, fields)
      return nil if message.nil? && fields.empty?

      parts = []
      parts << message.to_s if message
      unless fields.empty?
        parts << fields.map { |k, v| "#{k}=#{format_value(v)}" }.join(" ")
      end
      parts.join(" ")
    end
    private :compose

    def format_value(value)
      case value
      when Hash
        "{" + value.map { |k, v| "#{k}:#{format_value(v)}" }.join(",") + "}"
      when Array
        "[" + value.map { |v| format_value(v) }.join(",") + "]"
      when String
        value
      when Numeric, Symbol, TrueClass, FalseClass, NilClass
        value.inspect
      when ->(v) { v.respond_to?(:to_s) }
        value.to_s
      else
        value.inspect
      end
    end
    private :format_value

    def format_message(message)
      case message
      when String then message
      when Exception then "#{message.class}: #{message.message}"
      else
        message.inspect
      end
    end
    private :format_message

    def log_level
      level = ENV.fetch("RECIPE_POSTER_LOG_LEVEL", "info").to_s.downcase
      case level
      when "debug" then ::Logger::DEBUG
      when "warn" then ::Logger::WARN
      when "error" then ::Logger::ERROR
      when "fatal" then ::Logger::FATAL
      else
        ::Logger::INFO
      end
    end
    private :log_level
  end
end
