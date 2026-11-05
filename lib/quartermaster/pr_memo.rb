# frozen_string_literal: true

module Quartermaster
  # What the diff pane's PR scope learned from the network, remembered by the
  # GUI process for TTL seconds: which PR a branch's lookup found
  # (PrRevisions#find) and where its fetch left the head and base
  # (PrRevisions#fetch). Selecting another of the PR's commits then needs
  # neither gh nor git fetch. In memory only, shared across request threads.
  class PrMemo
    TTL = 60

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @entries = {}
      @lock = Mutex.new
    end

    # The remembered value for key while younger than TTL and `usable` agrees,
    # else the block's (remembered unless nil, or unless a call that started
    # later already remembered its own). fresh: always the block's. The block
    # runs outside the lock.
    def fetch(key, fresh: false, usable: ->(_value) { true })
      started = @clock.call
      unless fresh
        hit = @lock.synchronize { @entries[key] }
        return hit[:value] if hit && started - hit[:at] < TTL && usable.call(hit[:value])
      end

      value = yield
      @lock.synchronize { remember(key, value, started) }
      value
    end

    private

    def remember(key, value, started)
      @entries.delete_if { |_key, entry| started - entry[:at] >= TTL }
      return if (newer = @entries[key]) && newer[:started] > started

      value.nil? ? @entries.delete(key) : @entries[key] = { value: value, at: @clock.call, started: started }
    end
  end
end
