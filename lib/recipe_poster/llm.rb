# frozen_string_literal: true
require "json"
require "faraday"
require_relative "config"
require_relative "weather"

module RecipePoster
  module LLM
    module_function

    def build_prompt(forecast:, meal:)
      season = Weather.season_for(forecast[:date])
      weather_text = Weather.code_to_text(forecast[:code])
      <<~PROMPT
      あなたは日本の家庭料理に詳しいプロの料理家です。以下条件に最適な「\#{meal == 'lunch' ? 'ランチ' : '夕食'}」レシピを日本語で1つ提案してください。

      # 条件
      - 季節: \#{season}
      - 天気: \#{weather_text}（降水確率: \#{forecast[:pop]}% / 降水量合計: \#{forecast[:rain_sum]}mm）
      - 気温: 最高\#{forecast[:tmax]}℃ / 最低\#{forecast[:tmin]}℃
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
      url = "https://generativelanguage.googleapis.com/v1beta/models/\#{model}:generateContent?key=\#{api_key}"
      body = {
        contents: [{ role: "user", parts: [{ text: build_prompt(forecast: forecast, meal: meal) }] }],
        generationConfig: { response_mime_type: "application/json" }
      }
      res = Faraday.post(url) { |r| r.headers["Content-Type"] = "application/json"; r.body = JSON.dump(body) }
      raise "Gemini API error: \#{res.status} \#{res.body}" unless res.success?
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
        r.headers["Authorization"] = "Bearer \#{api_key}"
        r.body = JSON.dump(body)
      end
      raise "OpenAI API error: \#{res.status} \#{res.body}" unless res.success?
      txt = JSON.parse(res.body).dig("choices", 0, "message", "content")
      JSON.parse(txt)
    end
  end
end
