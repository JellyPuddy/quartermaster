# frozen_string_literal: true

module Quartermaster
  # The GUI's long actions, run on server threads and never under the action
  # mutex. Distills run here because `claude -p` takes minutes per transcript,
  # and holding the action mutex for that long queued every other action (a
  # state change waited on the distill and the page looked hung). Running
  # distills are keyed by slug; finished ones wait until a state build hands
  # them to the page once.
  #
  # The other long actions (pf switch, worktree creation, cleanup) run the
  # same way: one job per key — the slug, or "sweep" / "pf" for the global
  # ones — its label shown as a badge until a state build hands out the
  # result once.
  class GuiJobs
    def initialize
      @lock = Mutex.new
      @distilling = {}
      @distilled = []
      @running = {}
      @finished = []
      @progress = {}
    end

    # Runs the block on a thread unless its key already has a job, or it
    # needs the dev server while another such job runs — it is one shared server.
    def background(key, label, pf: false)
      @lock.synchronize do
        return { "ok" => false, "error" => "#{key} is still busy: #{@running[key]["label"]}" } if @running[key]

        if pf && (other = @running.values.find { |job| job["pf"] })
          return { "ok" => false, "error" => "the dev server is busy (#{other["key"]}: #{other["label"]})" }
        end

        @running[key] = { "key" => key, "label" => label, "pf" => pf }
      end
      Thread.new do
        result = begin
          yield
        rescue ArgumentError => e
          { "ok" => false, "error" => e.message }
        rescue StandardError => e
          Quartermaster.log_error("gui-job", e)
          { "ok" => false, "error" => e.message }
        end
        @lock.synchronize do
          @running.delete(key)
          @finished << result.merge("key" => key, "label" => label)
        end
      end
      { "ok" => true, "background" => true }
    end

    # A running job's badge says what it waits on now.
    def relabel(key, label)
      @lock.synchronize { @running[key]&.store("label", label) }
    end

    def running
      @lock.synchronize { @running.values.map(&:dup) }
    end

    def take_finished
      @lock.synchronize { @finished.dup.tap { @finished.clear } }
    end

    # The newest build-progress estimate per slug (BuildProgress), kept in
    # memory only: a new click replaces it, a GUI restart forgets it.
    def store_progress(slug, result)
      @lock.synchronize { @progress[slug] = result }
    end

    def progress
      @lock.synchronize { @progress.dup }
    end

    # False when the slug is already being distilled.
    def start_distill(slug, sessions)
      @lock.synchronize do
        return false if @distilling.key?(slug)

        @distilling[slug] = sessions
      end
      true
    end

    def finish_distill(slug, result)
      @lock.synchronize do
        @distilling.delete(slug)
        @distilled << result.merge("slug" => slug)
      end
    end

    def distilling_slugs
      @lock.synchronize { @distilling.keys }
    end

    def take_distilled
      @lock.synchronize { @distilled.dup.tap { @distilled.clear } }
    end
  end
end
