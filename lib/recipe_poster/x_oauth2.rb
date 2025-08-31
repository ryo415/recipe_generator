# frozen_string_literal: true
require "json"
require "faraday"
require "securerandom"
require "digest"
require "base64"
require "cgi"
require "fileutils"

module RecipePoster
  module XOauth2
    TOKEN_FILE = File.expand_path("../../data/x_tokens.json", __dir__)
    module_function

    def b64url(bin) = Base64.strict_encode64(bin).tr("+/", "-_").delete("=")

    def pkce_pair
      verifier  = b64url(SecureRandom.random_bytes(32))
      challenge = b64url(Digest::SHA256.digest(verifier))
      [verifier, challenge]
    end

    def save_tokens!(h)
      FileUtils.mkdir_p(File.dirname(TOKEN_FILE))
      h["obtained_at"] = Time.now.to_i
      File.write(TOKEN_FILE, JSON.pretty_generate(h))
    end

    def load_tokens = JSON.parse(File.read(TOKEN_FILE)) rescue {}

    def authorize_url(state:, challenge:, redirect_uri:)
      cid   = ENV.fetch("X_CLIENT_ID")
      scope = ENV["X_SCOPES"] || "tweet.read tweet.write users.read offline.access"
      "https://twitter.com/i/oauth2/authorize" \
        "?response_type=code" \
        "&client_id=#{CGI.escape(cid)}" \
        "&redirect_uri=#{CGI.escape(redirect_uri)}" \
        "&scope=#{CGI.escape(scope)}" \
        "&state=#{state}" \
        "&code_challenge=#{challenge}" \
        "&code_challenge_method=S256"
    end

    # --- ここを強化：Basic あり/なし両方で自動試行 ---
    def token_post!(form_body, use_basic:)
      conn = Faraday.new(url: "https://api.twitter.com") do |f|
        f.request :url_encoded
        f.adapter :net_http
        f.options.timeout = (ENV["X_HTTP_TIMEOUT"] || "60").to_i
        f.options.open_timeout = (ENV["X_HTTP_OPEN_TIMEOUT"] || "10").to_i
      end
      res = conn.post("/2/oauth2/token") do |r|
        r.headers["Content-Type"] = "application/x-www-form-urlencoded"
        if use_basic
          cid = ENV.fetch("X_CLIENT_ID")
          csec = ENV.fetch("X_CLIENT_SECRET")
          r.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{cid}:#{csec}")}"
        end
        r.body = form_body
      end
      res
    end

    def exchange_code!(code:, verifier:, redirect_uri:)
      cid = ENV.fetch("X_CLIENT_ID")
      form = URI.encode_www_form({
        client_id: cid,
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: verifier
      })

      # 1) .env に X_CLIENT_SECRET があればまず Basic 付きで試す（Confidential想定）
      # 2) 401/unauthorized_client なら Basic なしでもう一度（Public想定）
      tried_basic = !ENV["X_CLIENT_SECRET"].to_s.empty?
      order = tried_basic ? [true, false] : [false, true]

      last_res = nil
      order.each do |use_basic|
        res = token_post!(form, use_basic: use_basic)
        last_res = res
        if res.success?
          tok = JSON.parse(res.body)
          save_tokens!(tok)
          return tok
        end

        # 401 unauthorized_client で Basic が合っていなさそうなら次の試行へ
        begin
          err = JSON.parse(res.body)
          code = err["error"] || err.dig("errors", 0, "code")
        rescue
          code = nil
        end
        if res.status == 401 && code.to_s.include?("unauthorized_client")
          next
        else
          break
        end
      end

      raise "token exchange error: #{last_res.status} #{last_res.body}"
    end

    def refresh_if_needed!
      tok = load_tokens
      raise "no oauth2 tokens. run bin/x_auth first." if tok.empty?
      exp = tok["expires_in"].to_i
      return tok["access_token"] if Time.now.to_i < tok["obtained_at"].to_i + exp - 120

      cid = ENV.fetch("X_CLIENT_ID")
      form = URI.encode_www_form({
        client_id: cid,
        grant_type: "refresh_token",
        refresh_token: tok.fetch("refresh_token")
      })

      # 更新時も Basic あり/なしを自動切替
      order = !ENV["X_CLIENT_SECRET"].to_s.empty? ? [true, false] : [false, true]
      last_res = nil
      order.each do |use_basic|
        res = token_post!(form, use_basic: use_basic)
        last_res = res
        if res.success?
          nt = JSON.parse(res.body)
          save_tokens!(nt)
          return nt["access_token"]
        end
        if res.status == 401
          next
        else
          break
        end
      end
      raise "token refresh error: #{last_res.status} #{last_res.body}"
    end
  end
end