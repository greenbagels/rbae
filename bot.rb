#!/usr/bin/env ruby

# @file bot.rb
# @brief Basic discordrb-based chat utility bot
# @copyright GPLv3
# @author Sameed Pervaiz (pervaiz.8@osu.edu)
# @date 2021-Oct-17

# frozen_string_literal: true

# This simple bot responds to every "Ping!" message with a "Pong!"

require 'discordrb'
require 'net/http'
require 'cgi'
require 'digest'
require 'optparse'

Constraints = Struct.new(:at_least,
                         :at_most,
                         :n_highest,
                         :n_lowest,
                         :explode_at,
                         :explode_above,
                         :explode_below)

# These are used for primitive queueing of channel song playlists
mutex_map = {}
semaphore = Mutex.new

# Here we go!
puts 'Starting up the bot!'

# This statement creates a bot with the specified token and application ID. After this line, you can add events to the
# created bot, and eventually run it.
#
# If you don't yet have a token to put in here, you will need to create a bot account here:
#   https://discord.com/developers/applications
# If you're wondering about what redirect URIs and RPC origins, you can ignore those for now. If that doesn't satisfy
# you, look here: https://github.com/discordrb/discordrb/wiki/Redirect-URIs-and-RPC-origins
# After creating the bot, simply copy the token (*not* the OAuth2 secret) and put it into the
# respective place.
bot_token = File.new("discord_token", "r").read.strip
bot = Discordrb::Commands::CommandBot.new token: bot_token, prefix: '!'

# We use a hash with mutexes to check if we're currently connected to any channel.

# Wolfram Alpha
bot.command :wa do |_event, *args|
  base_uri = "http://api.wolframalpha.com/v1/result"
  appid = File.new("wolfram_token", "r").read.strip
  query = CGI.escape(args.join(' '))
  uri = base_uri + "?appid=" + appid + "&i=" + query
  _event << Net::HTTP.get(URI(uri))
end

# Music playing functionality
bot.command :play do |_event, *args|
  # First, find out where the user is, verifying that they are indeed connected
  channel = _event.user.voice_channel
  next "Error: you aren't in a voice channel!" unless channel

  query = args.join(" ")
  # Avoid fifo collisions
  fifoname = Digest::SHA512.hexdigest(query + channel.name + Time.new.to_i.to_s) + ".fifo"
  # Now we grab the audio they want and play it
  if File.exist?(fifoname)
    File.delete(fifoname)
  end
  cmd = "mkfifo " + fifoname + ";youtube-dl -x --no-part -R 0 -f bestaudio -o " + fifoname + " \"ytsearch: " + query + "\""
  pid = Process.spawn(cmd)
  Process.detach(pid)
  while not File.exist?(fifoname)
    sleep 0.1
  end

  channel_mutex = nil
  semaphore.synchronize {
    mutex_map[channel] = Mutex.new if mutex_map[channel].nil?
    channel_mutex = mutex_map[channel]
  }

  channel_mutex.synchronize {
    bot.voice_connect(channel)
    voice_bot = _event.voice
    voice_bot.play_file(fifoname)
    voice_bot.destroy
    File.delete(fifoname)
  }
  # File.delete(fifoname)
end

#bot.command :stop do |_event|
#  bot.voice_connect(_event.user.voice_channel)
#  _event.voice.destroy
#end

