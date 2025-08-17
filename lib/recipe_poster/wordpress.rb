# frozen_string_literal: true
require "json"
require "faraday"
require_relative "config"

module RecipePoster
  module WordPress
    module_function

    def create_post!(title:, html:, slug:)
      url = "\#{Config.wp_base}/wp-json/wp/v2/posts"
      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = "Basic \#{Config.wp_basic_auth}"
        r.headers["Content-Type"] = "application/json"
        r.body = JSON.dump({ title: title, content: html, status: "publish", slug: slug })
      end
      raise "WordPress create error: \#{res.status} \#{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    def get_by_slug(slug)
      url = "\#{Config.wp_base}/wp-json/wp/v2/posts?slug=\#{URI.encode_www_form_component(slug)}"
      res = Faraday.get(url) { |r| r.headers["Authorization"] = "Basic \#{Config.wp_basic_auth}" }
      raise "WordPress get error: \#{res.status} \#{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    def build_html(recipe, meta)
      ing_lines = recipe["ingredients"].map { |i| "<li>\#{i["item"]} – \#{i["amount"]}</li>" }.join
      steps = recipe["steps"].each_with_index.map { |s, i| "<li>\#{i + 1}. \#{s}</li>" }.join
      tips = (recipe["tips"] || []).map { |t| "<li>\#{t}</li>" }.join
      hashtags = (recipe["hashtags"] || []).map { |h| "##\#{h.gsub(/^#/, "")}" }.join(" ")
      <<~HTML
        <h2>概要</h2>
        <p>\#{recipe["summary"]}</p>
        <ul>
          <li>想定人数: \#{recipe["servings"]}人分</li>
          <li>調理時間: 約\#{recipe["time_minutes"]}分</li>
          <li>天気: \#{meta[:weather_text]}（降水確率\#{meta[:pop]}%） / 最高\#{meta[:tmax]}℃ 最低\#{meta[:tmin]}℃ / 季節: \#{meta[:season]}</li>
        </ul>

        <h2>材料</h2>
        <ul>\#{ing_lines}</ul>

        <h2>作り方</h2>
        <ol>\#{steps}</ol>

        <h2>栄養の目安（1人分）</h2>
        <ul>
          <li>エネルギー: \#{recipe.dig("nutrition","kcal")} kcal</li>
          <li>たんぱく質: \#{recipe.dig("nutrition","protein_g")} g</li>
          <li>脂質: \#{recipe.dig("nutrition","fat_g")} g</li>
          <li>炭水化物: \#{recipe.dig("nutrition","carb_g")} g</li>
        </ul>

        <h2>コツ・補足</h2>
        <ul>\#{tips}</ul>

        <p>\#{hashtags}</p>
      HTML
    end
  end
end
