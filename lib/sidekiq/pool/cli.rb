require 'sidekiq/cli'
require 'sidekiq/pool'

module Sidekiq
  module Pool
    class CLI < Sidekiq::CLI

      START_CTX = {
        :argv => ARGV.map(&:dup),
        0 => $0.dup,
      }

      def initialize
        @pool = []
        @done = false
        @system_booted = false
        super
      end

      alias_method :run_child, :run

      def run
        @master_pid = $$

        trap_signals
        update_process_name
        start_new_pool

        wait_for_signals
      end

      def parse_config_file(filename)
        config = YAML.load(ERB.new(File.read(filename)).result)
        unless config.key?(:workers)
          raise ArgumentError, 'Invalid configuration file - "workers" key must be present'
        end
        unless config[:workers].is_a?(Array)
          raise ArgumentError, 'Invalid configuration file - "workers" key must be a list'
        end
        unless config[:workers].size > 0
          raise ArgumentError, 'Invalid configuration file - Atleast one worker must be present'
        end
        config
      end

      private

      DEFAULT_FORK_WAIT = 1

      def boot_system
        if @system_booted
          logger.info "#{::Process.pid} - environment already started"
        else
          super
          @system_booted = true
        end
      end

      def working_directory
        @working_directory || @settings[:working_directory]
      end

      def start_new_pool
        logger.info 'Starting new pool'
        @settings = parse_config_file(@pool_config)
        Dir.chdir(working_directory) if working_directory

        boot_system

        @types = @settings[:workers]
        @types.each do |type|
          type[:amount].times do |i|
            sleep @fork_wait || DEFAULT_FORK_WAIT
            fork_child(type[:command], i+1)
          end
        end
        drop_reload_marker
      end

      def parse_options(argv)
        opts = {}

        @parser = OptionParser.new do |o|
          o.on '-c', '--concurrency INT', "processor threads to use" do |arg|
            opts[:concurrency] = Integer(arg)
          end

          o.on '-d', '--daemon', "Daemonize process" do |arg|
            opts[:daemon] = arg
          end

          o.on '-e', '--environment ENV', "Application environment" do |arg|
            opts[:environment] = arg
          end

          o.on '-g', '--tag TAG', "Process tag for procline" do |arg|
            opts[:tag] = arg
          end

          o.on "-q", "--queue QUEUE[,WEIGHT]", "Queues to process with optional weights" do |arg|
            queue, weight = arg.split(",")
            parse_queue opts, queue, weight
          end

          o.on '-r', '--require [PATH|DIR]', "Location of Rails application with workers or file to require" do |arg|
            opts[:require] = arg
          end

          o.on '-t', '--timeout NUM', "Shutdown timeout" do |arg|
            opts[:timeout] = Integer(arg)
          end

          o.on "-v", "--verbose", "Print more verbose output" do |arg|
            opts[:verbose] = arg
          end

          o.on '-w', '--fork-wait NUM', "seconds to wait between child forks, default #{DEFAULT_FORK_WAIT}" do |arg|
            @fork_wait = Integer(arg)
          end

          o.on '-C', '--config PATH', "path to YAML config file" do |arg|
            opts[:config_file] = arg
          end

          o.on '-L', '--logfile PATH', "path to writable logfile" do |arg|
            opts[:logfile] = arg
          end

          o.on '-P', '--pidfile PATH', "path to pidfile" do |arg|
            opts[:pidfile] = arg
          end

          o.on '-p', '--pool-config PATH', "path to pool config file" do |arg|
            @pool_config = arg
          end

          o.on '--working-directory PATH', "path to working directory" do |arg|
            unless Dir.exist?(arg)
              puts "Provided directory #{arg} does not exist"
              die(1)
            end
            @working_directory = arg
          end

          o.on '--wait-until-child-loaded NUM', "Seconds to wait until forked child is busy" do |arg|
            @wait_until_child_loaded = Integer(arg)
          end

          o.on '--suspend-before-graceful-reload', "Send USR1 singal to old pool when doing graceful reload" do |arg|
            @suspend_before_graceful_reload = arg
          end

          o.on '-V', '--version', "Print version and exit" do |arg|
            puts "Sidekiq #{Sidekiq::VERSION}"
            die(0)
          end
        end

        @parser.banner = 'sidekiq-pool [options]'
        @parser.on_tail '-h', '--help', 'Show help' do
          logger.info @parser
          die 1
        end
        @parser.parse!(argv)

        %w[config/sidekiq.yml config/sidekiq.yml.erb].each do |filename|
          opts[:config_file] ||= filename if File.exist?(filename)
        end

        %w[config/sidekiq-pool.yml config/sidekiq-pool.yml.erb].each do |filename|
          @pool_config ||= filename if File.exist?(filename)
        end

        opts
      end

      def trap_signals
        @self_read, @self_write = IO.pipe

        %w(INT TERM USR1 TSTP USR2 CHLD HUP).each do |sig|
          begin
            trap sig do
              @self_write.puts(sig) unless fork?
            end
          rescue ArgumentError
            puts "Signal #{sig} not supported"
          end
        end
      end

      def fork_child(command, child_index, wait_for_busy = true)
        logger.info "Adding child with args: (#{command}) in #{working_directory}, waiting for busy: #{wait_for_busy}"
        if working_directory && !Dir.exist?(working_directory)
          logger.info "Working directory: #{working_directory} does not exist unable to fork"
          return
        end

        pid = fork do
          Dir.chdir(working_directory) if working_directory
          opts = parse_options(command.split)
          options.merge!(opts)

          @self_write.close
          $0 = 'sidekiq starting'
          options[:index] = child_index

          # reset child identity
          @@process_nonce = nil
          @@identity = nil
          options[:identity] = identity

          run_after_fork_hooks
          run_child
        end

        wait_until_child_loaded ||= (@wait_until_child_loaded || 30)

        until cmdline_busy?(pid)
          break if (wait_until_child_loaded -= 1).zero?
          logger.info "Waiting for child #{pid} to be busy break in #{wait_until_child_loaded}"
          sleep 1
        end if wait_for_busy

        @pool << { pid: pid, index: child_index, command: command }
      end

      def wait_for_signals
        while readable_io = IO.select([@self_read])
          signal = readable_io.first[0].gets.strip
          handle_master_signal(signal)
        end
      end

      def handle_master_signal(sig)
        case sig
        when 'INT', 'TERM'
          stop_children
          logger.info 'Bye!'
          exit(0)
        when 'CHLD'
          check_pool
        when 'USR1', 'TSTP'
          @done = true
          update_process_name
          signal_to_pool(sig)
        when 'USR2'
          logger.info "Sending #{sig} signal to the pool"
          signal_to_pool(sig)
        when 'HUP'
          reload
        end
      end

      def reload
        logger.info 'Gracefully reloading pool'

        # USR1 tells Sidekiq it will be shutting down in near future.
        signal_to_pool('USR1') if @suspend_before_graceful_reload

        add_reload_marker
        reexec

        stop_children
        logger.info 'Graceful reload completed'
      ensure
        exit(0)
      end

      def reexec
        fork do
          cmd = [START_CTX[0]].concat(START_CTX[:argv])
          logger.info("Starting new master process #{cmd}")
          exec(*cmd)
        end
      end

      def run_after_fork_hooks
        Sidekiq::Pool.after_fork_hooks.each(&:call)
      end

      def add_reload_marker
        return unless options[:pidfile]
        File.write([options[:pidfile], '.reload'].join, '')
      end

      def drop_reload_marker
        reload_marker = [options[:pidfile], '.reload'].join
        File.unlink(reload_marker) if File.exist?(reload_marker)
      end

      def signal_to_pool(sig, given_pool = @pool)
        given_pool.each { |child| signal_to_child(sig, child[:pid]) }
      end

      def signal_to_child(sig, pid)
        ::Process.kill(sig, pid)
      rescue Errno::ESRCH
        @pool.delete(pid)
      end

      def check_pool
        ::Process.waitpid2(-1, ::Process::WNOHANG)
        @pool.each do |child|
          next if alive?(child[:pid])
          handle_dead_child(child)
        end
      end

      def handle_dead_child(child)
        logger.info "Child #{child[:pid]} died"
        @pool.delete(child)
        fork_child(child[:command], child[:index], false)
      end

      def alive?(pid)
        ::Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end

      def cmdline_busy?(pid)
        return unless alive?(pid)
        path = "/proc/#{pid}/cmdline"
        return unless File.exists?(path)
        cmdline = File.read(path)
        return if cmdline.empty?
        !cmdline.scan(/busy\]/).empty?
      end

      def stop_children(given_pool = @pool)
        @done = true
        logger.info 'Stopping children'
        update_process_name

        time = Time.now
        loop do
          wait_time = (Time.now - time).to_i
          if wait_time > options[:timeout] + 2
            logger.warn("Children didn't stop in #{wait_time}s, killing")
            signal_to_pool('KILL', given_pool)
          else
            signal_to_pool('TERM', given_pool)
          end
          sleep(1)
          ::Process.waitpid2(-1, ::Process::WNOHANG)
          break if given_pool.none? { |child| alive?(child[:pid]) }
        end
      end

      def fork?
        $$ != @master_pid
      end

      def stopping?
        @done
      end

      def update_process_name
        parts = [
          'sidekiq-pool',
          Sidekiq::Pool::VERSION,
          options[:tag]
        ]

        parts << 'stopping' if stopping?

        $0 = parts.compact.join(' ')
      end
    end
  end
end
