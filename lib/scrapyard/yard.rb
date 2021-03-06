require 'pathname'

module Scrapyard
  # Yard Interface
  class Yard
    def self.for(yard, log)
      klass = yard =~ /^s3:/ ? AwsS3Yard : FileYard
      @yard = klass.new(yard, log)
    end

    def to_path
      @log.error "not implemented"
    end

    def init
      @log.error "not implemented"
    end

    def search(key_paths)
      @log.error "not implemented"
    end

    def store(cache)
      @log.error "not implemented"
    end

    def junk(key_paths)
      @log.error "not implemented"
    end

    def crush
      @log.error "not_implemented"
    end
  end

  # Implement Yard using a directory as storage
  class FileYard < Yard
    def initialize(yard, log)
      @path = Pathname.new(yard)
      @log = log
      init
    end

    def to_path
      @path
    end

    def search(key_paths)
      key_paths.each do |path|
        glob = Pathname.glob(path.to_s)
        @log.debug "Scanning %s -> %p" % [path,glob.map(&:to_s)]
        cache = glob.max_by(&:mtime)
        return cache if cache # return on first match
      end

      nil
    end

    def store(cache)
      cache # no-op for local
    end

    def junk(key_paths)
      key_paths.select(&:exist?).each(&:delete)
    end

    def crush
      @log.info 'Crushing the yard to scrap!'
      @path.children.each do |tarball|
        if tarball.mtime < (Time.now - 20 * days)
          @log.info "Crushing: #{tarball}"
          tarball.delete
        else
          @log.debug "Keeping: #{tarball} at #{tarball.mtime}"
        end
      end
    end

    private

    def init
      if @path.exist?
        @log.info "Scrapyard: #{@path}"
      else
        @log.info "Scrapyard: #{@path} (creating)"
        @path.mkpath
      end
    end

    def days
      24 * 60 * 60
    end
  end

  # Implement Yard using an S3 bucket as storage
  class AwsS3Yard < Yard
    def initialize(yard, log)
      @bucket = yard
      @log = log
    end

    def to_path
      '/tmp/'
    end

    S3_CMD="aws s3"
    AWS_LS = /(?<time>\d+-\d+-\d+ \d+:\d+:\d+)\s+(?<size>\d+)\s+(?<name>.*)$/
    def search(key_paths)
      files = `#{S3_CMD} ls #{@bucket}`.chomp.split(/$/).map do |file|
        if (m = file.match(AWS_LS))
          { file: m['name'], size: m['size'], time: m['time'] }
        else
          @log.warn "Unable to parse #{file}"
        end
      end

      key_paths.each do |key|
        prefix = Pathname.new(key).basename.to_s.tr('*', '')
        glob = files.select { |f| f[:file].start_with? prefix }
        @log.debug "Scanning %s -> %p" % [key, glob.map { |x| x[:file] }]
        needle = glob.max_by { |f| f[:time] }
        return fetch(needle[:file]) if needle
      end

      nil
    end

    def fetch(cache)
      remote = @bucket + cache
      local = Pathname.new(to_path).join(cache)
      system("#{S3_CMD} cp #{remote} #{local}")
      local
    end

    def store(cache)
      remote_path = @bucket + Pathname.new(cache).basename.to_s
      system("#{S3_CMD} cp #{cache} #{remote_path}")
    end

    def junk(key_paths)
      key_paths.each do |key|
        path = @bucket + Pathname.new(key).basename.to_s
        system("#{S3_CMD} rm #{path}")
      end
    end
  end
end
