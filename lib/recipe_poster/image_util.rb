# frozen_string_literal: true

require_relative "logging"

module RecipePoster
  module ImageUtil
    module_function

    # ---- vips が使えれば最優先（高速・堅牢）----
    def vips_available?
      require "vips"
      true
    rescue LoadError
      false
    end

    def to_webp(bytes, quality: (ENV["WEBP_QUALITY"] || "82"),
                max_dim: (ENV["WEBP_MAX_DIM"] || "1536").to_i)
      return to_webp_vips(bytes, quality: quality.to_i, max_dim: max_dim) if vips_available?
      to_webp_minimagick_file(bytes, quality: quality, max_dim: max_dim)
    end

    def to_jpeg(bytes, quality: (ENV["X_JPEG_QUALITY"] || "85"),
                max_dim: (ENV["X_MAX_DIM"] || "1600").to_i)
      return to_jpeg_vips(bytes, quality: quality.to_i, max_dim: max_dim) if vips_available?
      to_jpeg_minimagick_file(bytes, quality: quality, max_dim: max_dim)
    end

    # ========== ruby-vips 版 ==========
    def to_webp_vips(bytes, quality:, max_dim:)
      img = Vips::Image.new_from_buffer(bytes, "")
      scale = [max_dim.to_f / img.width, max_dim.to_f / img.height, 1.0].min
      img = img.resize(scale) if scale < 1.0
      img.write_to_buffer(".webp", Q: quality, lossless: false)
    end

    def to_jpeg_vips(bytes, quality:, max_dim:)
      img = Vips::Image.new_from_buffer(bytes, "")
      scale = [max_dim.to_f / img.width, max_dim.to_f / img.height, 1.0].min
      img = img.resize(scale) if scale < 1.0
      img.write_to_buffer(".jpg", Q: quality, strip: true)
    end

    # ========== MiniMagick 版（FastImage で寸法判定 → `>` は使わない）==========
    require "tempfile"
    require "fastimage"

    def guess_ext(bytes)
      head = bytes[0, 16] || ""
      return ".png"  if head.start_with?("\x89PNG\r\n\x1A\n".b)
      return ".jpg"  if head.start_with?("\xFF\xD8\xFF".b)
      return ".webp" if head.start_with?("RIFF".b) && bytes[8,4] == "WEBP"
      return ".gif"  if head.start_with?("GIF87a") || head.start_with?("GIF89a")
      ".png"
    end

    def need_resize?(path, max_dim)
      w,h = FastImage.size(path)
      return false unless w && h
      w > max_dim || h > max_dim
    end

    def to_webp_minimagick_file(bytes, quality:, max_dim:)
      require "mini_magick"
      in_ext  = guess_ext(bytes)
      out_ext = ".webp"

      Tempfile.create(["in", in_ext]) do |fi|
        fi.binmode; fi.write(bytes); fi.flush
        Tempfile.create(["out", out_ext]) do |fo|
          fo.close
          tool = MiniMagick::Tool::Convert.new
          tool << fi.path
          tool.resize("#{max_dim}x#{max_dim}") if need_resize?(fi.path, max_dim) # 「>」は使わない
          tool.strip
          tool.quality quality.to_s if quality
          tool << fo.path
          tool.call
          return File.binread(fo.path)
        end
      end
    rescue => e
      Logging.warn("image_util.to_webp_minimagick_file_failed", error: e.class.name, message: e.message)
      bytes
    end

    def to_jpeg_minimagick_file(bytes, quality:, max_dim:)
      require "mini_magick"
      in_ext  = guess_ext(bytes)
      out_ext = ".jpg"

      Tempfile.create(["in", in_ext]) do |fi|
        fi.binmode; fi.write(bytes); fi.flush
        Tempfile.create(["out", out_ext]) do |fo|
          fo.close
          tool = MiniMagick::Tool::Convert.new
          tool << fi.path
          tool.resize("#{max_dim}x#{max_dim}") if need_resize?(fi.path, max_dim) # 「>」は使わない
          tool.strip
          tool.quality quality.to_s if quality
          tool << fo.path
          tool.call
          return File.binread(fo.path)
        end
      end
    rescue => e
      Logging.warn("image_util.to_jpeg_minimagick_file_failed", error: e.class.name, message: e.message)
      bytes
    end
  end
end