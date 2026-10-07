{% skip_file if flag?(:api_only) %}

module Invidious::Routes::Watch
  def self.handle(env)
    preferences = env.get("preferences").as(Preferences)
    locale = preferences.locale
    region = env.params.query["region"]?

    if env.params.query.to_s.includes?("%20") || env.params.query.to_s.includes?("+")
      url = "/watch?" + env.params.query.to_s.gsub("%20", "").delete("+")
      return env.redirect url
    end

    if env.params.query["v"]?
      id = env.params.query["v"]

      if env.params.query["v"].empty?
        return error_template(400, "Invalid parameters.")
      end

      unless validate_video_id(id)
        return error_template(400, InvalidVideoID.new(id))
      end
    else
      return env.redirect "/"
    end

    plid = env.params.query["list"]?.try &.gsub(/[^a-zA-Z0-9_-]/, "")
    continuation = process_continuation(env.params.query, plid, id)

    nojs = env.params.query["nojs"]?

    nojs ||= "0"
    nojs = nojs == "1"

    user = env.get?("user").try &.as(User)
    if user
      subscriptions = user.subscriptions
      watched = user.watched
      notifications = user.notifications
    end
    subscriptions ||= [] of String

    params = Invidious::Videos.process_video_params(env.params.query, preferences)
    env.params.query.delete_all("listen")

    begin
      video = get_video(id, region: params.region)
    rescue ex : NotFoundException
      LOGGER.error("get_video not found: #{id} : #{ex.message}")
      return error_template(404, ex)
    rescue ex
      LOGGER.error("get_video: #{id} : #{ex.message}")
      return error_template(500, ex)
    end

    if preferences.annotations_subscribed &&
       subscriptions.includes?(video.ucid) &&
       (env.params.query["iv_load_policy"]? || "1") == "1"
      params.annotations = true
    end
    env.params.query.delete_all("iv_load_policy")

    if watched && preferences.watch_history
      Invidious::Database::Users.mark_watched(user.as(User), id)
    end

    if CONFIG.enable_user_notifications && notifications && notifications.includes? id
      Invidious::Database::Users.remove_notification(user.as(User), id)
      env.get("user").as(User).notifications.delete(id)
      notifications.delete(id)
    end

    if nojs
      if preferences
        source = video.comments? ? preferences.comments[0] : "reddit"

        if source.empty?
          source = preferences.comments[1]
        end

        if source == "youtube"
          begin
            comment_html = JSON.parse(Comments.fetch_youtube(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
          rescue ex
            if preferences.comments[1] == "reddit"
              comments, reddit_thread = Comments.fetch_reddit(id)
              comment_html = Frontend::Comments.template_reddit(comments, locale)

              comment_html = Comments.fill_links(comment_html, "https", "www.reddit.com")
              comment_html = Comments.replace_links(comment_html)
            end
          end
        elsif source == "reddit"
          begin
            comments, reddit_thread = Comments.fetch_reddit(id)
            comment_html = Frontend::Comments.template_reddit(comments, locale)

            comment_html = Comments.fill_links(comment_html, "https", "www.reddit.com")
            comment_html = Comments.replace_links(comment_html)
          rescue ex
            if preferences.comments[1] == "youtube"
              comment_html = JSON.parse(Comments.fetch_youtube(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
            end
          end
        end
      else
        comment_html = JSON.parse(Comments.fetch_youtube(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
      end

      comment_html ||= ""
    end

    fmt_stream = video.fmt_stream
    adaptive_fmts = video.adaptive_fmts

    if params.local
      fmt_stream.each { |fmt| fmt["url"] = JSON::Any.new(HttpServer::Utils.proxy_video_url(fmt["url"].as_s)) }
    end

    # Always proxy DASH streams, otherwise youtube CORS headers will prevent playback
    adaptive_fmts.each { |fmt| fmt["url"] = JSON::Any.new(HttpServer::Utils.proxy_video_url(fmt["url"].as_s)) }

    video_streams = video.video_streams
    audio_streams = video.audio_streams

    # Videos that are a premiere do not have audio streams.
    if video.premiere_timestamp.nil?
      # Older videos may not have audio sources available.
      # We redirect here so they're not unplayable
      if audio_streams.empty? && !video.live_now
        if params.quality == "dash"
          env.params.query.delete_all("quality")
          env.params.query["quality"] = "medium"
          return env.redirect "/watch?#{env.params.query}"
        elsif params.listen
          env.params.query.delete_all("listen")
          env.params.query["listen"] = "0"
          return env.redirect "/watch?#{env.params.query}"
        end
      end
    end

    captions = video.captions

    preferred_captions = captions.select { |caption|
      params.preferred_captions.includes?(caption.name) ||
        params.preferred_captions.includes?(caption.language_code.split("-")[0])
    }
    preferred_captions.sort_by! { |caption|
      (params.preferred_captions.index(caption.name) ||
        params.preferred_captions.index(caption.language_code.split("-")[0])).not_nil!
    }
    captions = captions - preferred_captions

    aspect_ratio = "16:9"

    thumbnail = "/vi/#{video.id}/maxres.jpg"

    if params.raw
      if params.listen
        url = audio_streams[0]["url"].as_s

        if params.quality.ends_with? "k"
          audio_streams.each do |fmt|
            if fmt["bitrate"].as_i == params.quality.rchop("k").to_i
              url = fmt["url"].as_s
            end
          end
        end
      else
        url = fmt_stream[0]["url"].as_s

        fmt_stream.each do |fmt|
          if fmt["quality"].as_s == params.quality
            url = fmt["url"].as_s
          end
        end
      end

      return env.redirect url
    end

    # Structure used for the download widget
    video_assets = Invidious::Frontend::WatchPage::VideoAssets.new(
      full_videos: fmt_stream,
      video_streams: video_streams,
      audio_streams: audio_streams,
      captions: video.captions
    )

    if CONFIG.invidious_companion.present?
      invidious_companion = CONFIG.invidious_companion.sample
    end

    templated "watch"
  end

  def self.redirect(env)
    url = "/watch?v=#{env.params.url["id"]}"
    if env.params.query.size > 0
      url += "&#{env.params.query}"
    end

    return env.redirect url
  end

  def self.mark_watched(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env, "/feed/subscriptions")

    redirect = env.params.query["redirect"]?
    redirect ||= "true"
    redirect = redirect == "true"

    if !user
      if redirect
        return env.redirect referer
      else
        return error_json(403, "No such user")
      end
    end

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    id = env.params.query["id"]?
    unless id && validate_video_id(id)
      env.response.status_code = 400
      return
    end

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      if redirect
        return error_template(400, ex)
      else
        return error_json(400, ex)
      end
    end

    case action = env.params.query["action"]?
    when "mark_watched"
      Invidious::Database::Users.mark_watched(user, id)
    when "mark_unwatched"
      Invidious::Database::Users.mark_unwatched(user, id)
    else
      return error_json(400, "Unsupported action #{action}")
    end

    if redirect
      env.redirect referer
    else
      env.response.content_type = "application/json"
      "{}"
    end
  end

  def self.clip(env)
    clip_id = env.params.url["clip"]?

    return error_template(400, "A clip ID is required") if !clip_id

    response = YoutubeAPI.resolve_url("https://www.youtube.com/clip/#{clip_id}")
    return error_template(400, "Invalid clip ID") if response["error"]?

    if video_id = response.dig?("endpoint", "watchEndpoint", "videoId")
      if params = response.dig?("endpoint", "watchEndpoint", "params").try &.as_s
        start_time, end_time, _ = Invidious::Videos::Clip.parse_clip_parameters(params)
        env.params.query["start"] = start_time.to_s if start_time != nil
        env.params.query["end"] = end_time.to_s if end_time != nil
      end

      return env.redirect "/watch?v=#{video_id}&#{env.params.query}"
    else
      return error_template(404, "The requested clip doesn't exist")
    end
  end

  def self.download(env)
    if CONFIG.disabled?("downloads")
      return error_template(403, "Administrator has disabled this endpoint.")
    end
    if CONFIG.invidious_companion.present?
      return error_template(403, "Downloads should be routed through Companion when present")
    end

    title = env.params.body["title"]? || ""
    video_id = env.params.body["id"]? || ""
    selection = env.params.body["download_widget"]?

    if title.empty? || video_id.empty? || selection.nil?
      return error_template(400, "Missing form data")
    end

    download_widget = JSON.parse(selection)

    extension = download_widget["ext"].as_s
    filename = "#{title}-#{video_id}.#{extension}"

    # Delete the now useless URL parameters
    env.params.body.delete("id")
    env.params.body.delete("title")
    env.params.body.delete("download_widget")

    # Pass form parameters as URL parameters for the handlers of both
    # /latest_version and /api/v1/captions. This avoids an un-necessary
    # redirect and duplicated (and hazardous) sanity checks.
    if label = download_widget["label"]?
      # URL params specific to /api/v1/captions/:id
      env.params.url["id"] = video_id
      env.params.query["title"] = filename
      env.params.query["label"] = URI.decode_www_form(label.as_s)

      return Invidious::Routes::API::V1::Videos.captions(env)
    elsif itag = download_widget["itag"]?.try &.as_i.to_s
      # URL params specific to /latest_version
      env.params.query["id"] = video_id
      env.params.query["title"] = filename
      env.params.query["local"] = "true"

      return Invidious::Routes::VideoPlayback.latest_version(env)
    else
      return error_template(400, "Invalid label or itag")
    end
  end

  def self.download_merged(env)
    if CONFIG.disabled?("downloads")
      return error_template(403, "Administrator has disabled this endpoint.")
    end
    if !Invidious::Videos::MergedDownload.available?
      return error_template(403, "Merged downloads are not available on this instance.")
    end

    video_id = env.params.body["id"]? || ""
    video_itag = env.params.body["video_itag"]?.try &.to_i?
    audio_itag = env.params.body["audio_itag"]?.try &.to_i?
    caption_labels = env.params.body.fetch_all("caption")

    if !validate_video_id(video_id)
      return error_template(400, InvalidVideoID.new(video_id))
    end
    if video_itag.nil? || audio_itag.nil?
      return error_template(400, "Missing form data")
    end
    if CONFIG.dmca_content.includes?(video_id)
      return error_template(403, "dmca_content")
    end

    begin
      video = get_video(video_id)
    rescue ex : NotFoundException
      return error_template(404, ex)
    rescue ex
      return error_template(500, ex)
    end

    video_fmt = video.video_streams.find(&.["itag"].as_i.== video_itag)
    audio_fmt = video.audio_streams.find do |fmt|
      fmt["itag"].as_i == audio_itag && Invidious::Videos::MergedDownload.mergeable_audio?(fmt)
    end

    if video_fmt.nil? || audio_fmt.nil?
      return error_template(400, "Invalid itag")
    end

    companion = CONFIG.invidious_companion.sample

    subtitles = video.captions.select { |caption| caption_labels.includes?(caption.name) }.map do |caption|
      Invidious::Videos::MergedDownload::Subtitle.new(
        url: Invidious::Videos::MergedDownload.subtitle_url(companion, video_id, caption.name),
        language_code: caption.language_code,
        name: caption.name,
        auto_generated: caption.auto_generated
      )
    end
    subtitles = Invidious::Videos::MergedDownload.sort_subtitles(
      subtitles,
      env.get("preferences").as(Preferences).captions,
      Invidious::Videos::MergedDownload.audio_language(audio_fmt)
    )

    container = Invidious::Videos::MergedDownload.container_for(
      video_fmt["mimeType"].as_s, audio_fmt["mimeType"].as_s
    )

    filename = URI.encode_www_form("#{video.title}-#{video_id}.#{container.extension}", space_to_plus: false)

    merge_arguments = ->(output : String, merged_subtitles : Array(Invidious::Videos::MergedDownload::Subtitle)) do
      Invidious::Videos::MergedDownload.ffmpeg_arguments(
        container: container,
        video_url: Invidious::Videos::MergedDownload.stream_url(companion, video_id, video_itag),
        audio_url: Invidious::Videos::MergedDownload.stream_url(companion, video_id, audio_itag),
        audio_language: Invidious::Videos::MergedDownload.audio_language(audio_fmt),
        title: video.title,
        output: output,
        subtitles: merged_subtitles,
        request_size: Invidious::Videos::MergedDownload.request_size_supported?
      )
    end

    if subtitles.empty?
      return stream_merged(env, merge_arguments.call("pipe:1", subtitles), container, filename, video_id)
    end

    directory = File.tempname("invidious-download")
    Dir.mkdir(directory)

    begin
      fetched_subtitles = ::Channel(Array(Invidious::Videos::MergedDownload::Subtitle)).new(1)
      spawn do
        fetched_subtitles.send(Invidious::Videos::MergedDownload.fetch_subtitles(video_id, subtitles, directory))
      rescue ex
        LOGGER.warn("download_merged: failed to fetch the subtitles of #{video_id}: #{ex.message}")
        fetched_subtitles.send([] of Invidious::Videos::MergedDownload::Subtitle)
      end

      # Subtitles that are prefetched or few are ready right away, so the
      # download can be streamed. Otherwise, the streams are merged into a
      # file while the subtitles are fetched, as the subtitles must be known
      # before the output can start.
      select
      when ready_subtitles = fetched_subtitles.receive
        return stream_merged(env, merge_arguments.call("pipe:1", ready_subtitles), container, filename, video_id)
      when timeout(SUBTITLE_WAIT)
      end

      merged_path = File.join(directory, "merged.#{container.extension}")
      status, errors = run_ffmpeg(merge_arguments.call(merged_path, [] of Invidious::Videos::MergedDownload::Subtitle))
      subtitles = fetched_subtitles.receive

      if status.success? && !subtitles.empty?
        output_path = File.join(directory, "output.#{container.extension}")
        status, errors = run_ffmpeg(Invidious::Videos::MergedDownload.subtitle_arguments(container, merged_path, subtitles, output_path))
      else
        output_path = merged_path
      end

      if !status.success?
        LOGGER.warn("download_merged: ffmpeg failed for #{video_id} (#{status}): #{errors}")
        return error_template(500, "Failed to merge the streams of the video.")
      end

      env.response.content_type = container.mime_type
      env.response.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\"; filename*=UTF-8''#{filename}"
      env.response.content_length = File.size(output_path)

      begin
        File.open(output_path) { |file| IO.copy(file, env.response) }
      rescue IO::Error | HTTP::Server::ClientError
        # The client closed the connection
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  private SUBTITLE_WAIT = 3.seconds

  def self.prefetch_subtitle(env)
    video_id = env.params.body["id"]? || ""
    label = env.params.body["caption"]? || ""

    if !Invidious::Videos::MergedDownload.available? || !validate_video_id(video_id)
      haltf env, status_code: 400
    end

    begin
      video = get_video(video_id)
    rescue
      haltf env, status_code: 404
    end

    if !video.captions.any?(&.name.== label)
      haltf env, status_code: 404
    end

    companion = CONFIG.invidious_companion.sample
    url = Invidious::Videos::MergedDownload.subtitle_url(companion, video_id, label)
    Invidious::Videos::MergedDownload::SubtitleCache.prefetch(video_id, label, url)

    haltf env, status_code: 204
  end

  private def self.run_ffmpeg(arguments : Array(String)) : {Process::Status, String}
    errors = IO::Memory.new
    status = Process.run(Invidious::Videos::MergedDownload.ffmpeg_path.not_nil!, arguments, error: errors)
    return status, errors.to_s.strip
  end

  private def self.stream_merged(env, arguments : Array(String), container, filename : String, video_id : String)
    ffmpeg = Process.new(
      Invidious::Videos::MergedDownload.ffmpeg_path.not_nil!, arguments,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )

    # ffmpeg blocks once the stderr pipe is full
    ffmpeg_errors = IO::Memory.new
    spawn { IO.copy(ffmpeg.error, ffmpeg_errors) rescue nil }

    env.response.content_type = container.mime_type
    env.response.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\"; filename*=UTF-8''#{filename}"

    bytes_written = 0_i64
    client_disconnected = false
    begin
      bytes_written = IO.copy(ffmpeg.output, env.response)
    rescue IO::Error | HTTP::Server::ClientError
      client_disconnected = true
    ensure
      ffmpeg.terminate if !ffmpeg.terminated?
    end

    status = ffmpeg.wait

    if !status.success? && !client_disconnected
      LOGGER.warn("download_merged: ffmpeg failed for #{video_id} (#{status}): #{ffmpeg_errors.to_s.strip}")

      # Headers not sent yet
      if bytes_written == 0
        env.response.headers.delete("Content-Disposition")
        return error_template(500, "Failed to merge the streams of the video.")
      end
    end
  end
end
