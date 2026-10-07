module Invidious::Frontend::WatchPage
  extend self

  private DEFAULT_DOWNLOAD_HEIGHT  =    720
  private DEFAULT_DOWNLOAD_BITRATE = 58_000

  # A handy structure to pass many elements at
  # once to the download widget function
  struct VideoAssets
    getter full_videos : Array(Hash(String, JSON::Any))
    getter video_streams : Array(Hash(String, JSON::Any))
    getter audio_streams : Array(Hash(String, JSON::Any))
    getter captions : Array(Invidious::Videos::Captions::Metadata)

    def initialize(
      @full_videos,
      @video_streams,
      @audio_streams,
      @captions,
    )
    end
  end

  def download_widget(locale : String, video : Video, video_assets : VideoAssets) : String
    if CONFIG.disabled?("downloads")
      return "<p id=\"download\">#{I18n.translate(locale, "Download is disabled")}</p>"
    end

    if CONFIG.dmca_content.includes?(video.id)
      return "<p id=\"download\">#{I18n.translate(locale, "dmca_content")}</p>"
    end

    url = "/download"
    if (CONFIG.invidious_companion.present?)
      invidious_companion = CONFIG.invidious_companion.sample
      url = "#{invidious_companion.public_url}/download?check=#{invidious_companion_encrypt(video.id)}"
    end

    merged_download = Invidious::Videos::MergedDownload.available? &&
                      !video_assets.video_streams.empty? &&
                      video_assets.audio_streams.any? { |option| Invidious::Videos::MergedDownload.mergeable_audio?(option) }

    # The overlay and its tabs are toggled by inputs to work without javascript
    return String.build(8000) do |str|
      str << "<div id=\"download\" class=\"download-widget\">\n"

      str << "<input type=\"checkbox\" id=\"download-overlay-toggle\" class=\"download-overlay-toggle\" autocomplete=\"off\"/>\n"
      str << "<label for=\"download-overlay-toggle\" class=\"pure-button pure-button-primary\">\n"
      str << "\t<b>" << I18n.translate(locale, "Download") << "</b>\n"
      str << "</label>\n"

      str << "<div class=\"download-overlay\" role=\"dialog\" aria-modal=\"true\""
      str << " aria-label=\"" << I18n.translate(locale, "Download") << "\">\n"
      str << "<label for=\"download-overlay-toggle\" class=\"download-overlay-backdrop\"></label>\n"
      str << "<div class=\"download-overlay-panel\">\n"

      if merged_download
        str << "<input type=\"radio\" name=\"download-tab\" id=\"download-tab-merged\" class=\"download-tab-toggle\" checked/>\n"
        str << "<input type=\"radio\" name=\"download-tab\" id=\"download-tab-raw\" class=\"download-tab-toggle\"/>\n"
      end

      str << "<div class=\"download-overlay-header\">\n"
      if merged_download
        str << "\t<div class=\"download-tabs\">\n"
        str << "\t\t<label for=\"download-tab-merged\">" << I18n.translate(locale, "Download") << "</label>\n"
        str << "\t\t<label for=\"download-tab-raw\">" << I18n.translate(locale, "download_tab_raw") << "</label>\n"
        str << "\t</div>\n"
      else
        str << "\t<h3>" << I18n.translate(locale, "Download") << "</h3>\n"
      end
      str << "\t<label for=\"download-overlay-toggle\" class=\"download-overlay-close\""
      str << " title=\"" << I18n.translate(locale, "download_overlay_close") << "\">"
      str << "<i class=\"icon ion-ios-close\"></i></label>\n"
      str << "</div>\n"

      if merged_download
        str << "<div class=\"download-tab download-tab-merged\">\n"
        merged_download_form(str, locale, video, video_assets)
        str << "</div>\n"
        str << "<div class=\"download-tab download-tab-raw\">\n"
        single_download_form(str, locale, video, video_assets, url)
        str << "</div>\n"
      else
        single_download_form(str, locale, video, video_assets, url)
      end

      str << "</div>\n" # .download-overlay-panel
      str << "</div>\n" # .download-overlay
      str << "</div>\n" # .download-widget
    end
  end

  private def merged_download_form(str : String::Builder, locale : String, video : Video, video_assets : VideoAssets)
    str << "<form"
    str << " class=\"pure-form pure-form-stacked download-form\""
    str << " action='/download/merged'"
    str << " method='post'"
    str << " rel='noopener noreferrer'"
    str << " target='_blank'>\n"

    str << "<fieldset>\n"
    str << "\t<input type='hidden' name='id' value='" << video.id << "'/>\n"

    # H.264 is preferred for compatibility

    default_video = video_assets.video_streams.min_by do |option|
      height = option["height"]?.try &.as_i? || 0
      mp4 = option["mimeType"].as_s.starts_with?("video/mp4")
      {(height - DEFAULT_DOWNLOAD_HEIGHT).abs, mp4 ? 0 : 1, option["fps"]?.try &.as_i? || 0}
    end

    str << "\t<div class=\"pure-control-group\">\n"
    str << "\t\t<label for='download_merged_video'>" << I18n.translate(locale, "download_merged_video") << "</label>\n"
    str << "\t\t<select name='video_itag' id='download_merged_video'>\n"

    video_assets.video_streams.each do |option|
      mimetype = option["mimeType"].as_s.split(";")[0]

      str << "\t\t\t<option value='" << option["itag"] << "'"
      str << " data-height='" << (option["height"]?.try &.as_i? || 0) << "'"
      str << " data-fps='" << (option["fps"]?.try &.as_i? || 0) << "'"
      str << " data-codec='" << codec_name(option["mimeType"].as_s) << "'"
      str << " selected" if option.same?(default_video)
      str << ">"
      str << option["qualityLabel"] << " - " << mimetype
      str << " (" << codec_name(option["mimeType"].as_s) << ") @ " << option["fps"] << "fps"
      str << " - " << (option["bitrate"]?.try &.as_i.// 1000) << "k"
      file_size(str, option)
      str << "</option>\n"
    end

    str << "\t\t</select>\n"
    str << "\t</div>\n"

    audio_streams = video_assets.audio_streams.select { |option| Invidious::Videos::MergedDownload.mergeable_audio?(option) }

    default_audio = audio_streams.min_by? do |option|
      ((option["bitrate"]?.try &.as_i? || 0) - DEFAULT_DOWNLOAD_BITRATE).abs
    end

    str << "\t<div class=\"pure-control-group\">\n"
    str << "\t\t<label for='download_merged_audio'>" << I18n.translate(locale, "download_merged_audio") << "</label>\n"
    str << "\t\t<select name='audio_itag' id='download_merged_audio'>\n"

    audio_streams.each do |option|
      mimetype = option["mimeType"].as_s.split(";")[0]

      str << "\t\t\t<option value='" << option["itag"] << "'"
      str << " data-bitrate='" << (option["bitrate"]?.try &.as_i? || 0) << "'"
      str << " data-codec='" << codec_name(option["mimeType"].as_s) << "'"
      str << " selected" if option.same?(default_audio)
      str << ">"
      str << mimetype << " (" << codec_name(option["mimeType"].as_s) << ")"
      str << " @ " << (option["bitrate"]?.try &.as_i.// 1000) << "k"
      if display_name = option["audioTrack"]?.try &.["displayName"]?.try &.as_s?
        str << " - " << HTML.escape(display_name)
      end
      file_size(str, option)
      str << "</option>\n"
    end

    str << "\t\t</select>\n"
    str << "\t</div>\n"

    if !video_assets.captions.empty?
      str << "\t<fieldset class=\"download-captions\">\n"
      str << "\t\t<legend>\n"
      str << "\t\t\t<span>" << I18n.translate(locale, "download_merged_subtitles") << "</span>\n"

      # Shown by download_widget.js
      if video_assets.captions.size > 1
        filter_label = I18n.translate(locale, "download_merged_subtitles_filter")
        str << "\t\t\t<span class=\"download-captions-filter\" hidden><span>"
        str << "<input type=\"search\" placeholder=\"" << filter_label << "\" aria-label=\"" << filter_label << "\"/>"
        str << "<button type=\"button\" title=\"" << I18n.translate(locale, "download_merged_subtitles_filter_clear") << "\">"
        str << "<i class=\"icon ion-ios-close\"></i></button>"
        str << "</span></span>\n"

        str << "\t\t\t<span class=\"download-captions-select\" hidden>"
        str << "<button type=\"button\" data-download-captions=\"all\">"
        str << I18n.translate(locale, "download_merged_subtitles_all") << "</button>"
        str << " / "
        str << "<button type=\"button\" data-download-captions=\"none\">"
        str << I18n.translate(locale, "download_merged_subtitles_none") << "</button>"
        str << "</span>\n"
      end

      str << "\t\t</legend>\n"
      str << "\t\t<div class=\"download-captions-list\">\n"

      manual_captions, auto_captions = video_assets.captions.partition { |caption| !caption.auto_generated }

      (manual_captions + auto_captions).each_with_index do |caption, i|
        str << "\t\t\t<label for='download_caption_" << i << "' class=\"pure-checkbox\">"
        str << "<input type='checkbox' name='caption' id='download_caption_" << i << "'"
        str << " value='" << HTML.escape(caption.name) << "'"
        str << " data-language='" << HTML.escape(caption.language_code) << "'"
        str << " data-auto='" << caption.auto_generated << "'/> "
        str << I18n.translate(locale, caption.name.rchop(" (auto-generated)"))
        if caption.auto_generated
          str << " <span class=\"download-captions-badge\" title=\""
          str << I18n.translate(locale, "download_merged_subtitles_auto_title") << "\">"
          str << I18n.translate(locale, "download_merged_subtitles_auto") << "</span>"
        end
        str << "</label>\n"
      end

      str << "\t\t</div>\n"
      str << "\t</fieldset>\n"
    end

    str << "\t<button type=\"submit\" class=\"pure-button pure-button-primary\">\n"
    str << "\t\t<b>" << I18n.translate(locale, "Download") << "</b>\n"
    str << "\t</button>\n"

    str << "</fieldset>\n"
    str << "</form>\n"
  end

  private def single_download_form(str : String::Builder, locale : String, video : Video, video_assets : VideoAssets, url : String)
    str << "<form"
    str << " class=\"pure-form pure-form-stacked download-form\""
    str << " action='" << HTML.escape(url) << "'"
    str << " method='post'"
    str << " rel='noopener noreferrer'"
    str << " target='_blank'>"
    str << '\n'

    str << "<fieldset>\n"

    # Hidden inputs for video id and title
    str << "<input type='hidden' name='id' value='" << video.id << "'/>\n"
    str << "<input type='hidden' name='title' value='" << HTML.escape(video.title) << "'/>\n"

    str << "\t<div class=\"pure-control-group\">\n"

    str << "\t\t<label for='download_widget'>"
    str << I18n.translate(locale, "Download as: ")
    str << "</label>\n"

    str << "\t\t<select name='download_widget' id='download_widget'>\n"

    # Non-DASH videos (audio+video)

    video_assets.full_videos.each do |option|
      mimetype = option["mimeType"].as_s.split(";")[0]

      height = Invidious::Videos::Formats.itag_to_metadata?(option["itag"]).try &.["height"]?

      value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

      str << "\t\t\t<option value='" << value << "'>"
      str << (height || "~240") << "p - " << mimetype
      file_size(str, option)
      str << "</option>\n"
    end

    # DASH video streams

    video_assets.video_streams.each do |option|
      mimetype = option["mimeType"].as_s.split(";")[0]

      value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

      str << "\t\t\t<option value='" << value << "'>"
      str << option["qualityLabel"] << " - " << mimetype << " @ " << option["fps"] << "fps - video only"
      file_size(str, option)
      str << "</option>\n"
    end

    # DASH audio streams

    video_assets.audio_streams.each do |option|
      mimetype = option["mimeType"].as_s.split(";")[0]

      value = {"itag": option["itag"], "ext": mimetype.split("/")[1]}.to_json

      str << "\t\t\t<option value='" << value << "'>"
      str << mimetype << " @ " << (option["bitrate"]?.try &.as_i./ 1000) << "k - audio only"
      file_size(str, option)
      str << "</option>\n"
    end

    # Subtitles (a.k.a "closed captions")

    video_assets.captions.each do |caption|
      value = {"label": caption.name, "ext": "#{caption.language_code}.vtt"}.to_json

      str << "\t\t\t<option value='" << value << "'>"
      str << I18n.translate(locale, "download_subtitles", I18n.translate(locale, caption.name))
      str << "</option>\n"
    end

    # End of form

    str << "\t\t</select>\n"
    str << "\t</div>\n"

    str << "\t<button type=\"submit\" class=\"pure-button pure-button-primary\">\n"
    str << "\t\t<b>" << I18n.translate(locale, "Download") << "</b>\n"
    str << "\t</button>\n"

    str << "</fieldset>\n"
    str << "</form>\n"
  end

  private def file_size(str : String::Builder, option : Hash(String, JSON::Any))
    bytes = option["contentLength"]?.try &.as_s?.try &.to_i64?
    return if bytes.nil?

    megabytes = bytes / 1024 / 1024
    if megabytes >= 1024
      str << " - " << (megabytes / 1024).round(1) << " GB"
    elsif megabytes >= 10
      str << " - " << megabytes.round.to_i << " MB"
    else
      str << " - " << megabytes.round(1) << " MB"
    end
  end

  private def codec_name(mime_type : String) : String
    codec = mime_type.match(/codecs="([^".]+)/).try &.[1]

    case codec
    when "avc1"        then "H.264"
    when "vp9", "vp09" then "VP9"
    when "av01"        then "AV1"
    when "mp4a"        then "AAC"
    when "opus"        then "Opus"
    when nil           then "?"
    else                    codec
    end
  end
end
