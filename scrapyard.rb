#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'logger'
require 'pathname'
require 'digest'
require 'tempfile'
require 'fileutils'

def parse_options(args = ARGV)
  options = {
    keys: [],
    yard: '/tmp/scrapyard',
    paths: []
  }

  parser = OptionParser.new(args) do |opts|
    opts.banner = 'Usage: scrapyard.rb [command] [options]'
    opts.on(
      '-k', '--keys KEY1,KEY2', Array,
      'Specify keys for search or dumping in order of preference'
    ) do |keys|
      options[:keys] = keys
    end
    opts.on('-y', '--yard PATH', String,
            'The directory the scrapyard is stored in.') do |path|
      options[:yard] = path
    end
    opts.on('-p', '--paths PATH1,PATH2', Array,
            'Paths to store in the scrapyard') do |paths|
      options[:paths] = paths
    end
    opts.on_tail('-v', '--verbose') do
      options[:verbose] = true
    end
    opts.on_tail('-h', '--help') do
      puts opts
      exit
    end
  end.parse!

  operations = {
    search: 1,
    store: 1,
    junk: 0,
    crush: 0
  }

  if args.empty?
    puts "No command specified from #{operations.keys}"
    puts opts
    exit
  end

  command = args.shift.intern
  options[:paths] += args # grab everything remaining after -- as a path

  if (remaining = operations[command])
    if options[:paths].size >= remaining
      options[:command] = command
    else
      puts "#{command} requires paths"
      puts parser
      exit
    end
  else
    puts "Unrecognized command #{command}"
    puts parser
    exit
  end

  if %i[search store junk].include?(command) && options[:keys].empty?
    puts "Command #{command} requires at least one key argument"
  end

  options
end

class Key
  def initialize(key)
    @key = key
  end

  def checksum!(log)
    @key = @key.gsub(/(#\([^}]+\))/) do |match|
      f = Pathname.new match[2..-2].strip
      if f.exist?
        log.debug "Including sha1 of #{f}"
        Digest::SHA1.file(f).hexdigest
      else
        log.debug "File #{f} does not exist, ignoring checksum"
        ''
      end
    end

    self
  end

  def to_s
    @key
  end

  def self.to_path(yard, keys, suffix, log)
    keys.map { |k| yard.to_key + (Key.new(k).checksum!(log).to_s + suffix) }
  end
end

# Save or restores from a tarball
class Pack
  attr_reader :log
  def initialize(log)
    @log = log
  end

  def save(cache, paths)
    Tempfile.open('scrapyard') do |temp|
      temp_path = temp.path
      cmd = "tar czf %s %s" % [temp_path, paths.join(" ")]
      log.debug "Executing [#{cmd}]"
      system(cmd)
      FileUtils.mv temp_path, cache
      system("touch #{cache}")
    end

    log.info "Created: %s" % %x|ls -lah #{cache}|.chomp
  end

  def restore(cache, paths)
    cmd = "tar zxf #{cache}"
    log.debug "Found scrap in #{cache}"
    log.info "Executing [#{cmd}]"
    rval = system(cmd)
    unless paths.empty?
      log.info "Restored: %s" % %x|du -sh #{paths.join(" ")}|.chomp
    end
    rval == true ? 0 : 255
  end
end

class FileYard
  def initialize(yard, log)
    @path = Pathname.new(yard)
    @log = log
  end

  def to_key
    @path.to_s
  end

  def init
    if @path.exist?
      @log.info "Scrapyard: #{@path}"
    else
      @log.info "Scrapyard: #{@path} (creating)"
      @path.mkpath
    end
  end
end

class Scrapyard
  def initialize(yard, log)
    @yard = FileYard.new(yard, log)
    @log = log
    @pack = Pack.new(@log)
  end

  attr_reader :log

  def search(keys, paths)
    @yard.init
    log.info "Searching for #{keys}"
    key_paths = Key.to_path(@yard, keys, "*", log)

    cache = nil
    key_paths.each do |path|
      glob = Pathname.glob(path.to_s)
      log.debug "Scanning %s -> %p" % [path,glob.map(&:to_s)]
      cache = glob.max_by(&:mtime)
      break if cache # return on first match
    end

    if cache
      exit(@pack.restore(cache, paths))
    else
      log.info 'Unable to find key(s): %p' % [paths.map(&:to_s)]
      exit 1
    end
  end

  def store(keys, paths)
    @yard.init
    log.info "Storing #{keys}"
    key_path = Key.to_path(@yard, keys, ".tgz", log).first.to_s

    @pack.save(key_path, paths)
    exit 0
  end

  def junk(keys, _paths)
    @yard.init
    log.info "Junking #{keys}"
    key_paths = Key.to_path(@yard, keys, ".tgz", log)
    log.debug "Paths: %p" % key_paths.map(&:to_s)
    key_paths.select(&:exist?).each(&:delete)
    exit 0
  end

  def crush(_keys, _paths)
    @yard.init
    log.info "Crushing the yard to scrap!"
    @yard.children.each do |tarball|
      if tarball.mtime < (Time.now - 20 * days)
        log.info "Crushing: #{tarball}"
        tarball.delete
      else
        log.debug "Keeping: #{tarball} at #{tarball.mtime}"
      end
    end
  end

  private

  def days
    24 * 60 * 60
  end
end

if $PROGRAM_NAME == __FILE__
  options = parse_options

  log = Logger.new(STDOUT)
  log.level = options[:verbose] ? Logger::DEBUG : Logger::WARN

  Scrapyard.new(options[:yard], log).send(
    options[:command], options[:keys], options[:paths]
  )
end
