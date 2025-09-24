# lib/config.rb
# .env を自動ロード（gem 'dotenv' が無ければスキップ）
begin
  require "dotenv/load"
rescue LoadError
  # 何もしない（.env を使わず export でも動く）
end

require "base64"

module Config
  module_function

  # 末尾スラ無しの WP ベースURL（例: https://example.com）
  def wp_base
    fetch_any!("WP_BASE", "WORDPRESS_BASE_URL")
  end

  # 既存コード互換: "Basic <base64>" の <base64> 部分だけ返す
  def wp_basic_auth
    # 1) "WP_BASIC_AUTH" があればそれを使う（"Basic xxx" でも "xxx" でもOK）
    if (tok = ENV["WP_BASIC_AUTH"]) && !tok.empty?
      return tok.sub(/\ABasic\s+/i, "")
    end

    # 2) ユーザ/パスから生成（アプリケーションパスワードやベーシックパス）
    user = fetch_any!("WP_USERNAME", "WP_USER")
    pass = fetch_any!("WP_APP_PASSWORD", "WP_APPLICATION_PASSWORD", "WP_PASSWORD")

    # WordPress Application Password にはスペースが含まれることがありますがそのままでOK
    Base64.strict_encode64("#{user}:#{pass}")
  end

  # 完成形（"Basic <base64>"）を返す版。新規コードはこちら推奨
  def wp_authorization
    tok = ENV["WP_BASIC_AUTH"]
    if tok && !tok.empty?
      return tok.start_with?("Basic ") ? tok : "Basic #{tok}"
    end
    "Basic #{wp_basic_auth}"
  end

  # 使いやすいフェッチ（候補の中から最初に見つかったものを返す）
  def fetch_any!(*keys)
    keys.each do |k|
      v = ENV[k]
      return v if v && !v.empty?
    end
    raise KeyError, %(key not found: #{keys.map{|k| %("#{k}")}.join(" or ")})
  end
end