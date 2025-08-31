# frozen_string_literal: true
require "json"
require "faraday"
require_relative "config"
require_relative "weather"

module RecipePoster
  module LLM
    module_function

    def build_prompt_with_diversity(forecast:, meal:, avoid: {})
      season = Weather.season_for(forecast[:date])
      weather_text = Weather.code_to_text(forecast[:code])

      avoid_titles      = Array(avoid[:titles]).uniq.first(10)
      avoid_ingredients = Array(avoid[:ingredients]).uniq.first(10)
      avoid_methods     = Array(avoid[:methods]).uniq.first(10)

      <<~PROMPT
      あなたは日本の家庭料理のプロ。以下条件に最適な「#{meal == 'lunch' ? 'ランチ' : '夕食'}」レシピを日本語で1つ提案。

      # 条件
      - 季節: #{season}
      - 天気: #{weather_text}（降水確率: #{forecast[:pop]}% / 降水量合計: #{forecast[:rain_sum]}mm）
      - 気温: 最高#{forecast[:tmax]}℃ / 最低#{forecast[:tmin]}℃
      - 家庭で作りやすい。45分以内が目安。
      - 多様性: 下記に該当するメニューは避ける。被らない主材料・調理法にする。
        * 避けたい料理名: #{avoid_titles.join(", ")}
        * 避けたい主材料: #{avoid_ingredients.join(", ")}
        * 避けたい調理法: #{avoid_methods.join(", ")}

      # 出力は必ず JSON（UTF-8）で。キー厳守
      {
        "title": string,
        "summary": string,
        "servings": integer,
        "time_minutes": integer,
        "ingredients": [{"item": string, "amount": string}],
        "steps": [string, ...],
        "tips": [string, ...],
        "nutrition": {"kcal": integer, "protein_g": integer, "fat_g": integer, "carb_g": integer},
        "slug_tokens_en": [string, ...],
        "hashtags": [string, ...],

        // 多様性メタ（新規）
        "primary_ingredient": string, // 例: 鶏むね肉 / 豚こま / 豆腐 / そうめん
        "method": string,             // 例: 炒め / 煮る / 揚げ / 蒸す / 和える / 冷製
        "category": string            // 例: 主菜 / 麺 / ごはん / 汁物 / サラダ 等
      }
      PROMPT
    end

    def generate_recipe_diverse(forecast:, meal:, model: Config.models[:model], tries: 3, avoid:)
      tries.times do
        json = if Config.models[:provider] == "gemini"
          gemini_generate_with_prompt(build_prompt_with_diversity(forecast: forecast, meal: meal, avoid: avoid), model)
        else
          openai_generate_with_prompt(build_prompt_with_diversity(forecast: forecast, meal: meal, avoid: avoid), model)
        end
        return json if passes_diversity?(json, avoid)
        # 次トライでは「同系統は不可」を強める（軽い促し）
        avoid = {
          titles: Array(avoid[:titles]) + [json["title"]].compact,
          ingredients: Array(avoid[:ingredients]) + [json["primary_ingredient"]].compact,
          methods: Array(avoid[:methods]) + [json["method"]].compact
        }
      end
      # どうしても通らない場合は最後の案を返す
      if Config.models[:provider] == "gemini"
        gemini_generate_with_prompt(build_prompt_with_diversity(forecast: forecast, meal: meal, avoid: avoid), model)
      else
        openai_generate_with_prompt(build_prompt_with_diversity(forecast: forecast, meal: meal, avoid: avoid), model)
      end
    end

    def openai_generate_with_prompt(prompt, model)
      api_key = ENV.fetch("OPENAI_API_KEY")
      url = "https://api.openai.com/v1/chat/completions"
      body = {
        model: model,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: "You are a helpful Japanese cooking expert. Always reply in valid JSON." },
          { role: "user", content: prompt }
        ]
      }
      res = Faraday.post(url) { |r| r.headers["Content-Type"]="application/json"; r.headers["Authorization"]="Bearer #{api_key}"; r.body=JSON.dump(body) }
      raise "OpenAI API error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(JSON.parse(res.body).dig("choices", 0, "message", "content"))
    end

    def gemini_generate_with_prompt(prompt, model)
      api_key = ENV.fetch("GEMINI_API_KEY")
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"
      body = { contents: [{ role: "user", parts: [{ text: prompt }] }], generationConfig: { response_mime_type: "application/json" } }
      res = Faraday.post(url) { |r| r.headers["Content-Type"]="application/json"; r.body=JSON.dump(body) }
      raise "Gemini API error: #{res.status} #{res.body}" unless res.success?
      json_text = JSON.parse(res.body).dig("candidates",0,"content","parts",0,"text")
      JSON.parse(json_text)
    end

    def passes_diversity?(recipe, avoid)
      t   = recipe["title"].to_s
      ing = recipe["primary_ingredient"].to_s
      met = recipe["method"].to_s
      # 料理名は「含む」でざっくりブロック、主材料/調理法は一致でブロック
      return false if Array(avoid[:titles]).any? { |x| !x.to_s.empty? && t.include?(x.to_s) }
      return false if Array(avoid[:ingredients]).any? { |x| !x.to_s.empty? && x.to_s == ing }
      return false if Array(avoid[:methods]).any? { |x| !x.to_s.empty? && x.to_s == met }
      true
    end

    def build_prompt(forecast:, meal:)
      season = Weather.season_for(forecast[:date])
      weather_text = Weather.code_to_text(forecast[:code])
      <<~PROMPT
      あなたは日本の家庭料理に詳しいプロの料理家です。以下条件に最適な「#{meal == 'lunch' ? 'ランチ' : '夕食'}」レシピを日本語で1つ提案してください。

      # 条件
      - 季節: #{season}
      - 天気: #{weather_text}（降水確率: #{forecast[:pop]}% / 降水量合計: #{forecast[:rain_sum]}mm）
      - 気温: 最高#{forecast[:tmax]}℃ / 最低#{forecast[:tmin]}℃
      - 日本の家庭で作りやすい（手に入る食材、道具）
      - 季節感・気温に合う献立（暑い日はさっぱり・冷たい、寒い日は温かい・滋養 など）
      - 1品で主菜になること。所要時間は45分以内目標

      # 出力は必ずJSON（UTF-8, 改行含む）で（キー名厳守）
      {
        "title": string,
        "summary": string,
        "servings": integer,
        "time_minutes": integer,
        "ingredients": [{"item": string, "amount": string}],
        "steps": [string, ...],
        "tips": [string, ...],
        "slug_tokens_en": [string, ...],
        "nutrition": {"kcal": integer, "protein_g": integer, "fat_g": integer, "carb_g": integer},
        "hashtags": [string, ...]
      }
      PROMPT
    end

    def generate_recipe(forecast:, meal:, model: Config.models[:model])
      provider = Config.models[:provider]
      if provider == "gemini"
        gemini_generate(forecast: forecast, meal: meal, model: model)
      else
        openai_generate(forecast: forecast, meal: meal, model: model)
      end
    end

    def gemini_generate(forecast:, meal:, model:)
      api_key = ENV.fetch("GEMINI_API_KEY")
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"
      body = {
        contents: [{ role: "user", parts: [{ text: build_prompt(forecast: forecast, meal: meal) }] }],
        generationConfig: { response_mime_type: "application/json" }
      }
      res = Faraday.post(url) { |r| r.headers["Content-Type"] = "application/json"; r.body = JSON.dump(body) }
      raise "Gemini API error: #{res.status} #{res.body}" unless res.success?
      json_text = JSON.parse(res.body).dig("candidates", 0, "content", "parts", 0, "text")
      JSON.parse(json_text)
    end

    def openai_generate(forecast:, meal:, model:)
      api_key = ENV.fetch("OPENAI_API_KEY")
      url = "https://api.openai.com/v1/chat/completions"
      body = {
        model: model,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: "You are a helpful Japanese cooking expert. Always reply in valid JSON." },
          { role: "user", content: build_prompt(forecast: forecast, meal: meal) }
        ]
      }
      res = Faraday.post(url) do |r|
        r.headers["Content-Type"] = "application/json"
        r.headers["Authorization"] = "Bearer #{api_key}"
        r.body = JSON.dump(body)
      end
      raise "OpenAI API error: #{res.status} #{res.body}" unless res.success?
      txt = JSON.parse(res.body).dig("choices", 0, "message", "content")
      JSON.parse(txt)
    end
  end
end
