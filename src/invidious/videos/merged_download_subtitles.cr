require "http/client"

# Subtitles of merged downloads, shared by all requests. YouTube rate limits
# subtitles far more readily than videos, so they are throttled for the whole
# instance: a few at once, like a player does, then one every two seconds.
module Invidious::Videos::MergedDownload::SubtitleCache
  extend self

  private BURST       = 3
  private INTERVAL    = 2.seconds
  private RETRY_DELAY = 10.seconds
  private TTL         = 15.minutes
  private MAX_ENTRIES = 500

  private class Entry
    getter created_at = Time.utc
    getter done = ::Channel(Nil).new
    property content : String? = nil
  end

  @@entries = {} of String => Entry
  @@entries_mutex = Mutex.new

  @@tokens : Float64 = BURST.to_f
  @@tokens_updated_at : Time = Time.utc
  @@throttle_mutex = Mutex.new

  def prefetch(video_id : String, label : String, url : String) : Nil
    spawn { fetch(video_id, label, url) }
  end

  # Waits until the subtitle is fetched, nil if that failed
  def fetch(video_id : String, label : String, url : String) : String?
    key = "#{video_id}\n#{label}"

    entry, created = @@entries_mutex.synchronize do
      prune

      if existing = @@entries[key]?
        {existing, false}
      else
        {@@entries[key] = Entry.new, true}
      end
    end

    if created
      entry.content = download(url)
      @@entries_mutex.synchronize { @@entries.delete(key) } if entry.content.nil?
      entry.done.close
    else
      entry.done.receive?
    end

    return entry.content
  end

  private def prune
    now = Time.utc
    @@entries.reject! { |_, entry| entry.done.closed? && now - entry.created_at > TTL }

    while @@entries.size >= MAX_ENTRIES
      @@entries.delete(@@entries.first_key)
    end
  end

  private def throttle
    @@throttle_mutex.synchronize do
      now = Time.utc
      @@tokens = Math.min(BURST.to_f, @@tokens + (now - @@tokens_updated_at) / INTERVAL)
      @@tokens_updated_at = now

      if @@tokens < 1
        sleep INTERVAL * (1 - @@tokens)
        @@tokens = 1.0
        @@tokens_updated_at = Time.utc
      end

      @@tokens -= 1
    end
  end

  private def download(url : String) : String?
    uri = URI.parse(url)

    2.times do |attempt|
      sleep RETRY_DELAY if attempt > 0
      throttle

      begin
        response = HTTP::Client.new(uri) do |client|
          client.connect_timeout = 10.seconds
          client.read_timeout = 30.seconds
          client.get(uri.request_target)
        end

        return response.body if response.success?

        LOGGER.warn("download_merged: subtitle request failed with #{response.status_code}")
        return nil if !(response.status.too_many_requests? || response.status.server_error?)
      rescue ex
        LOGGER.warn("download_merged: subtitle request failed: #{ex.message}")
      end
    end

    return nil
  end
end
