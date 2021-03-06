module Godhead
  class GodRecipe
    DEFAULT_OPTIONS = {
      :monitor_group      => nil,
      :uid                => nil,
      :gid                => nil,
      :env                => nil,
      :crash_notify       => nil,
      :restart_notify     => nil,
      :flapping_notify    => nil,
      :process_log_dir    => '/var/log/god',
      :pid_dir            => '/var/run/god',
      :start_grace_time   => 10.seconds,
      :restart_grace_time => nil,         # will be start_grace_time+2 if left nil
      :default_interval   => 5.minutes,
      :start_interval     => nil,         # uses default_interval if unset
      :max_mem_usage      => nil,         # doesn't monitor mem usage if nil
      :mem_usage_interval => 10.minutes,
      :max_cpu_usage      => 50.percent,  # doesn't monitor cpu usage if nil
      :cpu_usage_interval => 10.minutes,
    }
    #
    # Hash mapping recipe_name to default options
    #
    cattr_accessor :global_options
    self.global_options = {}
    #
    # options for this instance
    #
    attr_accessor  :options

    #
    # pass in options to override the class default_options
    #
    def initialize _options={}
      self.options = self.class.default_options.deep_merge _options
    end

    def do_setup! options={}
      self.options.merge! options
      mkdirs!
      God.watch do |watcher|
        setup_watcher   watcher
        setup_start     watcher
        setup_restart   watcher
        setup_lifecycle watcher
      end
    end

    def self.create options={}
      recipe = self.new options
      recipe.do_setup!
      recipe
    end

    # ===========================================================================
    #
    # Watcher setup
    #

    #
    # Setup common to most watchers
    #
    def setup_watcher watcher
      watcher.name             = self.handle
      watcher.group            = monitor_group
      watcher.start            = start_command
      watcher.stop             = stop_command             if stop_command
      watcher.restart          = restart_command          if restart_command
      watcher.pid_file         = pid_file                 if pid_file
      watcher.uid              = options[:uid]            if options[:uid]
      watcher.gid              = options[:gid]            if options[:gid]
      watcher.env              = options[:env]            if options[:env]
      watcher.log              = process_log_file
      watcher.err_log          = process_err_log_file
      watcher.interval         = options[:default_interval]
      watcher.start_grace      = options[:start_grace_time]
      watcher.restart_grace    = options[:restart_grace_time] || (options[:start_grace_time] + 2.seconds)
      watcher.behavior(:clean_pid_file)
    end

    #
    # Starts process
    #
    def setup_start watcher
      watcher.start_if do |start|
        start.condition(:process_running) do |c|
          c.interval = options[:start_interval] || options[:default_interval]
          c.running  = false
        end
      end
      watcher.transition(:up, :start) do |on|
        on.condition(:process_exits) do |c|
          c.notify   = options[:crash_notify] if options[:crash_notify]
        end
      end
    end

    #
    def setup_restart watcher
      watcher.restart_if do |restart|
        restart.condition(:memory_usage) do |c|
          c.interval   = options[:mem_usage_interval] if options[:mem_usage_interval]
          c.above      = options[:max_mem_usage]
          c.times      = [3, 5] # 3 out of 5 intervals
          c.notify     = options[:restart_notify] if options[:restart_notify]
        end if options[:max_mem_usage]
        restart.condition(:cpu_usage) do |c|
          c.interval   = options[:cpu_usage_interval] if options[:cpu_usage_interval]
          c.above      = options[:max_cpu_usage]
          c.times      = 5
          c.notify     = options[:restart_notify] if options[:restart_notify]
        end if options[:max_cpu_usage]
      end
    end

    # Define lifecycle
    def setup_lifecycle watcher
      watcher.lifecycle do |on|
        on.condition(:flapping) do |c|
          c.to_state     = [:start, :restart]
          c.times        = 5
          c.within       = options[:flapping_window]   || 15.minute
          c.transition   = :unmonitored
          c.retry_in     = options[:flapping_retry_in] || 30.minutes
          c.retry_times  = 5
          c.retry_within = 4.hours
          c.notify       = options[:flapping_notify] if options[:flapping_notify]
        end
      end
    end

    # ===========================================================================
    #
    # Configuration
    #

    #
    # string holding name for this process type, eg 'mongrel' or 'starling'
    #
    # Unless told otherwise, uses the class_name -- MongrelRecipe
    #
    def self.recipe_name
      @recipe_name ||= recipe_name_from_class_name
    end
    # calls back to self.class.recipe_name
    def recipe_name() self.class.recipe_name ;  end

    def self.recipe_name_from_class_name
      self.to_s.underscore.demodulize.
        gsub(%r{.*\/+},   '').  # remove module portion
        gsub(%r{_recipe}, '')   # remove _recipe part
    end

    # unique label for this process
    def handle
      [recipe_name, options[:port]].compact.map(&:to_s).join('_')
    end

    #
    # Starts with the portion of the global_options dealing with this class then
    # walks upwards through the inheritance tree, accumulating default options.
    #
    # Subclasses should override with something like
    #
    #     def self.default_options
    #       super.deep_merge(ThisClass::DEFAULT_OPTIONS)
    #     end
    #
    def self.default_options
      GodRecipe::DEFAULT_OPTIONS.deep_merge(global_options[recipe_name] || {})
    end

    #
    # load a series of YAML-format options files
    #
    # Later files win out over earlier files
    #
    def self.options_from_files *options_filenames
      options = {}
      options_filenames.each do |options_filename|
        options.deep_merge! YAML.load_file(options_filename)
      end
      options
    end


    # ===========================================================================
    #
    # helpers
    #

    # by default, groups by process -- you may want to instead group by project
    def monitor_group
      options[:monitor_group].to_s || recipe_name.pluralize
    end

    # by default, uses :pid_dir/:recipe_name_:port.pid
    def pid_file
      return nil if (options[:pid_file] == false)
      options[:pid_file] || File.join(options[:pid_dir], "#{recipe_name}_#{options[:port]}.pid")
    end

    # command to start the daemon
    def start_command
      options[:start_command]
    end
    # command to stop the daemon
    # return nil to have god daemonize the process
    def stop_command
      options[:stop_command]
    end
    # command to restart
    # if stop_command is nil, it lets god daemonize the process
    # otherwise, by default it runs stop_command, pauses for 1 second, then runs start_command
    def restart_command
      return unless stop_command
      [stop_command, "sleep 1", start_command].join(" && ")
    end

    # Default log filename
    def process_log_file
      File.join(options[:process_log_dir], handle+".log")
    end

    # Default error log filename.
    def process_err_log_file
      process_log_file
    end

    # create any directories required by the process
    def mkdirs!
      require 'fileutils'
      FileUtils.mkdir_p File.dirname(process_log_file)
      FileUtils.mkdir_p File.dirname(options[:pid_file]) unless options[:pid_file].blank?
    end

  end
end
