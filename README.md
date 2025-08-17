# Recipe Poster (Ruby)

天気・気温・季節からレシピをAIで自動生成し、WordPressに投稿、Xへ要約ポストする自動化ツール。

## セットアップ

```bash
git clone <this-project>
cd recipe_poster_ruby
bundle install
cp config/.env.example .env
# .env を編集
```

## 実行例

```bash
# 1回だけ昼
bundle exec ruby bin/recipe_poster once lunch

# 1回だけ夜
bundle exec ruby bin/recipe_poster once dinner

# スケジュール（常駐: 12:00 / 18:00 JST）
bundle exec ruby bin/recipe_poster schedule
```

## 構成

- `lib/recipe_poster/config.rb` … 環境変数の読み出し
- `lib/recipe_poster/weather.rb` … Open-Meteoから予報取得
- `lib/recipe_poster/llm.rb` … レシピ生成（Gemini / OpenAI 切替）
- `lib/recipe_poster/wordpress.rb` … WordPress REST API クライアント
- `lib/recipe_poster/x_poster.rb` … X /2/tweets 投稿
- `lib/recipe_poster/run.rb` … 実行フロー（once / schedule）
- `bin/recipe_poster` … CLI エントリ
