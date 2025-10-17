# frozen_string_literal: true
require "json"
require "time"
require "fileutils"

module RecipePoster
  module History
    module_function

    FILE = File.expand_path("../../data/recipe_history.json", __dir__)

    THIRTY_DAYS = 30 * 86_400

    def load
      arr = JSON.parse(File.read(FILE)) rescue []
      prune(arr)
    end

    def save(arr)
      FileUtils.mkdir_p(File.dirname(FILE))
      File.write(FILE, JSON.pretty_generate(arr))
    end

    def prune(arr)
      cutoff = Time.now - THIRTY_DAYS
      filtered = arr.select do |entry|
        created_at = entry["created_at"] || ""
        time = Time.parse(created_at) rescue Time.at(0)
        time >= cutoff
      end

      save(filtered) if filtered.length != arr.length
      filtered
    end

    # 直近 days 日ぶん（meal で昼/夜を絞り込み可）
    def recent(days: 14, meal: nil)
      cutoff = Time.now - days * 86_400
      load.select do |e|
        t = Time.parse(e["created_at"] || "") rescue Time.at(0)
        (meal.nil? || e["meal"] == meal) && t >= cutoff
      end
    end

    # 記録（最後500件だけ保持）
    def record!(entry)
      arr = load
      entry["created_at"] ||= Time.now.iso8601
      arr << entry
      arr = arr.last(500)
      save(arr)
    end
  end
end
