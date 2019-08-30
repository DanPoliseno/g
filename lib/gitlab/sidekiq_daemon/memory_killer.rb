# frozen_string_literal: true

module Gitlab
  module SidekiqDaemon
    class MemoryKiller < Daemon
      include ::Gitlab::Utils::StrongMemoize

      # Today 64-bit CPU support max 256T memory. It is big enough.
      MAX_MEMORY_KB = 256 * 1024 * 1024 * 1024
      # RSS below `soft_limit_rss` is considered safe
      SOFT_LIMIT_RSS_KB = ENV.fetch('SIDEKIQ_MEMORY_KILLER_MAX_RSS', 2000000).to_i
      # RSS above `hard_limit_rss` will be stopped
      HARD_LIMIT_RSS_KB = ENV.fetch('SIDEKIQ_MEMORY_KILLER_HARD_LIMIT_RSS', MAX_MEMORY_KB).to_i
      # RSS in range (soft_limit_rss, hard_limit_rss) is allowed for GRACE_BALLOON_SECONDS
      GRACE_BALLOON_SECONDS = ENV.fetch('SIDEKIQ_MEMORY_KILLER_GRACE_BALLOON_TIME', 15 * 60).to_i
      # Check RSS every CHECK_INTERVAL_SECONDS, minimum 2 seconds
      CHECK_INTERVAL_SECONDS = [ENV.fetch('SIDEKIQ_MEMORY_KILLER_CHECK_INTERVAL', 3).to_i, 2].max
      # Give Sidekiq up to 15 minutes of grace time to allow existing jobs to finish after exceeding the limit
      GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS = ENV.fetch('SIDEKIQ_MEMORY_KILLER_GRACE_TIME', 15 * 60).to_i
      # Give Sidekiq up to 30 seconds to interrupt all running jobs and shutdown
      SHUTDOWN_TIMEOUT_SECONDS = ENV.fetch('SIDEKIQ_MEMORY_KILLER_SHUTDOWN_WAIT', 30).to_i

      def initialize
        super

        @enabled = true
      end

      private

      def start_working
        Sidekiq.logger.info(
          class: self.class.to_s,
          action: 'start',
          pid: pid,
          message: 'Starting Gitlab::SidekiqDaemon::MemoryKiller Daemon'
        )

        while enabled?
          begin
            restart_sidekiq unless rss_within_range?
            sleep(CHECK_INTERVAL_SECONDS)
          rescue => e
            log_exception(e, __method__)
          rescue Exception => e # rubocop:disable Lint/RescueException
            log_exception(e, __method__ )
            raise e
          end
        end
      ensure
        Sidekiq.logger.warn(
          class: self.class.to_s,
          action: 'stop',
          pid: pid,
          message: 'Stopping Gitlab::SidekiqDaemon::MemoryKiller Daemon'
        )
      end

      def log_exception(exception, method)
        Sidekiq.logger.warn(
          class: self.class.to_s,
          pid: pid,
          message: "Exception from #{method}: #{exception.message}"
        )
      end

      def stop_working
        @enabled = false
      end

      def enabled?
        @enabled
      end

      def restart_sidekiq
        # Tell Sidekiq to stop fetching new jobs
        # We first SIGNAL and then wait given time
        # We also monitor a number of running jobs and allow to restart early
        signal_and_wait(GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS, 'SIGTSTP', 'stop fetching new jobs')
        return unless enabled?

        # Tell sidekiq to restart itself
        signal_and_wait(SHUTDOWN_TIMEOUT_SECONDS, 'SIGTERM', 'gracefully shut down')
        return unless enabled?

        # Ideally we should never reach this condition
        # Wait for Sidekiq to shutdown gracefully, and kill it if it didn't
        # Kill the whole pgroup, so we can be sure no children are left behind
        # Keep extra safe to wait `Sidekiq.options[:timeout] + 2` seconds before SIGKILL
        signal_pgroup(Sidekiq.options[:timeout] + 2, 'SIGKILL', 'die')
      end

      def rss_within_range?
        current_rss = nil
        deadline = Time.now + GRACE_BALLOON_SECONDS.seconds
        loop do
          return true unless enabled?

          current_rss = get_rss

          # RSS go above hard limit should trigger forcible shutdown right away
          break if current_rss > hard_limit_rss

          # RSS go below the soft limit
          return true if current_rss < soft_limit_rss

          # RSS did not go below the soft limit within deadline, restart
          break if Time.now > deadline

          sleep(CHECK_INTERVAL_SECONDS)
        end

        log_rss_out_of_range(current_rss, hard_limit_rss, soft_limit_rss)

        false
      end

      def log_rss_out_of_range(current_rss, hard_limit_rss, soft_limit_rss)
        Sidekiq.logger.warn(
          class: self.class.to_s,
          pid: pid,
          message: 'Sidekiq worker rss out of range',
          reason: out_of_range_description(current_rss, hard_limit_rss, soft_limit_rss)
        )
      end

      def out_of_range_description(rss, hard_limit, soft_limit)
        if rss > hard_limit
          "current_rss(#{rss}) > hard_limit_rss(#{hard_limit})"
        else
          "current_rss(#{rss}) > soft_limit_rss(#{soft_limit}) longer than GRACE_BALLOON_SECONDS(#{GRACE_BALLOON_SECONDS})"
        end
      end

      def get_rss
        output, status = Gitlab::Popen.popen(%W(ps -o rss= -p #{pid}), Rails.root.to_s)
        return 0 unless status&.zero?

        output.to_i
      end

      def soft_limit_rss
        SOFT_LIMIT_RSS_KB + rss_increase_by_jobs
      end

      def hard_limit_rss
        HARD_LIMIT_RSS_KB
      end

      def signal_and_wait(time, signal, explanation)
        Sidekiq.logger.warn(
          class: self.class.to_s,
          pid: pid,
          message: "sending Sidekiq worker #{signal} (#{explanation}). Then wait at most #{time} seconds."
        )
        Process.kill(signal, pid)

        deadline = Time.now + time

        # we try to finish as early as all jobs finished
        # so we retest that in loop
        sleep(CHECK_INTERVAL_SECONDS) while enabled? && any_jobs? && Time.now < deadline
      end

      def signal_pgroup(time, signal, explanation)
        if Process.getpgrp == pid
          pid_or_pgrp_str = 'PGRP'
          pid_to_signal = 0
        else
          pid_or_pgrp_str = 'PID'
          pid_to_signal = pid
        end

        Sidekiq.logger.warn(
          class: self.class.to_s,
          signal: signal,
          pid: pid,
          message: "waiting #{time} seconds before sending Sidekiq worker #{pid_or_pgrp_str}-#{pid} #{signal} (#{explanation})"
        )
        sleep(time)

        Sidekiq.logger.warn(
          class: self.class.to_s,
          signal: signal,
          pid: pid,
          message: "sending Sidekiq worker #{pid_or_pgrp_str}-#{pid} #{signal} (#{explanation})"
        )
        Process.kill(signal, pid_to_signal)
      end

      def rss_increase_by_jobs
        Gitlab::SidekiqDaemon::Monitor.instance.jobs.sum do |job| # rubocop:disable CodeReuse/ActiveRecord
          rss_increase_by_job(job)
        end
      end

      def rss_increase_by_job(job)
        memory_growth_kb = get_job_options(job, 'memory_killer_memory_growth_kb', 0).to_i
        max_memory_growth_kb = get_job_options(job, 'memory_killer_max_memory_growth_kb', MAX_MEMORY_KB).to_i

        return 0 if memory_growth_kb.zero?

        time_elapsed = Time.now.to_i - job[:started_at]
        [memory_growth_kb * time_elapsed, max_memory_growth_kb].min
      end

      def get_job_options(job, key, default)
        job[:worker_class].sidekiq_options.fetch(key, default)
      rescue
        default
      end

      def pid
        Process.pid
      end

      def any_jobs?
        Gitlab::SidekiqDaemon::Monitor.instance.jobs.any?
      end
    end
  end
end
