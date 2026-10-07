require "json"

# Merges a video stream, an audio stream and subtitles without re-encoding
module Invidious::Videos::MergedDownload
  extend self

  enum Container
    MP4
    WebM
    Matroska

    def extension : String
      case self
      in .mp4?      then "mp4"
      in .web_m?    then "webm"
      in .matroska? then "mkv"
      end
    end

    def mime_type : String
      case self
      in .mp4?      then "video/mp4"
      in .web_m?    then "video/webm"
      in .matroska? then "video/x-matroska"
      end
    end

    def ffmpeg_format : String
      case self
      in .mp4?      then "mp4"
      in .web_m?    then "webm"
      in .matroska? then "matroska"
      end
    end

    # MP4 can't hold WebVTT, Matroska players handle SubRip better
    def subtitle_codec : String
      case self
      in .mp4?      then "mov_text"
      in .web_m?    then "webvtt"
      in .matroska? then "srt"
      end
    end
  end

  record Subtitle, url : String, language_code : String, name : String, auto_generated : Bool = false

  # The first subtitle is shown by default in MP4, so the most likely one is
  # put first: the user's preferred captions, then manual before
  # auto-generated ones, each in the language of the audio, then English.
  def sort_subtitles(subtitles : Array(Subtitle), preferred : Array(String), audio_language : String?) : Array(Subtitle)
    audio_language = audio_language.try &.split(/[-_.]/)[0].downcase

    return subtitles.each_with_index.to_a.sort_by! do |subtitle, i|
      language = subtitle.language_code.split(/[-_.]/)[0].downcase
      preference = preferred.index do |caption|
        !caption.empty? && caption.downcase.in?(subtitle.name.downcase, language)
      end

      {
        preference || preferred.size,
        subtitle.auto_generated ? 1 : 0,
        language == audio_language ? 0 : 1,
        language == "en" ? 0 : 1,
        i,
      }
    end.map(&.[0])
  end

  # "iw", "in" and "ji" are deprecated, but still used by YouTube
  private ISO_639_1_TO_2 = {
    "aa" => "aar", "ab" => "abk", "af" => "afr", "ak" => "aka", "am" => "amh", "ar" => "ara", "an" => "arg", "as" => "asm",
    "av" => "ava", "ae" => "ave", "ay" => "aym", "az" => "aze", "ba" => "bak", "bm" => "bam", "be" => "bel", "bn" => "ben",
    "bh" => "bih", "bi" => "bis", "bo" => "bod", "bs" => "bos", "br" => "bre", "bg" => "bul", "ca" => "cat", "cs" => "ces",
    "ch" => "cha", "ce" => "che", "cu" => "chu", "cv" => "chv", "kw" => "cor", "co" => "cos", "cr" => "cre", "cy" => "cym",
    "da" => "dan", "de" => "deu", "dv" => "div", "dz" => "dzo", "el" => "ell", "en" => "eng", "eo" => "epo", "et" => "est",
    "eu" => "eus", "ee" => "ewe", "fo" => "fao", "fa" => "fas", "fj" => "fij", "fi" => "fin", "fr" => "fra", "fy" => "fry",
    "ff" => "ful", "gd" => "gla", "ga" => "gle", "gl" => "glg", "gv" => "glv", "gn" => "grn", "gu" => "guj", "ht" => "hat",
    "ha" => "hau", "he" => "heb", "hz" => "her", "hi" => "hin", "ho" => "hmo", "hr" => "hrv", "hu" => "hun", "hy" => "hye",
    "ig" => "ibo", "io" => "ido", "ii" => "iii", "iu" => "iku", "ie" => "ile", "ia" => "ina", "id" => "ind", "ik" => "ipk",
    "is" => "isl", "it" => "ita", "jv" => "jav", "ja" => "jpn", "kl" => "kal", "kn" => "kan", "ks" => "kas", "ka" => "kat",
    "kr" => "kau", "kk" => "kaz", "km" => "khm", "ki" => "kik", "rw" => "kin", "ky" => "kir", "kv" => "kom", "kg" => "kon",
    "ko" => "kor", "kj" => "kua", "ku" => "kur", "lo" => "lao", "la" => "lat", "lv" => "lav", "li" => "lim", "ln" => "lin",
    "lt" => "lit", "lb" => "ltz", "lu" => "lub", "lg" => "lug", "mh" => "mah", "ml" => "mal", "mr" => "mar", "mk" => "mkd",
    "mg" => "mlg", "mt" => "mlt", "mn" => "mon", "mi" => "mri", "ms" => "msa", "my" => "mya", "na" => "nau", "nv" => "nav",
    "nr" => "nbl", "nd" => "nde", "ng" => "ndo", "ne" => "nep", "nl" => "nld", "nn" => "nno", "nb" => "nob", "no" => "nor",
    "ny" => "nya", "oc" => "oci", "oj" => "oji", "or" => "ori", "om" => "orm", "os" => "oss", "pa" => "pan", "pi" => "pli",
    "pl" => "pol", "pt" => "por", "ps" => "pus", "qu" => "que", "rm" => "roh", "ro" => "ron", "rn" => "run", "ru" => "rus",
    "sg" => "sag", "sa" => "san", "si" => "sin", "sk" => "slk", "sl" => "slv", "se" => "sme", "sm" => "smo", "sn" => "sna",
    "sd" => "snd", "so" => "som", "st" => "sot", "es" => "spa", "sq" => "sqi", "sc" => "srd", "sr" => "srp", "ss" => "ssw",
    "su" => "sun", "sw" => "swa", "sv" => "swe", "ty" => "tah", "ta" => "tam", "tt" => "tat", "te" => "tel", "tg" => "tgk",
    "tl" => "tgl", "th" => "tha", "ti" => "tir", "to" => "ton", "tn" => "tsn", "ts" => "tso", "tk" => "tuk", "tr" => "tur",
    "tw" => "twi", "ug" => "uig", "uk" => "ukr", "ur" => "urd", "uz" => "uzb", "ve" => "ven", "vi" => "vie", "vo" => "vol",
    "wa" => "wln", "wo" => "wol", "xh" => "xho", "yi" => "yid", "yo" => "yor", "za" => "zha", "zh" => "zho", "zu" => "zul",
    "iw" => "heb", "in" => "ind", "ji" => "yid",
  }

  private ISO_639_2_T_TO_B = {
    "bod" => "tib", "ces" => "cze", "cym" => "wel", "deu" => "ger", "ell" => "gre", "eus" => "baq", "fas" => "per", "fra" => "fre",
    "hye" => "arm", "isl" => "ice", "kat" => "geo", "mkd" => "mac", "mri" => "mao", "msa" => "may", "mya" => "bur", "nld" => "dut",
    "ron" => "rum", "slk" => "slo", "sqi" => "alb", "zho" => "chi",
  }

  private REQUEST_SIZE = 10 * 1024 * 1024

  private FFMPEG_PATH = Process.find_executable(CONFIG.ffmpeg_path)

  def ffmpeg_path : String?
    return FFMPEG_PATH
  end

  def available? : Bool
    return CONFIG.invidious_companion.present? && !FFMPEG_PATH.nil?
  end

  # The "request_size" option of the HTTP protocol is only in recent ffmpeg versions
  private REQUEST_SIZE_SUPPORTED = FFMPEG_PATH.try do |path|
    help = IO::Memory.new
    Process.run(path, {"-hide_banner", "-h", "protocol=http"}, output: help, error: help)
    help.to_s.includes?("-request_size")
  end || false

  def request_size_supported? : Bool
    return REQUEST_SIZE_SUPPORTED
  end

  # Companion only serves the original audio track
  def stream_url(companion : ::Config::CompanionConfig, video_id : String, itag : Int32) : String
    return companion_url(companion, "/latest_version", video_id, {"id" => video_id, "itag" => itag.to_s, "local" => "true"})
  end

  def subtitle_url(companion : ::Config::CompanionConfig, video_id : String, label : String) : String
    return companion_url(companion, "/api/v1/captions/#{video_id}", video_id, {"label" => label})
  end

  private def companion_url(companion : ::Config::CompanionConfig, path : String, video_id : String, params : Hash(String, String)) : String
    params = params.merge({"check" => invidious_companion_encrypt(video_id)})
    return "#{companion.private_url.to_s.chomp('/')}#{path}?#{URI::Params.encode(params)}"
  end

  def container_for(video_mime_type : String, audio_mime_type : String) : Container
    video = video_mime_type.split(";")[0].strip
    audio = audio_mime_type.split(";")[0].strip

    case {video, audio}
    when {"video/mp4", "audio/mp4"}   then Container::MP4
    when {"video/webm", "audio/webm"} then Container::WebM
    else                                   Container::Matroska
    end
  end

  # MP4 expects ISO 639-2/T, Matroska ISO 639-2/B
  def iso_639_2(code : String, container : Container) : String
    primary = code.split(/[-_.]/)[0].downcase

    language = ISO_639_1_TO_2[primary]?
    language ||= primary if primary.size == 3 && primary.each_char.all?(&.ascii_lowercase?)
    return "und" if language.nil?

    return language if container.mp4?
    return ISO_639_2_T_TO_B.fetch(language, language)
  end

  # Companion only serves the original audio track and no DRC streams,
  # which have the same itag. Videos with a single audio track don't have
  # any audio track information.
  def mergeable_audio?(format : Hash(String, JSON::Any)) : Bool
    return false if format["isDrc"]?.try(&.as_bool?)

    audio_track = format["audioTrack"]?
    return audio_track.nil? || audio_track["audioIsDefault"]?.try(&.as_bool?) != false
  end

  # Track IDs look like "en.4"
  def audio_language(format : Hash(String, JSON::Any)) : String?
    return format["audioTrack"]?.try &.["id"]?.try &.as_s?.try &.split('.')[0]
  end

  # Merges the video and audio streams and the subtitles, which must be
  # local files, into `output`, a file or "pipe:1"
  def ffmpeg_arguments(
    container : Container,
    video_url : String,
    audio_url : String,
    audio_language : String?,
    title : String,
    output : String,
    subtitles : Array(Subtitle) = [] of Subtitle,
    request_size : Bool = false,
  ) : Array(String)
    args = ["-hide_banner", "-loglevel", "error", "-nostdin"]

    {video_url, audio_url}.each do |url|
      # Companion sometimes fails to reach YouTube on the first try
      args.concat({
        "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_on_network_error", "1",
        "-reconnect_on_http_error", "5xx", "-reconnect_delay_max", "10",
      })
      # YouTube throttles requests for a whole stream to the playback speed
      args.concat({"-request_size", REQUEST_SIZE.to_s}) if request_size
      args.concat({"-i", url})
    end
    subtitles.each { |subtitle| args.concat({"-i", subtitle.url}) }

    args.concat({"-map", "0:v:0", "-map", "1:a:0"})
    subtitles.each_index { |i| args.concat({"-map", "#{i + 2}:s:0"}) }

    args.concat({"-c", "copy"})
    args.concat({"-c:s", container.subtitle_codec}) if !subtitles.empty?
    args.concat({"-metadata", "title=#{title}"})

    # Matroska players assume English without a language
    args.concat({"-metadata:s:v:0", "language=und"})
    args.concat({"-metadata:s:a:0", "language=#{iso_639_2(audio_language || "", container)}"})
    subtitle_metadata(args, container, subtitles)

    # MP4 needs to be fragmented to be written to a non-seekable output
    args.concat({"-movflags", "frag_keyframe+empty_moov"}) if container.mp4? && output == "pipe:1"

    args.concat({"-f", container.ffmpeg_format, "-y", output})

    return args
  end

  # Adds the subtitles to the file merged by `ffmpeg_arguments`
  def subtitle_arguments(container : Container, input : String, subtitles : Array(Subtitle), output : String) : Array(String)
    args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", input]
    subtitles.each { |subtitle| args.concat({"-i", subtitle.url}) }

    args.concat({"-map", "0"})
    subtitles.each_index { |i| args.concat({"-map", "#{i + 1}:s:0"}) }

    args.concat({"-c", "copy", "-c:s", container.subtitle_codec})
    subtitle_metadata(args, container, subtitles)

    args.concat({"-movflags", "+faststart"}) if container.mp4?
    args.concat({"-f", container.ffmpeg_format, "-y", output})

    return args
  end

  private def subtitle_metadata(args : Array(String), container : Container, subtitles : Array(Subtitle))
    subtitles.each_with_index do |subtitle, i|
      args.concat({"-metadata:s:s:#{i}", "language=#{iso_639_2(subtitle.language_code, container)}"})
      args.concat({"-metadata:s:s:#{i}", "title=#{subtitle.name}"})
    end

    # ffmpeg marks the first subtitle as default, so players show it
    args.concat({"-disposition:s", "0"}) if !subtitles.empty?
  end

  # Writes the subtitles to `directory`. Failed subtitles are skipped.
  def fetch_subtitles(video_id : String, subtitles : Array(Subtitle), directory : String) : Array(Subtitle)
    fetched = [] of Subtitle

    subtitles.each_with_index do |subtitle, i|
      content = SubtitleCache.fetch(video_id, subtitle.name, subtitle.url)
      next if content.nil?

      path = File.join(directory, "subtitle-#{i}.vtt")
      File.write(path, content)
      fetched << subtitle.copy_with(url: path)
    end

    return fetched
  end
end
