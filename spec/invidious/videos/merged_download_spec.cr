require "../../spec_helper"
require "../../../src/invidious/videos/merged_download"

alias MergedDownload = Invidious::Videos::MergedDownload

Spectator.describe MergedDownload do
  describe ".container_for" do
    it "uses MP4 for MP4 video and audio" do
      container = MergedDownload.container_for(%(video/mp4; codecs="avc1.640028"), %(audio/mp4; codecs="mp4a.40.2"))
      expect(container).to eq(MergedDownload::Container::MP4)
    end

    it "uses WebM for WebM video and audio" do
      container = MergedDownload.container_for(%(video/webm; codecs="vp9"), %(audio/webm; codecs="opus"))
      expect(container).to eq(MergedDownload::Container::WebM)
    end

    it "uses Matroska for mixed containers" do
      container = MergedDownload.container_for(%(video/webm; codecs="vp9"), %(audio/mp4; codecs="mp4a.40.2"))
      expect(container).to eq(MergedDownload::Container::Matroska)

      container = MergedDownload.container_for(%(video/mp4; codecs="av01.0.08M.08"), %(audio/webm; codecs="opus"))
      expect(container).to eq(MergedDownload::Container::Matroska)
    end
  end

  describe ".iso_639_2" do
    it "converts two-letter codes" do
      expect(MergedDownload.iso_639_2("en", MergedDownload::Container::MP4)).to eq("eng")
      expect(MergedDownload.iso_639_2("de", MergedDownload::Container::MP4)).to eq("deu")
      expect(MergedDownload.iso_639_2("de", MergedDownload::Container::Matroska)).to eq("ger")
      expect(MergedDownload.iso_639_2("fr", MergedDownload::Container::WebM)).to eq("fre")
    end

    it "ignores the region and the audio track number" do
      expect(MergedDownload.iso_639_2("pt-BR", MergedDownload::Container::MP4)).to eq("por")
      expect(MergedDownload.iso_639_2("en.4", MergedDownload::Container::MP4)).to eq("eng")
    end

    it "converts deprecated codes used by YouTube" do
      expect(MergedDownload.iso_639_2("iw", MergedDownload::Container::MP4)).to eq("heb")
    end

    it "keeps three-letter codes" do
      expect(MergedDownload.iso_639_2("fil", MergedDownload::Container::MP4)).to eq("fil")
    end

    it "returns 'und' for unknown codes" do
      expect(MergedDownload.iso_639_2("", MergedDownload::Container::MP4)).to eq("und")
      expect(MergedDownload.iso_639_2("xx", MergedDownload::Container::MP4)).to eq("und")
    end
  end

  describe ".sort_subtitles" do
    let(subtitles) do
      [
        MergedDownload::Subtitle.new("1", "fr", "French (auto-generated)", auto_generated: true),
        MergedDownload::Subtitle.new("2", "de", "German"),
        MergedDownload::Subtitle.new("3", "en", "English (auto-generated)", auto_generated: true),
        MergedDownload::Subtitle.new("4", "en-US", "English (United States)"),
        MergedDownload::Subtitle.new("5", "fr", "French"),
      ]
    end

    it "puts manual subtitles first, English first without other preference" do
      sorted = MergedDownload.sort_subtitles(subtitles, ["", "", ""], nil)
      expect(sorted.map(&.url)).to eq(["4", "2", "5", "3", "1"])
    end

    it "puts the language of the audio before English" do
      sorted = MergedDownload.sort_subtitles(subtitles, [] of String, "fr.2")
      expect(sorted.map(&.url)).to eq(["5", "4", "2", "1", "3"])
    end

    it "puts the user's preferred captions first, by name or language" do
      sorted = MergedDownload.sort_subtitles(subtitles, ["German", "fr", ""], nil)
      expect(sorted.map(&.url)).to eq(["2", "5", "1", "4", "3"])
    end
  end

  describe ".audio_language" do
    it "reads the language of the audio track" do
      format = JSON.parse(%({"itag": 140, "audioTrack": {"id": "de.3", "displayName": "German"}})).as_h
      expect(MergedDownload.audio_language(format)).to eq("de")
    end

    it "returns nil without audio track" do
      format = JSON.parse(%({"itag": 140})).as_h
      expect(MergedDownload.audio_language(format)).to be_nil
    end
  end

  describe ".ffmpeg_arguments" do
    it "maps the video and the audio with its language" do
      args = MergedDownload.ffmpeg_arguments(
        container: MergedDownload::Container::Matroska,
        video_url: "http://video",
        audio_url: "http://audio",
        audio_language: "de",
        title: "Title",
        output: "/tmp/merged.mkv"
      )

      expect(args.each_cons(2).to_a).to contain(
        ["-i", "http://video"],
        ["-i", "http://audio"],
        ["-map", "0:v:0"],
        ["-map", "1:a:0"],
        ["-metadata:s:a:0", "language=ger"],
      )
      expect(args).not_to contain("-movflags")
      expect(args).not_to contain("-request_size")
      expect(args.last(4)).to eq(["-f", "matroska", "-y", "/tmp/merged.mkv"])
    end

    it "requests the streams in chunks when supported" do
      args = MergedDownload.ffmpeg_arguments(
        container: MergedDownload::Container::MP4,
        video_url: "http://video",
        audio_url: "http://audio",
        audio_language: nil,
        title: "Title",
        output: "pipe:1",
        request_size: true
      )

      expect(args.each_cons(4).to_a).to contain(
        ["-request_size", "10485760", "-i", "http://video"],
        ["-request_size", "10485760", "-i", "http://audio"],
      )
    end

    it "fragments MP4 written to a pipe" do
      args = MergedDownload.ffmpeg_arguments(
        container: MergedDownload::Container::MP4,
        video_url: "http://video",
        audio_url: "http://audio",
        audio_language: nil,
        title: "Title",
        output: "pipe:1"
      )

      expect(args.each_cons(2).to_a).to contain(
        ["-movflags", "frag_keyframe+empty_moov"],
        ["-metadata:s:a:0", "language=und"],
      )
      expect(args.last(4)).to eq(["-f", "mp4", "-y", "pipe:1"])
    end
  end

  describe ".subtitle_arguments" do
    it "adds the subtitles with their languages" do
      subtitles = [
        MergedDownload::Subtitle.new("/tmp/subtitle-0.vtt", "en", "English"),
        MergedDownload::Subtitle.new("/tmp/subtitle-1.vtt", "de", "German"),
      ]

      args = MergedDownload.subtitle_arguments(
        MergedDownload::Container::MP4, "/tmp/merged.mp4", subtitles, "/tmp/output.mp4"
      )

      expect(args.each_cons(2).to_a).to contain(
        ["-i", "/tmp/merged.mp4"],
        ["-i", "/tmp/subtitle-0.vtt"],
        ["-i", "/tmp/subtitle-1.vtt"],
        ["-map", "0"],
        ["-map", "1:s:0"],
        ["-map", "2:s:0"],
        ["-c:s", "mov_text"],
        ["-metadata:s:s:0", "language=eng"],
        ["-metadata:s:s:1", "language=deu"],
        ["-metadata:s:s:1", "title=German"],
        ["-disposition:s", "0"],
      )
      expect(args.last(4)).to eq(["-f", "mp4", "-y", "/tmp/output.mp4"])
    end
  end
end
