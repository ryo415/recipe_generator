# frozen_string_literal: true
require "faraday"
require "json"
require "uri"
require "faraday/retry"
require "config"

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
      "Authorization" => Config.wp_authorization,
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