# frozen_string_literal: true
require "date"
require "rufus-scheduler"
require "digest"
require_relative "config"
require_relative "weather"
require_relative "llm"
require_relative "wordpress"
require_relative "x_poster"
require_relative "history"
require_relative "image_gen"

module RecipePoster
  module Run
    module_function

    def once(meal)
      lat, lon = Config.coords
      forecast = Weather.fetch_daily(lat, lon, tz: Config.tz)
      weather_text = Weather.code_to_text(forecast[:code])
      season = Weather.season_for(forecast[:date])

      recent = History.recent(days: 14, meal: meal)
      avoid = {
        titles:      recent.map { |e| e["title"] }.compact,
        ingredients: recent.map { |e| e["primary_ingredient"] }.compact,
        methods:     recent.map { |e| e["method"] }.compact
      }

      model = Config.models[:model]
      # recipe = LLM.generate_recipe(forecast: forecast, meal: meal, model: model)
      recipe = LLM.generate_recipe_diverse(forecast: forecast, meal: meal, model: model, avoid: avoid)

      title = recipe["title"]
      date = Date.parse(forecast[:date]).strftime("%Y-%m-%d")
      # slug = "#{date}-#{meal}-#{title.gsub(/[^\p{Alnum}]+/,'-').downcase}"[0,80]
      slug = build_short_slug(meal: meal, recipe: recipe, max_len: 40)

      existing = WordPress.get_by_slug(slug)

      html = WordPress.build_html(recipe, {
        season: season,
        weather_text: weather_text,
        pop: forecast[:pop],
        tmax: forecast[:tmax],
        tmin: forecast[:tmin]
      })

      # 生成画像を作ってWPへアップロード
      media_id, hero_url = nil, nil
      begin
        media_id, hero_url = ImageGen.generate_and_upload!(recipe: recipe, season: season, weather_text: weather_text, size: ENV["IMG_SIZE"])
      rescue => e
        warn "[WARN] image generation failed: #{e.class}: #{e.message}"
        if (fallback = ENV["DEFAULT_IMAGE_URL"] || ENV["WP_DEFAULT_IMAGE_URL"])
          media_id, hero_url = RecipePoster::WordPress.upload_media_from_url!(fallback)
        end
      end

      # 本文の先頭に <figure> を差し込む（生成成功時のみ）
      if hero_url
        hero_html = %Q{<figure class="rp-hero"><img src="#{hero_url}" alt="#{recipe["title"]} 完成イメージ" loading="lazy" decoding="async"></figure>}
        html = hero_html + "\n" + html
      end

      tags = Array(recipe["hashtags"]).map { |h| h.to_s.sub(/^#/, "") }.reject(&:empty?).uniq
      tags |= [season, weather_text].compact

      cats = [(meal == "lunch" ? "昼ごはん" : "夜ごはん")]

      post = if existing.is_a?(Array) && !existing.empty?
                p = existing.first
                # 既存記事で featured が未設定なら後付け
                if media_id && (p["featured_media"].to_i <= 0)
                  RecipePoster::WordPress.set_featured_media!(p["id"], media_id)
                  # 反映後の情報を取り直す
                  p = RecipePoster::WordPress.get_by_slug(slug).first || p
                end
                p
              else
                WordPress.create_post!(
                  title: title,
                  html: html,
                  slug: slug,
                  status: "publish",
                  tag_names: tags,                 # 既存のタグ配列
                  category_names: cats,            # 既存のカテゴリ配列
                  featured_media_id: media_id      # ★ 同じ画像をアイキャッチに
                )
              end

      RecipePoster::History.record!(
        "meal" => meal,
        "title" => title,
        "primary_ingredient" => recipe["primary_ingredient"],
        "method" => recipe["method"],
        "category" => recipe["category"],
        "season" => season
      )

      link = post["link"] || post.dig("guid","rendered") || "#{Config.wp_base}/?p=#{post["id"]}"
      meal_ja = (meal == "lunch" ? "昼" : "夜")
      d = Date.parse(forecast[:date]).strftime("%-m/%-d")


      hashtags = Array(recipe["hashtags"]).map { |h| h.to_s.sub(/^#/, "") }
      hashtags |= [season, weather_text].compact
      tags_for_x = build_x_hashtags(recipe["hashtags"], season: season, weather_text: weather_text)

      tweet = "本日の#{meal_ja}（#{d}・#{weather_text}・#{forecast[:tmax]}℃/#{forecast[:tmin]}℃）\n#{title}\n#{link}"
      tweet = "#{tweet}\n#{tags_for_x}" unless tags_for_x.empty?

      begin
        if hero_url
          RecipePoster::XPoster.post_tweet_with_image!(tweet, hero_url)
        else
          RecipePoster::XPoster.post_tweet!(tweet)
        end
      rescue => e
        warn "[WARN] X post failed: #{e.class}: #{e.message}"
      end

      puts "[OK] #{meal} -> WP: #{link}"
    end

    # base が重複していたら -2, -3... を試し、それでもダメなら極小IDを付加
    def ensure_unique_slug(base, max_len: 32)
      cand = ascii_slugify(base)[0, max_len]
      return cand unless WordPress.slug_taken?(cand)
      (2..9).each do |n|
        s = ascii_slugify("#{base}-#{n}")[0, max_len]
        return s unless WordPress.slug_taken?(s)
      end
      # 極小ID（時刻base36の末尾2桁 + ランダム1桁）で短く衝突回避
      tiny = (Time.now.to_i.to_s(36)[-2,2] + rand(36).to_s(36))
      s = ascii_slugify("#{base}-#{tiny}")[0, max_len]
      return s unless WordPress.slug_taken?(s)
      # 最後の保険
      s + "-x"
    end

    # 文字列を英数字・ハイフンだけに
    def ascii_slugify(s)
      s.to_s.downcase
        .gsub(/[^a-z0-9]+/, "-")
        .gsub(/-+/, "-")
        .gsub(/\A-|-+\z/, "")
    end

    def build_short_slug(meal:, recipe:, max_len: 40)
      tokens = []

      # 1) LLMが返す英語トークン群（プロンプトで出させると◎）
      raw = recipe["slug_tokens_en"]
      tokens += Array(raw).flat_map { |v| v.to_s.split(/[,\s]+/) }

      # 2) レシピのハッシュタグから英字だけ拾う
      tags_en = Array(recipe["hashtags"]).map(&:to_s).map { |h| h.sub(/^#/, "") }
                  .select { |t| t.match?(/\A[a-z0-9][a-z0-9\-]*\z/i) }
      tokens += tags_en

      # 3) 主材料・調理法など（英字のみ拾う）
      %w[primary_ingredient method category].each do |k|
        v = recipe[k]
        tokens << v if v && v.to_s.match?(/\A[a-z0-9][a-z0-9\-]*\z/i)
      end

      tokens = tokens.map { |t| ascii_slugify(t) }.reject(&:empty?).uniq
      base = ([meal[0]] + tokens).join("-") # 例: "d-cold-pasta"
      slug = ensure_unique_slug(base, max_len: max_len)

      # 4) すべて空ならフォールバック： meal頭文字 + 短いハッシュ
      if slug.nil? || slug.empty?
        digest = Digest::SHA1.hexdigest(recipe["title"].to_s)[0, 6]
        slug = "#{meal[0]}-#{digest}"
      end
      slug
    end

    def hashtagify(str)
      core = str.to_s.sub(/^#/, "")
      core = core.gsub(/[^\p{Hiragana}\p{Katakana}\p{Han}A-Za-z0-9_ー]+/, "")
      return nil if core.empty?
      "##{core}"
    end

    def build_x_hashtags(list, season:, weather_text:)
      base = Array(list).map(&:to_s)
      base |= [season, weather_text].compact # メタ情報もタグ化
      tokens = base.map { |x| normalize_hashtag_token(x) }.reject(&:empty?).uniq
      max = (ENV["X_MAX_HASHTAGS"] || "4").to_i
      tokens.first(max).map { |w| "##{w}" }.join(" ")
    end

    def pack_tweet(body, tags, limit: 280)
      text = [body, tags.join(" ")].reject(&:empty?).join("\n")
      return text if text.length <= limit
      pruned = tags.dup
      while pruned.any?
        text = [body, pruned.join(" ")].reject(&:empty?).join("\n")
        return text if text.length <= limit
        pruned.pop
      end
      body[0, limit - 1] + "…"
    end

    # 日本語対応のハッシュタグ正規化
    # 先頭の # を外し、空白を除去、ハッシュタグを壊す記号のみ削除
    def normalize_hashtag_token(s)
      t = s.to_s.strip.sub(/^#/, "")
      # 空白類は除去（スペースがあるとそこでタグが切れる）
      t = t.gsub(/\s+/, "").gsub(/\u3000+/, "") # \u3000 = 全角空白
      # 許可する文字だけ残す：英数・全角英数・アンダースコア・ひらがな・カタカナ・漢字・長音・々・ゝゞ・ヽヾ
      allowed = /[0-9A-Za-z_\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u30FC\u3005\u309D\u309E\u30FD\u30FE]/u
      t = t.each_char.select { |ch| ch.match?(allowed) }.join
      t
    end

    def schedule
      scheduler = Rufus::Scheduler.new
      scheduler.cron "0 12 * * * Asia/Tokyo" do
        once("lunch")
      end
      scheduler.cron "0 18 * * * Asia/Tokyo" do
        once("dinner")
      end
      puts "Scheduler started (12:00 / 18:00 JST). Press Ctrl+C to exit."
      scheduler.join
    end
  end
end
