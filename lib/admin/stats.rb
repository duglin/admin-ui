require 'json'
require_relative 'utils'

module IBM::AdminUI
  class Stats
    def initialize(logger, cc, varz)
      @logger = logger
      @cc     = cc
      @varz   = varz

      @stats_semaphore = Mutex.new

      Thread.new do
        loop do
          schedule_stats
        end
      end
    end

    def stats
      result = {}

      result['label'] = Config.cloud_controller_uri
      result['items']  = []

      @stats_semaphore.synchronize do
        begin
          result['items'] = JSON.parse(IO.read(Config.stats_file)) if File.exists?(Config.stats_file)
        rescue => error
          @logger.debug("Error reading stats file: #{ error }")
        end
      end

      result
    end

    def current_stats
      {
        :apps              => @cc.applications_count,
        :deas              => @varz.deas_count,
        :organizations     => @cc.organizations_count,
        :running_instances => @cc.applications_running_instances,
        :spaces            => @cc.spaces_count,
        :timestamp         => Utils.time_in_milliseconds,
        :total_instances   => @cc.applications_total_instances,
        :users             => @cc.users_count
      }
    end

    def create_stats(stats)
      save_stats(stats) ? stats : nil
    end

    private

    def schedule_stats
      time_until_generate_stats = calculate_time_until_generate_stats
      @logger.debug("Waiting #{ time_until_generate_stats } seconds before trying to save stats...")
      sleep(time_until_generate_stats)
      generate_stats
    rescue => error
      @logger.debug("Error generating stats: #{ error.inspect }")
    end

    def calculate_time_until_generate_stats
      current_time = Time.now.to_i
      refresh_time = (Date.today.to_time + 60 * Config.stats_refresh_time).to_i
      time_difference = refresh_time - current_time
      time_difference > 0 ? time_difference : (refresh_time + 60 * 60 * 24) - current_time
    end

    def save_stats(stats)
      result = false

      unless stats.nil?
        @stats_semaphore.synchronize do
          begin
            stats_array = []

            stats_array = JSON.parse(IO.read(Config.stats_file)) if File.exists?(Config.stats_file)

            @logger.debug("Writing stats: #{ stats }")

            stats_array.push(stats)

            File.open(Config.stats_file, 'w') do |file|
              file << JSON.pretty_generate(stats_array)
            end

            result = true
          rescue => error
            @logger.debug("Error writing stats: #stats, error: #{ error }")
          end
        end
      end

      result
    end

    def generate_stats
      stats = current_stats

      attempt = 0

      while !save_stats(stats) && (attempt < Config.stats_retries)
        attempt += 1
        @logger.debug("Waiting #{ Config.stats_retry_interval } seconds before trying to save stats again...")
        sleep(Confog.stats_retry_interval)
        stats = current_stats
      end

      @logger.debug('Reached max number of stat retries, giving up for now...') if attempt == Config.stats_retries
    end
  end
end