# Dice rolling functionality
bot.command(:roll, min_args: 0,
            description: "Rolls `n` independent, `k`-sided dice with per-dice modifier `r`," +
            " and returns a list of results with related stats.\nThe modifier is optional, but leaving out either n or k" +
            " results in a standard 1d6 roll.",
            usage: 'This command has its own help subcommand! Try using \'roll --help\' (or \'-h\')!') do |_event, *args|

  # default values
  n = 1
  k = 6
  r = 0

  # parse the inputs
  args&.each { |arg|
    ourmatch = /([0-9]+)?d([0-9]+)([+-][0-9]+)?/.match(arg.strip)
    if ourmatch
      n_str = ourmatch[1]
      k = ourmatch[2].to_i
      r_str = ourmatch[3]
      if n_str
        n = n_str.to_i
      end
      if r_str
        if r_str[0] == "+"
          r = r_str[1..].to_i
        elsif r_str[0] == "-"
          r = -r_str[1..].to_i
        end
      end
    end
  }

  #at_least = nil
  #at_most = nil
  #n_highest = nil
  #n_lowest = nil
  #explode_at = nil
  #explode_above = nil
  #explode_below = nil
  constraints = Constraints.new()

  long_switches = [
    "--at-least N",
    "--at-most N",
    "--use-highest N",
    "--use-lowest N",
    "--explode-at N",
    "--explode-above N",
    "--explode-below N"
  ]

  long_switch_descs = [
    "Only uses rolls that are >= N",
    "Only uses rolls that are <= N",
    "Only uses the N highest rolls",
    "Only uses the N lowest rolls",
    "Performs additional rolls for each result = N",
    "Performs additional rolls for each result >= N",
    "Performs additional rolls for each result <= N"
  ]

  # Now that we know the roll parameters, we can parse options with proper error checking
  stop = false
  optparser = OptionParser.new do |opts|
    opts.banner = "Usage: roll [options]\n" +
    "Options generally combine additively (i.e. using both --use-highest and" +
    "--use-lowest will include both extremes)"

    (0..6).each do |i|
      opts.on(long_switches[i], Integer, long_switch_descs[i]) do |n|
        constraints[i] = n
      end
    end

    opts.on("--help", "-h", "Prints this help listing") do
      _event << opts
      stop = true
    end
  end

  begin
    optparser.parse(args)
  rescue Exception => e
    _event << e.message
    stop = true
  end

  if stop
    next
  end
  # From here on, the constraints struct contains up to 7 constraints that determine
  # our rolling/rerolling strategy. How these constraints combine depends on the
  # individual constraints themselves.
  #
  # For example, the at-least and at-most constraints could be ANDed together to
  # create a closed interval of desired roll outcomes, assuming they are given the
  # lower and upper bounds, respectively. But if the at-most constraint is smaller
  # than the at-least constraint, this would lead to an empty set. In this case, it
  # makes more sense to take the *union* of such solution sets!
  #
  # In a similar note, it doesn't make sense for the highest and lowest N options
  # to combine in any way except as a union, and ditto for exploding the rolls.

  randarr = Array.new(n) { rand(1..k) + r }

  # Handle rolling the extras from explosions
  rerolls = 0
  randarr.each do |val|
    if (constraints[:explode_at] and val == constraints[:explode_at]) or
       (constraints[:explode_above] and val >= constraints[:explode_above]) or
       (constraints[:explode_below] and val <= constraints[:explode_below])
      rerolls = rerolls + 1
    end
  end

  randarr.concat(Array.new(rerolls) { rand(1..k) + r })

  # Now, filter based on desired min/max.
  filtered_arr = []
  randarr.each do |elem|
    min = constraints[:at_least]
    max = constraints[:at_most]
    if min and max
      if min <= max
        filtered_arr.push(elem) unless elem < min or elem > max
      else
        filtered_arr.push(elem) unless elem > min and elem < max
      end
    elsif min
      filtered_arr.push(elem) unless elem < min
    elsif max
      filtered_arr.push(elem) unless elem > max
    end
  end

  # Now sort and cut out the highest + lowest rolls
  randarr = filtered_arr.sort unless filtered_arr.empty?
  filtered_arr = []

  if constraints[:n_lowest] and constraints[:n_lowest] > 0
    cutoff = [randarr.size, constraints[:n_lowest]].min
    filtered_arr.concat(randarr[0, cutoff])
  end
  if constraints[:n_highest] and constraints[:n_highest] > 0
    cutoff = [randarr.size, constraints[:n_highest]].min - filtered_arr.size
    filtered_arr.concat(randarr[-cutoff, cutoff])
  end
  randarr = filtered_arr unless filtered_arr.empty?
  total = randarr.size

  # And continue as normal
  sum = randarr.reduce(&:+).to_f
  mean = sum / total.to_f
  # and return the values
  _event << "`Rolling " + n.to_s + "d" + k.to_s + (r >= 0 ? "+" + r.to_s : r.to_s) + ":` " +
  randarr[0..[20, total].min - 1].map { |x| "#{x}" }.join(", ")

  # First, let's pre-calculate our conditions
  do_explode = (constraints[:explode_at] or constraints[:explode_above]) or constraints[:explode_below]
  do_bounds = constraints[:at_least] or constraints[:at_most]

  medial_connector = " ├─>"
  terminal_connector = " └─>"

  if total > 20
    connector = (do_explode or do_bounds) ? medial_connector : terminal_connector
    _event << connector + "(+" + (total - [20, total].min).to_s + " suppressed roll(s))..."
  end

  if (do_explode)
    connector = do_bounds ? medial_connector : terminal_connector
    if rerolls > 0
      _event << connector + "***Bang!*** " + rerolls.to_s + " roll(s) exploded into additional rolls!"
    else
      _event << connector + "*Fizzle...* " + rerolls.to_s + " roll(s) exploded into additional rolls..."
    end
  end

  if (do_bounds)
    connector = terminal_connector
    _event << connector + total.to_s + " total success(es)! (within specified min/max)"
  end

  if (total > 1)
    _event << "Sum: " + sum.to_i.to_s
    _event << "Mean: " + mean.round(2).to_s
  end
end

bot.command(:bots, description: "Acknowledges self as bot using a standard formatted version string")  do |event|
  event << "Reporting in! [Ruby " + RUBY_VERSION + " / discordrb " + Gem.loaded_specs["discordrb"].version.to_s + "]"
end
# This method call has to be put at the end of your script, it is what makes the bot actually connect to Discord. If you
# leave it out (try it!) the script will simply stop and the bot will not appear online.
bot.run
