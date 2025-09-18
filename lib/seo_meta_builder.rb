# frozen_string_literal: true
require "faraday"
require "json"
require "uri"

module SeoMetaBuilder
  module_function

  SITE_NAME = "毎日レシピ"
  CANONICAL_BASE = "https://mainichi-recipe.com" # ←必要なら変更

  def build_meta(title:, html:, slug:, tags: [])
    plain = html_to_text(html)
    desc  = build_description(plain)
    kw    = build_focus_keywords(title: title, text: plain, tags: tags)

    seo_title = build_seo_title(title)

    {
      "rank_math_title"                => seo_title,
      "rank_math_description"          => desc,
      "rank_math_focus_keyword"        => kw.join(", "),
      "rank_math_canonical_url"        => File.join(CANONICAL_BASE, slug.to_s),

      # SNS（必要に応じてアイキャッチURL後で上書き）
      "rank_math_facebook_title"       => seo_title,
      "rank_math_facebook_description" => desc,
      "rank_math_twitter_title"        => seo_title,
      "rank_math_twitter_description"  => desc,
      # "rank_math_facebook_image"     => "https://.../og.jpg",
      # "rank_math_twitter_image"      => "https://.../tw.jpg",
    }
  end

  # --- helpers ---

  def html_to_text(html)
    # ざっくりのHTML→テキスト（依存無し）
    text = html.
      gsub(/<script[\s\S]*?<\/script>/i, " ").
      gsub(/<style[\s\S]*?<\/style>/i, " ").
      gsub(/<br\s*\/?>/i, "。").
      gsub(/<\/p>/i, "。").
      gsub(/<[^>]+>/, " ").
      gsub(/\s+/, " ").
      strip
    # 句点の連打修正
    text.gsub(/。{2,}/, "。")
  end

  def build_seo_title(title)
    # 既に「レシピ」や「作り方」が無ければ付ける
    base = title.dup
    base << " レシピ" unless base.include?("レシピ") || base.include?("作り方")
    # サイト名サフィックス
    composed = "#{base}｜作り方・コツ｜#{SITE_NAME}"
    shrink_japanese(composed, target: 34, min: 28)
  end

  def build_description(text)
    # 最初の2〜3文から 110〜140 文字で自然に切る
    cand = text.split(/。/).take(3).join("。")
    cand = text if cand.length < 80
    trimmed = trim_to_range(cand, min: 110, max: 140)
    # 記号整形
    trimmed.gsub(/[「」『』【】\[\]\(\)]/, "")
  end

  def build_focus_keywords(title:, text:, tags: [])
    # タイトルの主要語
    keys = extract_head_terms(title)
    # 本文の頻出語（ひらがなのみ＆1文字は除外）
    keys |= top_terms(text, top_n: 6)
    # タグ優先
    keys |= Array(tags)
    # 2〜4語に整形
    keys = keys.
      select { |w| w.size >= 2 }.
      reject { |w| w =~ /\A[ぁ-ゖー]+\z/ }[0, 4]
    keys.empty? ? extract_head_terms(title)[0,2] : keys
  end

  def extract_head_terms(s)
    # 記号で分割→漢字/カナ/英語っぽい語を抽出
    s.to_s.split(/[・\s　\-\|｜／\/:：,、。!！?？]+/).
      select { |w| w =~ /[一-龠ァ-ヶｱ-ﾝﾞﾟa-zA-Z0-9]/ }.
      map { |w| w.gsub(/[^\p{Han}\p{Katakana}\p{Hiragana}a-zA-Z0-9]/, "") }.
      reject(&:empty?)
  end

  def top_terms(text, top_n: 6)
    # 超簡易頻度語抽出：全角空白/句読点で分割→ひらがなのみ/1文字語を除外→頻度順
    tokens = text.split(/[、。・\s　\/\|\-,:：!！?？\(\)「」『』【】]/)
    freq = Hash.new(0)
    tokens.each do |t|
      t = t.strip
      next if t.size <= 1
      next if t =~ /\A[ぁ-ゖー]+\z/
      next unless t =~ /[一-龠ァ-ヶｱ-ﾝﾞﾟa-zA-Z]/
      freq[t] += 1
    end
    freq.sort_by { |_, c| -c }.map(&:first).first(top_n)
  end

  def trim_to_range(s, min:, max:)
    return s if s.length.between?(min, max)
    if s.length > max
      out = s[0...max]
      # 文の途中なら直前の句点/読点で止める
      if (i = out.rindex(/[。．、,]/))
        out = out[0..i]
      end
      out = out.sub(/[、,]$/, "。")
      out = out.end_with?("。") ? out : "#{out}…"
      return out
    else
      # 足りないときはそのまま
      s
    end
  end

  def shrink_japanese(s, target:, min:)
    return s if s.length <= target
    # 長い時はサフィックスを短縮
    base = s.sub(/｜作り方・コツ｜#{SITE_NAME}\z/, "｜#{SITE_NAME}")
    return base if base.length <= target
    # それでも長ければ末尾を省略
    base.length > target ? "#{base[0...(target-1)]}…" : base
  end
end

module RankMathPoster
  module_function

  def conn
    @conn ||= Faraday.new do |f|
      f.request :retry, max: 2, interval: 0.5
      f.adapter Faraday.default_adapter
    end
  end

  def auth_headers
    {
      "Authorization" => "Basic #{Config.wp_basic_auth}",
      "Content-Type"  => "application/json"
    }
  end

  # 1) 新規投稿時に Rank Math メタも同時に送る
  def create_post_with_rankmath!(title:, html:, slug:, status: "publish", tags: [])
    meta = SeoMetaBuilder.build_meta(title: title, html: html, slug: slug, tags: tags)

    res = conn.post("#{Config.wp_base}/wp-json/wp/v2/posts") do |r|
      r.headers.update(auth_headers)
      r.body = JSON.dump({
        title: title,
        content: html,
        status: status,
        slug: slug,
        meta: meta
      })
    end
    raise "WP create error: #{res.status} #{res.body}" unless res.success?

    post = JSON.parse(res.body)
    # アイキャッチがあればSNS画像に反映（二度目のPATCH）
    if (fid = post["featured_media"].to_i) > 0
      img_url = fetch_media_url(fid)
      patch_rankmath_images!(post_id: post["id"], img_url: img_url) if img_url
    end
    post
  end

  # 2) 既存記事IDから本文を取得→メタ生成→PATCHで更新
  def update_rankmath_for_post!(post_id:)
    post = get_post(post_id)
    html = post.dig("content","rendered") || ""
    title = post["title"]["rendered"] || ""
    slug  = post["slug"]
    tags  = fetch_tag_names(post["tags"]) # 数値ID→名前

    meta = SeoMetaBuilder.build_meta(title: title, html: html, slug: slug, tags: tags)

    # featured image をSNSにも流用
    if (fid = post["featured_media"].to_i) > 0
      if (img_url = fetch_media_url(fid))
        meta["rank_math_facebook_image"] = img_url
        meta["rank_math_twitter_image"]  = img_url
      end
    end

    patch_meta!(post_id: post_id, meta: meta)
  end

  # --- helpers ---

  def get_post(id)
    res = conn.get("#{Config.wp_base}/wp-json/wp/v2/posts/#{id}") { |r| r.headers.update(auth_headers) }
    raise "WP get error: #{res.status} #{res.body}" unless res.success?
    JSON.parse(res.body)
  end

  def patch_meta!(post_id:, meta:)
    res = conn.post("#{Config.wp_base}/wp-json/wp/v2/posts/#{post_id}") do |r|
      r.headers.update(auth_headers)
      r.body = JSON.dump({ meta: meta })
    end
    raise "WP patch meta error: #{res.status} #{res.body}" unless res.success?
    JSON.parse(res.body)
  end

  def fetch_media_url(media_id)
    res = conn.get("#{Config.wp_base}/wp-json/wp/v2/media/#{media_id}") { |r| r.headers.update(auth_headers) }
    return nil unless res.success?
    JSON.parse(res.body)["source_url"]
  end

  def fetch_tag_names(tag_ids)
    return [] if tag_ids.nil? || tag_ids.empty?
    names = []
    tag_ids.each do |tid|
      res = conn.get("#{Config.wp_base}/wp-json/wp/v2/tags/#{tid}") { |r| r.headers.update(auth_headers) }
      names << JSON.parse(res.body)["name"] if res.success?
    end
    names
  end
end