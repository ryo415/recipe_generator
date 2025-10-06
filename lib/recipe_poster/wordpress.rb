# frozen_string_literal: true
require "json"
require "faraday"
require "uri"
require_relative "config"

module RecipePoster
  module WordPress
    module_function

    def create_post!(title:, html:, slug:, status: "draft", tag_names: nil, category_names: nil, featured_image_url: nil, featured_media_id: nil)
      tag_ids = ensure_term_ids(Array(tag_names), "tags")
      cat_ids = ensure_term_ids(Array(category_names), "categories")
      if featured_media_id.nil? && featured_image_url
        featured_media_id, _url = upload_media_from_url!(featured_image_url)
      end

      body = {
        title:   title,
        content: html,
        status:  status,
        slug:    slug,
      }
      body[:tags] = tag_ids unless tag_ids.empty?
      body[:categories] = cat_ids unless cat_ids.empty?
      body[:featured_media] = featured_media_id if featured_media_id

      url = "#{Config.wp_base}/wp-json/wp/v2/posts"
      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        r.headers["Content-Type"]  = "application/json"
        r.headers["Accept"]        = "application/json"
        r.body = JSON.dump(body)
      end
      raise "WordPress create error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    def update_post!(post_id, attrs = {})
      url = "#{Config.wp_base}/wp-json/wp/v2/posts/#{post_id}"
      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        r.headers["Content-Type"]  = "application/json"
        r.body = JSON.dump(attrs)
      end
      raise "WordPress update error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    def upload_media_from_bytes!(bytes, filename:, mime:)
      url = "#{Config.wp_base}/wp-json/wp/v2/media"

      http_timeout       = (ENV["WP_HTTP_TIMEOUT"] || "180").to_i
      http_open_timeout  = (ENV["WP_HTTP_OPEN_TIMEOUT"] || "15").to_i
      http_write_timeout = (ENV["WP_HTTP_WRITE_TIMEOUT"] || "180").to_i

      conn = Faraday.new do |f|
        f.request :url_encoded
        f.adapter :net_http
        f.options.timeout       = http_timeout
        f.options.open_timeout  = http_open_timeout
        f.options.read_timeout  = http_timeout
        f.options.write_timeout = http_write_timeout
      end

      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        r.headers["Content-Type"]  = mime
        r.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
        r.body = bytes
      end
      raise "WordPress media error: #{res.status} #{res.body}" unless res.success?
      json = JSON.parse(res.body)
      [json["id"], json["source_url"]]
    end

    def upload_media_from_url!(image_url)
      # 簡易実装：URLそのまま fetch → bytes アップ（リモートDL不可の環境なら Faraday 経由）
      resp = Faraday.get(image_url)
      raise "Fetch image failed: #{resp.status}" unless resp.success?
      guessed_mime = mime || (image_url.downcase.end_with?(".png") ? "image/png" : "image/jpeg")
      fname = filename || File.basename(URI.parse(image_url).path.presence || "image.jpg")
      upload_media_from_bytes!(resp.body, filename: fname, mime: guessed_mime)
    end

    def set_featured_media!(post_id, media_id)
      update_post!(post_id, { featured_media: media_id })
    end

    def strip_step_prefix(s)
      s.to_s.strip.sub(
        /\A\s*(?:第?\s*[0-9０-９]+|[0-9０-９]+|[①②③④⑤⑥⑦⑧⑨⑩]|(?:step|STEP|手順|ステップ)\s*[0-9０-９]+|\(?\s*[0-9０-９]+\)?)[:：\.\．、，\)\-–—・]?\s*/,
        ""
      )
    end

    def get_by_slug(slug)
      url = "#{Config.wp_base}/wp-json/wp/v2/posts?slug=#{URI.encode_www_form_component(slug)}"
      res = Faraday.get(url) { |r| r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}" }
      raise "WordPress get error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)
    end

    def ensure_tag_ids(names)
      Array(names).map { |n| ensure_single_tag_id(n) }.compact.uniq
    end

    def ensure_single_tag_id(name)
      clean = name.to_s.gsub(/^#/, "").strip
      return nil if clean.empty?

      # 既存検索（完全一致優先）
      search_url = "#{Config.wp_base}/wp-json/wp/v2/tags?search=#{URI.encode_www_form_component(clean)}&per_page=100"
      search_res = Faraday.get(search_url) { |r| r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}" }
      raise "WordPress tag search error: #{search_res.status} #{search_res.body}" unless search_res.success?
      list = JSON.parse(search_res.body)
      exact = list.find { |t| t["name"].casecmp?(clean) }
      return exact["id"] if exact

      # なければ作成
      create_res = Faraday.post("#{Config.wp_base}/wp-json/wp/v2/tags") do |r|
        r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        r.headers["Content-Type"]  = "application/json"
        r.body = JSON.dump({ name: clean })
      end

      if create_res.success?
        JSON.parse(create_res.body)["id"]
      else
        body = JSON.parse(create_res.body) rescue {}
        # 既存重複（term_exists）は data.term_id に既存IDが返る
        if create_res.status == 400 && body["code"] == "term_exists" && body.dig("data", "term_id")
          body.dig("data", "term_id")
        else
          raise "WordPress tag create error: #{create_res.status} #{create_res.body}"
        end
      end
    end

    def ensure_term_ids(names, taxonomy)
      names = names.map { |n| n.to_s.strip }.reject(&:empty?).uniq
      return [] if names.empty?
      names.map do |name|
        found = find_term_by_name(name, taxonomy)
        found ? found["id"] : create_term(name, taxonomy)["id"]
      end
    end

    def find_term_by_name(name, taxonomy)
      url = "#{Config.wp_base}/wp-json/wp/v2/#{taxonomy}?search=#{URI.encode_www_form_component(name)}&per_page=100"
      res = Faraday.get(url) { |r| r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}" }
      return nil unless res.success?
      arr = JSON.parse(res.body)
      # 完全一致優先（大文字小文字を無視）、なければ先頭
      arr.find { |t| t["name"].downcase == name.downcase } || arr.first
    end

    def create_term(name, taxonomy)
      url = "#{Config.wp_base}/wp-json/wp/v2/#{taxonomy}"
      res = Faraday.post(url) do |r|
        r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        r.headers["Content-Type"]  = "application/json"
        r.body = JSON.dump({ name: name })
      end
      raise "WordPress create term error: #{res.status} #{res.body}" unless res.success?
      JSON.parse(res.body)
    end



    def build_html(recipe, meta)
      ing_lines = recipe["ingredients"].map { |i| "<li>#{i["item"]} – #{i["amount"]}</li>" }.join
      clean_steps = Array(recipe["steps"]).map { |s| strip_step_prefix(s) }
      steps_html  = clean_steps.map { |s| "<li>#{s}</li>" }.join
      tips      = (recipe["tips"] || []).map { |t| "<li>#{t}</li>" }.join
      trivia    = recipe["trivia"].to_s.strip
      trivia_html = if trivia.empty?
        ""
      else
        section = <<~HTML
          <h2>豆知識</h2>
          <p class="rp-trivia">#{trivia}</p>
        HTML
        section.lines.map { |line| "          #{line}" }.join
      end

      # === JSON-LD を構築 ===
      require "json"
      # 画像（必須）：まずは既定を使用。将来は WP で設定したアイキャッチURLに差し替え可。
      image_url = ENV["WP_DEFAULT_IMAGE_URL"] || "#{Config.wp_base}/wp-content/uploads/default-recipe.jpg"

      ingredients = recipe["ingredients"].map { |i| "#{i["item"]} #{i["amount"]}".strip }
      instructions = recipe["steps"].map do |s|
        { "@type" => "HowToStep", "text" => s.to_s.strip }
      end

      total_minutes = recipe["time_minutes"].to_i
      total_iso = "PT#{total_minutes}M" if total_minutes > 0

      nutrition = recipe["nutrition"] || {}
      nutrition_ld = {
        "@type" => "NutritionInformation"
      }

      nutrition_ld["calories"]              = "#{nutrition["kcal"]} kcal" if nutrition["kcal"]
      nutrition_ld["proteinContent"]        = "#{nutrition["protein_g"]} g" if nutrition["protein_g"]
      nutrition_ld["fatContent"]            = "#{nutrition["fat_g"]} g" if nutrition["fat_g"]
      nutrition_ld["carbohydrateContent"]   = "#{nutrition["carb_g"]} g" if nutrition["carb_g"]

      # keywords（カンマ区切り）
      kw = []
      kw << meta[:season] if meta[:season]
      kw << meta[:weather_text] if meta[:weather_text]
      kw += Array(recipe["hashtags"]).map(&:to_s)
      kw << (meta[:meal_ja] || (meta[:meal] == "lunch" ? "昼ごはん" : "夜ごはん"))
      keywords = kw.compact.map(&:strip).reject(&:empty?).uniq.join(", ")

      recipe_ld = {
      "@context" => "https://schema.org",
        "@type"    => "Recipe",
        "name"        => recipe["title"],
        "description" => recipe["summary"],
        "image"       => image_url,
        "author"      => { "@type" => "Organization", "name" => (ENV["SITE_NAME"] || "Mainichi Recipe") },
        "datePublished"      => (meta[:date_iso] || Time.now.utc.iso8601),
        "recipeYield"        => recipe["servings"],
        "totalTime"          => total_iso,
        "recipeIngredient"   => ingredients,
        "recipeInstructions" => instructions,
        "nutrition"          => nutrition_ld,
        "recipeCategory"     => recipe["category"] || (meta[:meal] == "lunch" ? "主菜" : "主菜"),
        "recipeCuisine"      => recipe["cuisine"] || "和食",
        "keywords"           => keywords
      }.compact

      json_ld = JSON.pretty_generate(recipe_ld)

      <<~HTML
      <div class="rp-card">
        <script type="application/ld+json">#{json_ld}</script>

          <h2>概要</h2>
          <p>#{recipe["summary"]}</p>
#{trivia_html}
          <ul class="rp-meta">
          <li>想定人数: #{recipe["servings"]}人分</li>
            <li>調理時間: 約#{recipe["time_minutes"]}分</li>
            <li>天気: #{meta[:weather_text]}（降水確率#{meta[:pop]}%） / 最高#{meta[:tmax]}℃ 最低#{meta[:tmin]}℃ / 季節: #{meta[:season]}</li>
            </ul>

          <h2>材料</h2>
          <ul class="rp-ingredients">#{ing_lines}</ul>

          <h2>作り方</h2>
          <ol class="rp-steps">#{steps_html}</ol>

          <h2>栄養の目安（1人分）</h2>
          <ul class="rp-nutrition">
          <li>エネルギー: #{recipe.dig("nutrition","kcal")} kcal</li>
            <li>たんぱく質: #{recipe.dig("nutrition","protein_g")} g</li>
            <li>脂質: #{recipe.dig("nutrition","fat_g")} g</li>
            <li>炭水化物: #{recipe.dig("nutrition","carb_g")} g</li>
            </ul>

          <h2>コツ・補足</h2>
          <ul class="rp-tips">#{tips}</ul>

          </div>
        HTML
    end

    # 指定スラッグが既に使われているか（post / page をチェック）
    def slug_taken?(slug)
      enc = URI.encode_www_form_component(slug)
      headers = { "Authorization" => "Basic #{Config.wp_basic_auth}" }
      # posts
      u1 = "#{Config.wp_base}/wp-json/wp/v2/posts?slug=#{enc}&_fields=id&per_page=1"
      r1 = Faraday.get(u1) { |r| headers.each { |k,v| r.headers[k]=v } }
      if r1.success? && JSON.parse(r1.body).is_a?(Array) && !JSON.parse(r1.body).empty?
        return true
      end
      # pages（同スラッグの固定ページがあると URL 競合し得るので念のため）
      u2 = "#{Config.wp_base}/wp-json/wp/v2/pages?slug=#{enc}&_fields=id&per_page=1"
      r2 = Faraday.get(u2) { |r| headers.each { |k,v| r.headers[k]=v } }
      r2.success? && JSON.parse(r2.body).is_a?(Array) && !JSON.parse(r2.body).empty?
    rescue
      false
    end

    def ensure_terms!(type, names)
      names = Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return [] if names.empty?
      endpoint = type == :tag ? "tags" : "categories"
      ids = []
      names.each do |name|
        # 既存検索
        q = Faraday.get("#{Config.wp_base}/wp-json/wp/v2/#{endpoint}?search=#{URI.encode_www_form_component(name)}") do |r|
          r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
        end
        raise "WordPress term search error: #{q.status} #{q.body}" unless q.success?
        arr = JSON.parse(q.body)
        hit = arr.find { |t| t["name"].to_s == name }
        if hit
          ids << hit["id"]
        else
          # 作成
          create = Faraday.post("#{Config.wp_base}/wp-json/wp/v2/#{endpoint}") do |r|
            r.headers["Authorization"] = "Basic #{Config.wp_basic_auth}"
            r.headers["Content-Type"]  = "application/json"
            r.body = JSON.dump({ name: name })
          end
          raise "WordPress term create error: #{create.status} #{create.body}" unless create.success?
          ids << JSON.parse(create.body)["id"]
        end
      end
      ids
    end
  end
end
