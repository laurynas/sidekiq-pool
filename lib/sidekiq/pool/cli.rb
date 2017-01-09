require 'sidekiq/cli'
require 'sidekiq/pool/version'

module Sidekiq
  module Pool
    class CLI < Sidekiq::CLI
      def initialize
        @child_index = 0
        @pool = []
        @done = false
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

      def start_new_pool
        logger.info 'Starting new pool'
        @settings = parse_config_file(@pool_config)
        working_directory = @working_directory || @settings[:working_directory]
        Dir.chdir(working_directory) if working_directory
        @types = @settings[:workers]
        @types.each do |type|
          type[:amount].times do
            fork_wait = @fork_wait || DEFAULT_FORK_WAIT
            times_to_wait_for_alive ||= (fork_wait * 3)
            pid = add_child(type[:command])

            until alive?(pid)
              break if (times_to_wait_for_alive -= 1).zero?
              sleep fork_wait
            end
          end
        end
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

        %w(INT TERM USR1 USR2 CHLD HUP).each do |sig|
          begin
            trap sig do
              @self_write.puts(sig) unless fork?
            end
          rescue ArgumentError
            puts "Signal #{sig} not supported"
          end
        end
      end

      def fork_child(command)
        pid = fork do
          opts = parse_options(command.split)
          options.merge!(opts)

          @self_write.close
          $0 = 'sidekiq starting'
          options[:index] = @child_index++
          run_child
        end
        @pool << { pid: pid, command: command }
        pid
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
        when 'USR1'
          @done = true
          update_process_name
          signal_to_pool(sig)
        when 'USR2'
          logger.info "Sending #{sig} signal to the pool"
          signal_to_pool(sig)
        when 'HUP'
          logger.info 'Gracefully reloading pool'
          old_pool = @pool.dup

          # Signal old pool
          # USR1 tells Sidekiq it will be shutting down in near future.
          signal_to_pool('USR1')

          # Reset pool
          @pool = []

          # Start new pool
          start_new_pool

          # Stop old pool
          stop_children(old_pool)
          logger.info 'Graceful reload completed'
        end
      end

      def add_child(*arg)
        logger.info "Adding child with args: #{arg}"
        fork_child(*arg)
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
        add_child(child[:command])
      end

      def alive?(pid)
        ::Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
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
