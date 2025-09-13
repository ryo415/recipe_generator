# frozen_string_literal: true
require "json"
require "faraday"
require "faraday/multipart"
require "simple_oauth"
require "stringio"
require_relative "x_oauth2"

module RecipePoster
  module XPoster
    module_function
    API_V1    = "https://api.twitter.com/1.1"
    UPLOAD_V1 = "https://upload.twitter.com/1.1"

    def http
      Faraday.new do |f|
        f.request :multipart
        f.request :url_encoded
        f.adapter :net_http
        t = (ENV["X_HTTP_TIMEOUT"] || "90").to_i
        o = (ENV["X_HTTP_OPEN_TIMEOUT"] || "15").to_i
        f.options.timeout = t; f.options.open_timeout = o
        f.options.read_timeout = t; f.options.write_timeout = t
      end
    end

    # --- v1.1 OAuth1 (media upload) ---
    def oauth1_header(method, url, params = {})
      ck = ENV.fetch("X_API_KEY")
      cs = ENV.fetch("X_API_SECRET")
      at = ENV.fetch("X_ACCESS_TOKEN")
      ts = ENV.fetch("X_ACCESS_SECRET")
      SimpleOAuth::Header.new(method, url, params, consumer_key: ck, consumer_secret: cs, token: at, token_secret: ts).to_s
    end

    def upload_media_bytes!(bytes, mime: "image/jpeg")
      url = "#{UPLOAD_V1}/media/upload.json"
      auth = oauth1_header(:post, url, {})
      payload = { media: Faraday::Multipart::FilePart.new(StringIO.new(bytes), mime, "image") }
      res = http.post(url) { |r| r.headers["Authorization"] = auth; r.body = payload }
      raise "X media upload error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)["media_id_string"]
    end

    def upload_media_url!(image_url)
      r = http.get(image_url); raise "download failed: #{r.status}" unless r.success?
      mime = image_url.downcase.end_with?(".png") ? "image/png" : "image/jpeg"
      upload_media_bytes!(r.body, mime: mime)
    end

    # --- v2 OAuth2 (tweet create) ---
    def v2_post_tweet!(text, media_ids: [])
      access = RecipePoster::XOauth2.refresh_if_needed!
      url = "https://api.twitter.com/2/tweets"
      body = { text: text }
      mids = Array(media_ids).compact
      body[:media] = { media_ids: mids } unless mids.empty?
      res = http.post(url) do |r|
        r.headers["Authorization"] = "Bearer #{access}"
        r.headers["Content-Type"]  = "application/json"
        r.body = JSON.dump(body)
      end
      raise "X v2 post error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    # 便利メソッド
    def post_tweet_with_image!(text, image_url)
      mid = upload_media_url!(image_url)
      v2_post_tweet!(text, media_ids: [mid])
    end

    def set_media_alt_text!(media_id, alt_text)
      return true if alt_text.to_s.empty?
      url  = "#{UPLOAD_V1}/media/metadata/create.json"
      auth = oauth1_header(:post, url, {})
      body = { media_id: media_id, alt_text: { text: alt_text.to_s[0, 1000] } }
      res = http.post(url) do |r|
        r.headers["Authorization"] = auth
        r.headers["Content-Type"]  = "application/json"
        r.body = JSON.dump(body)
      end
      raise "X media alt error: #{res.status} #{res.body}" unless res.success?
      true
    end

    # バイト列を直接添付してツイート（v2 /2/tweets を使用）
    def post_tweet_with_image_bytes!(text, bytes, mime: "image/jpeg", alt_text: nil)
      raise ArgumentError, "bytes is empty" if !bytes || bytes.empty?
      mid = upload_media_bytes!(bytes, mime: mime) # v1.1
      set_media_alt_text!(mid, alt_text) if alt_text
      v2_post_tweet!(text, media_ids: [mid])       # v2
    end

    def post_tweet!(text) = v2_post_tweet!(text)
  end
end
