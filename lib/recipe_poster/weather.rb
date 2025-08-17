# frozen_string_literal: true
require "json"
require "net/http"
require "uri"
require "date"
require_relative "config"

module RecipePoster
  module Weather
    module_function

    def fetch_daily(lat, lon, tz: Config.tz)
      url = URI("https://api.open-meteo.com/v1/forecast"                   "?latitude=\#{lat}&longitude=\#{lon}"                   "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,weathercode"                   "&timezone=\#{URI.encode_www_form_component(tz)}")
      res = Net::HTTP.get_response(url)
      raise "Weather API error: \#{res.code} \#{res.body}" unless res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      daily = data["daily"]
      idx = 0
      {
        date: daily["time"][idx],
        tmax: daily["temperature_2m_max"][idx],
        tmin: daily["temperature_2m_min"][idx],
        pop:  daily["precipitation_probability_max"][idx],
        rain_sum: daily["precipitation_sum"][idx],
        code: daily["weathercode"][idx]
      }
    end

    def code_to_text(code)
      case code.to_i
      when 0 then "快晴"
      when 1,2 then "晴れ"
      when 3 then "くもり"
      when 45,48 then "霧"
      when 51,53,55 then "霧雨"
      when 56,57 then "着氷性霧雨"
      when 61,63,65 then "雨"
      when 66,67 then "凍雨"
      when 71,73,75 then "雪"
      when 80,81,82 then "にわか雨"
      when 85,86 then "にわか雪"
      when 95 then "雷雨"
      when 96,99 then "ひょう"
      else "不明"
      end
    end

    def season_for(date_str)
      m = Date.parse(date_str).month
      case m
      when 3..5 then "春"
      when 6..8 then "夏"
      when 9..11 then "秋"
      else "冬"
      end
    end
  end
end
