# frozen_string_literal: true
require "date"
require "rufus-scheduler"
require_relative "config"
require_relative "weather"
require_relative "llm"
require_relative "wordpress"
require_relative "x_poster"

module RecipePoster
  module Run
    module_function

    def once(meal)
      lat, lon = Config.coords
      forecast = Weather.fetch_daily(lat, lon, tz: Config.tz)
      weather_text = Weather.code_to_text(forecast[:code])
      season = Weather.season_for(forecast[:date])

      model = Config.models[:model]
      recipe = LLM.generate_recipe(forecast: forecast, meal: meal, model: model)

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
               WordPress.create_post!(title: title, html: html, slug: slug)
             end

      link = post["link"] || post.dig("guid","rendered") || "#{Config.wp_base}/?p=#{post["id"]}"
      meal_ja = (meal == "lunch" ? "昼" : "夜")
      d = Date.parse(forecast[:date]).strftime("%-m/%-d")
      tweet = "本日の#{meal_ja}（#{d}・#{weather_text}・#{forecast[:tmax]}℃/#{forecast[:tmin]}℃）\n#{title}\n#{link}"

      XPoster.post_tweet!(tweet)
      puts "[OK] #{meal} -> WP: #{link}"
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
