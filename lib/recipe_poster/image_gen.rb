# frozen_string_literal: true
require "json"
require "faraday"
require "securerandom"
require "base64"   # Ruby 3.4 では default gem ではないので Gemfile に `gem "base64"` を追加してください

require_relative "rate_limit"
require_relative "config"
require_relative "wordpress"

module RecipePoster
  module ImageGen
    module_function

    # レシピ→画像プロンプト（日本語OK、英語キーワードも足すと安定）
    def build_image_prompt(recipe:, season:, weather_text:)
      title = recipe["title"].to_s
      points = [
        title,
        (recipe["primary_ingredient"] || recipe.dig("ingredients", 0, "item")),
        (recipe["method"] || "home cooking"),
        (recipe["category"] || "main dish"),
        season, weather_text
      ].compact

      <<~PROMPT
      A high-quality food photograph styled illustration of "#{title}".
      Japanese home-cooking plating on a simple table setting, bright natural light, appetizing, 3:2 crop safe.
      Details to reflect: #{points.join(", ")}.
      No text, watermark, logo, or hands. Focus on the finished dish only.
      PROMPT
    end

    # OpenAI 画像生成 → バイナリ返却
    def generate_bytes!(prompt:, size: ENV["IMG_SIZE"] || "1024x1024",
                        max_retries: (ENV["OPENAI_IMAGE_MAX_RETRIES"] || "4").to_i,
                        base_sleep_ms: (ENV["OPENAI_IMAGE_BACKOFF_BASE_MS"] || "500").to_i)
      # 送信前にクールダウンを確認
      RecipePoster::RateLimit.wait_cooldown!("openai_images")

      # 1枚ごと最小25秒（3RPM対策）
      RecipePoster::RateLimit.throttle!(
        "openai_images",
        min_interval_ms: (ENV["OPENAI_IMAGE_MIN_INTERVAL_MS"] || "25000").to_i
      )
      api_key = ENV.fetch("OPENAI_API_KEY")
      url  = "https://api.openai.com/v1/images/generations"
      body = { model: "gpt-image-1", prompt: prompt, size: size }

      http_timeout       = (ENV["OPENAI_HTTP_TIMEOUT"] || "180").to_i       # 全体読み取り
      http_open_timeout  = (ENV["OPENAI_HTTP_OPEN_TIMEOUT"] || "15").to_i   # 接続確立
      http_write_timeout = (ENV["OPENAI_HTTP_WRITE_TIMEOUT"] || "180").to_i # 送信

      attempts = 0
      loop do
        attempts += 1
        res = Faraday.post(url) do |r|
          r.headers["Authorization"] = "Bearer #{api_key}"
          r.headers["Content-Type"]  = "application/json"
          r.body = JSON.dump(body)
        end

        payload = JSON.parse(res.body) rescue {}
        err_code = payload.dig("error","code").to_s

        hdr = {}; res.headers.each { |k,v| hdr[k.to_s.downcase] = v }
        warn "[OPENAI] status=#{res.status} code=#{err_code} "\
             "limit=#{hdr['x-ratelimit-limit-requests']}/m "\
             "remain=#{hdr['x-ratelimit-remaining-requests']} "\
             "reset=#{hdr['x-ratelimit-reset-requests']} req_id=#{hdr['x-request-id']}"

        if err_code == "insufficient_quota"
          raise "OpenAI image error: insufficient quota/billing. Add funds or raise monthly budget."
        end

        # リトライ上限
        raise "OpenAI image error: #{res.status} #{res.body}" if attempts > max_retries

        # 429 or 5xx → リトライ（Retry-After優先）
        if res.status == 429 || (500..599).cover?(res.status)
          if attempts > max_retries
            raise "OpenAI image error: #{res.status} #{res.body}"
          end
          hdr = {}
          res.headers.each { |k,v| hdr[k.to_s.downcase] = v }
          wait =
            if hdr["retry-after"]
              [hdr["retry-after"].to_f, 0.3].max  # 0秒指示対策で最小0.3s
            else
              (base_sleep_ms / 1000.0) * (2 ** (attempts - 1)) + rand * 0.3
            end
          warn "[INFO] OpenAI rate-limited/status #{res.status}. retrying in #{format('%.2f', wait)}s (#{attempts}/#{max_retries})"
          sleep wait
          next
        end

        # その他のエラーは即終了
        raise "OpenAI image error: #{res.status} #{res.body}" unless res.success?

        data0 = JSON.parse(res.body).dig("data", 0) || {}
        if (b64 = data0["b64_json"]).to_s != ""
          return Base64.decode64(b64)
        elsif (u = data0["url"]).to_s != ""
          img = Faraday.get(u)
          raise "Fetch image failed: #{img.status}" unless img.success?
          return img.body
        else
          raise "OpenAI image: neither b64_json nor url in response"
        end
      end
    end
    
    def generate_bytes!(prompt:, size: ENV["IMG_SIZE"] || "1024x1024",
                        max_retries: (ENV["OPENAI_IMAGE_MAX_RETRIES"] || "6").to_i,
                        base_sleep_ms: (ENV["OPENAI_IMAGE_BACKOFF_BASE_MS"] || "800").to_i)
    
      # 送信前スロットリング/クールダウン（あなたの実装のままでOK）
      RecipePoster::RateLimit.wait_cooldown!("openai_images")
      RecipePoster::RateLimit.throttle!("openai_images",
        min_interval_ms: (ENV["OPENAI_IMAGE_MIN_INTERVAL_MS"] || "25000").to_i
      )
    
      size = normalize_size(size) if respond_to?(:normalize_size) # あれば
    
      api_key = ENV.fetch("OPENAI_API_KEY")
    
      # ← 追加: Faradayコネクションを作ってタイムアウトを拡張
      http_timeout       = (ENV["OPENAI_HTTP_TIMEOUT"] || "180").to_i       # 全体読み取り
      http_open_timeout  = (ENV["OPENAI_HTTP_OPEN_TIMEOUT"] || "15").to_i   # 接続確立
      http_write_timeout = (ENV["OPENAI_HTTP_WRITE_TIMEOUT"] || "180").to_i # 送信
    
      conn = Faraday.new(url: "https://api.openai.com") do |f|
        f.request :url_encoded
        f.adapter :net_http
        f.options.timeout       = http_timeout
        f.options.open_timeout  = http_open_timeout
        # net-http 0.6 以降は read/write_timeout を個別設定可能
        f.options.read_timeout  = http_timeout
        f.options.write_timeout = http_write_timeout
      end
    
      attempts = 0
      loop do
        attempts += 1
        body = { model: "gpt-image-1", prompt: prompt, size: size }
    
        begin
          res = conn.post("/v1/images/generations") do |r|
            r.headers["Authorization"] = "Bearer #{api_key}"
            r.headers["Content-Type"]  = "application/json"
            r.body = JSON.dump(body)
            # 念のためリクエスト単位でも上書き可
            r.options.timeout       = http_timeout
            r.options.open_timeout  = http_open_timeout
            r.options.read_timeout  = http_timeout
            r.options.write_timeout = http_write_timeout
          end
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
          # ← 追加: タイムアウト/接続失敗も指数バックオフで再試行
          raise "OpenAI image network error: #{e.class}: #{e.message}" if attempts > max_retries
          wait = (base_sleep_ms/1000.0) * (2 ** (attempts - 1)) + rand * 0.8
          warn "[OPENAI] network error #{e.class} → retry in #{format('%.2f', wait)}s (#{attempts}/#{max_retries})"
          sleep wait
          next
        end
    
        # 429/5xx → 既存のバックオフ処理（あなたの分岐があればそのまま）
        if res.status == 429 || (500..599).cover?(res.status)
          payload = JSON.parse(res.body) rescue {}
          code = payload.dig("error","code").to_s
          if code == "insufficient_quota"
            raise "OpenAI image error: insufficient quota/billing. Billingでクレジット追加が必要です。"
          end
          raise "OpenAI image error: #{res.status} #{res.body}" if attempts > max_retries
          hdr = {}; res.headers.each { |k,v| hdr[k.to_s.downcase] = v }
          ra  = hdr["retry-after"]; ra_f = ra.to_f
          wait = ra_f > 0 ? ra_f : (base_sleep_ms/1000.0) * (2 ** (attempts - 1)) + rand * 0.8
          warn "[OPENAI] 429/5xx → wait #{format('%.2f', wait)}s (req_id=#{hdr['x-request-id'] || '-'})"
          sleep wait
          RecipePoster::RateLimit.set_cooldown!("openai_images",
            seconds: (ENV["OPENAI_IMAGE_COOLDOWN_SEC"] || "60").to_i
          )
          next
        end
    
        raise "OpenAI image error: #{res.status} #{res.body}" unless res.success?
    
        data0 = JSON.parse(res.body).dig("data", 0) || {}
        if (b64 = data0["b64_json"]).to_s != ""
          return Base64.decode64(b64)
        elsif (u = data0["url"]).to_s != ""
          img = conn.get(u) { |r| r.options.timeout = http_timeout }  # 画像URL取得もタイムアウト延長
          raise "Fetch image failed: #{img.status}" unless img.success?
          return img.body
        else
          raise "OpenAI image: neither b64_json nor url in response"
        end
      end
    end

    # 生成→WPメディアへアップロード（IDとURLを返す）
    def generate_and_upload!(recipe:, season:, weather_text:, size: nil)
      prompt = build_image_prompt(recipe: recipe, season: season, weather_text: weather_text)
      bytes  = generate_bytes!(prompt: prompt, size: size)
      fname  = "recipe-#{Time.now.to_i}-#{SecureRandom.hex(3)}.png"
      media_id, url = WordPress.upload_media_from_bytes!(bytes, filename: fname, mime: "image/png")
      [media_id, url]
    end
  end
end