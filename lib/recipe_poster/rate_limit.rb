# frozen_string_literal: true
require "json"
require "fileutils"

require_relative "logging"

module RecipePoster
  module RateLimit
    module_function

    STATE = File.expand_path("../../data/rate_state.json", __dir__)

    # 例: throttle!("openai_images", min_interval_ms: 2000)
    def throttle!(key, min_interval_ms:)
      Logging.info("rate_limit.throttle", key: key, min_interval_ms: min_interval_ms)
      FileUtils.mkdir_p(File.dirname(STATE))
      File.open(STATE, File.exist?(STATE) ? "r+" : "w+") do |f|
        f.flock(File::LOCK_EX)
        data = (f.size > 0 ? JSON.parse(f.read) : {}) rescue {}
        data[key] ||= 0.0
        now = monotonic
        elapsed_ms = (now - data[key]) * 1000.0
        wait_ms = min_interval_ms.to_f - elapsed_ms
        if wait_ms > 0
          Logging.debug("rate_limit.sleep", key: key, wait_ms: wait_ms.round(1))
          sleep(wait_ms / 1000.0)
          now = monotonic
        end
        # 書き戻し
        f.rewind
        f.truncate(0)
        data[key] = now
        f.write(JSON.generate(data))
        f.flush
        f.flock(File::LOCK_UN)
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cooldown_path(key)
      File.expand_path("../../data/#{key}.cooldown", __dir__)
    end

    def set_cooldown!(key, seconds:)
      Logging.info("rate_limit.set_cooldown", key: key, seconds: seconds)
      FileUtils.mkdir_p(File.dirname(cooldown_path(key)))
      File.write(cooldown_path(key), (monotonic + seconds).to_f.to_s)
    end

    def wait_cooldown!(key)
      path = cooldown_path(key)
      return unless File.exist?(path)
      until_time = (File.read(path).to_f rescue 0.0)
      remain = until_time - monotonic
      if remain > 0
        Logging.info("rate_limit.cooldown_wait", key: key, seconds: remain.round(1))
        sleep(remain)
      else
        File.delete(path) rescue nil
      end
    end
  end
end