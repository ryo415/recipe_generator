# frozen_string_literal: true
require "json"
require "faraday"
require "securerandom"
require "base64"

require_relative "logging"
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

    def generate_bytes!(prompt:, size: ENV["IMG_SIZE"] || "1024x1024",
                        max_retries: (ENV["OPENAI_IMAGE_MAX_RETRIES"] || "6").to_i,
                        base_sleep_ms: (ENV["OPENAI_IMAGE_BACKOFF_BASE_MS"] || "800").to_i)

      Logging.info("image.generate_bytes.start", size: size, max_retries: max_retries)
      # 送信前スロットリング/クールダウン（あなたの実装のままでOK）
      RecipePoster::RateLimit.wait_cooldown!("openai_images")
      RecipePoster::RateLimit.throttle!("openai_images",
        min_interval_ms: (ENV["OPENAI_IMAGE_MIN_INTERVAL_MS"] || "25000").to_i
      )

      Logging.debug("image.generate_bytes.rate_limited", key: "openai_images")

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

      Logging.debug("image.generate_bytes.http_config", timeout: http_timeout, open_timeout: http_open_timeout, write_timeout: http_write_timeout)

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

          Logging.info("image.generate_bytes.request", attempt: attempts, status: res.status)
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError => e
          # ← 追加: タイムアウト/接続失敗も指数バックオフで再試行
          raise "OpenAI image network error: #{e.class}: #{e.message}" if attempts > max_retries
          wait = (base_sleep_ms/1000.0) * (2 ** (attempts - 1)) + rand * 0.8
          Logging.warn("image.generate_bytes.retry", error: e.class.name, wait_seconds: format('%.2f', wait), attempt: attempts, max_retries: max_retries)
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
          Logging.warn("image.generate_bytes.backoff", status: res.status, wait_seconds: format('%.2f', wait), request_id: hdr['x-request-id'] || "-", attempt: attempts)
          sleep wait
          RecipePoster::RateLimit.set_cooldown!("openai_images",
            seconds: (ENV["OPENAI_IMAGE_COOLDOWN_SEC"] || "60").to_i
          )
          next
        end

        raise "OpenAI image error: #{res.status} #{res.body}" unless res.success?

        data0 = JSON.parse(res.body).dig("data", 0) || {}
        if (b64 = data0["b64_json"]).to_s != ""
          decoded = Base64.decode64(b64)
          Logging.info("image.generate_bytes.success", attempt: attempts, bytes: decoded.bytesize)
          return decoded
        elsif (u = data0["url"]).to_s != ""
          img = conn.get(u) { |r| r.options.timeout = http_timeout }  # 画像URL取得もタイムアウト延長
          raise "Fetch image failed: #{img.status}" unless img.success?
          body = img.body
          Logging.info("image.generate_bytes.success", attempt: attempts, bytes: body.bytesize)
          return body
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