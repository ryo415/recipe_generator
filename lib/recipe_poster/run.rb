# frozen_string_literal: true
require "date"
require "rufus-scheduler"
require_relative "config"
require_relative "weather"
require_relative "llm"
require_relative "wordpress"
require_relative "x_poster"
require_relative "history"

module RecipePoster
  module Run
    module_function

    def once(meal)
      lat, lon = Config.coords
      forecast = Weather.fetch_daily(lat, lon, tz: Config.tz)
      weather_text = Weather.code_to_text(forecast[:code])
      season = Weather.season_for(forecast[:date])

      recent = History.recent(days: 14, meal: meal)
      avoid = {
        titles:      recent.map { |e| e["title"] }.compact,
        ingredients: recent.map { |e| e["primary_ingredient"] }.compact,
        methods:     recent.map { |e| e["method"] }.compact
      }

      model = Config.models[:model]
      # recipe = LLM.generate_recipe(forecast: forecast, meal: meal, model: model)
      recipe = LLM.generate_recipe_diverse(forecast: forecast, meal: meal, model: model, avoid: avoid)

      title = recipe["title"]
      date = Date.parse(forecast[:date]).strftime("%Y-%m-%d")
      slug = "#{date}-#{meal}-#{title.gsub(/[^\p{Alnum}]+/,'-').downcase}"[0,80]

      existing = WordPress.get_by_slug(slug)

      post = if existing.is_a?(Array) && !existing.empty?
               existing.first
             else
               html = WordPress.build_html(recipe, {
                 season: season, weather_text: weather_text,
                 pop: forecast[:pop], tmax: forecast[:tmax], tmin: forecast[:tmin]
               })
               tags = Array(recipe["hashtags"]).map { |h| h.to_s.sub(/^#/, "") }.reject(&:empty?).uniq
               tags |= [season, weather_text].compact

               cats = [(meal == "lunch" ? "昼ごはん" : "夜ごはん")]

               featured = ENV["DEFAULT_IMAGE_URL"] || ENV["WP_DEFAULT_IMAGE_URL"]

              WordPress.create_post!(
                title: title,
                html: html,
                slug: slug,
                status: "publish",
                tag_names: tags,                 # ← タグ名配列
                category_names: cats,            # ← カテゴリ名配列
                featured_image_url: featured     # ← 画像URL（nilなら無視）
              )
            end

      RecipePoster::History.record!(
        "meal" => meal,
        "title" => title,
        "primary_ingredient" => recipe["primary_ingredient"],
        "method" => recipe["method"],
        "category" => recipe["category"],
        "season" => season
      )

      link = post["link"] || post.dig("guid","rendered") || "#{Config.wp_base}/?p=#{post["id"]}"
      meal_ja = (meal == "lunch" ? "昼" : "夜")
      d = Date.parse(forecast[:date]).strftime("%-m/%-d")

      body  = "本日の#{meal_ja}（#{d}・#{weather_text}・#{forecast[:tmax]}℃/#{forecast[:tmin]}℃）\n#{title}\n#{link}"
      x_tags = build_hashtags_for_x(recipe: recipe, meal: meal, season: season, weather_text: weather_text)
      tweet  = pack_tweet(body, x_tags)

      XPoster.post_tweet!(tweet)
      puts "[OK] #{meal} -> WP: #{link}"
    end

    def hashtagify(str)
      core = str.to_s.sub(/^#/, "")
      core = core.gsub(/[^\p{Hiragana}\p{Katakana}\p{Han}A-Za-z0-9_ー]+/, "")
      return nil if core.empty?
      "##{core}"
    end

    def build_hashtags_for_x(recipe:, meal:, season:, weather_text:)
      meal_tag = (meal == "lunch" ? "昼ごはん" : "夜ごはん")
      base = ["毎日レシピ", meal_tag, season, weather_text, "簡単レシピ"]
      model_tags = Array(recipe["hashtags"])
      (base + model_tags).map { |t| hashtagify(t) }.compact.uniq.first(6)
    end

    def pack_tweet(body, tags, limit: 280)
      text = [body, tags.join(" ")].reject(&:empty?).join("\n")
      return text if text.length <= limit
      pruned = tags.dup
      while pruned.any?
        text = [body, pruned.join(" ")].reject(&:empty?).join("\n")
        return text if text.length <= limit
        pruned.pop
      end
      body[0, limit - 1] + "…"
    end

    def schedule
      scheduler = Rufus::Scheduler.new
      scheduler.cron "0 12 * * * Asia/Tokyo" do
        once("lunch")
      end
      scheduler.cron "0 18 * * * Asia/Tokyo" do
        once("dinner")
      end
      puts "Scheduler started (12:00 / 18:00 JST). Press Ctrl+C to exit."
      scheduler.join
    end
  end
end
