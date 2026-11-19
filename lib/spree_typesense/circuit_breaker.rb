require 'concurrent/map'

module SpreeTypesense
  # Remembers, for the process, that Typesense is failing, so searches stop
  # waiting out its timeout before falling back. Each request builds a new
  # provider and client, so without this every search during an outage waits
  # the full search timeout and is logged and reported.
  #
  # Closed: requests go through, and transient failures in a row are counted.
  # At the threshold it opens: requests are refused (the caller answers from
  # the Database provider) for `open_seconds`. Then it is half-open: exactly
  # one request is let through to probe; success closes it, failure opens it
  # for another period.
  #
  # Per process and in memory, so each server process learns on its own.
  class CircuitBreaker
    DEFAULT_THRESHOLD = 3
    DEFAULT_OPEN_SECONDS = 30

    REGISTRY = Concurrent::Map.new
    private_constant :REGISTRY

    # The breaker for a Typesense URL, made on first use with the threshold
    # and period TYPESENSE_BREAKER_THRESHOLD and TYPESENSE_BREAKER_SECONDS
    # give, when they are positive numbers.
    #
    # @param key [String] the Typesense URL
    # @return [CircuitBreaker]
    def self.for(key)
      REGISTRY.compute_if_absent(key.to_s) { new(threshold: configured_threshold, open_seconds: configured_open_seconds) }
    end

    # Forgets every breaker (tests).
    def self.reset_all! = REGISTRY.clear

    def self.configured_threshold
      value = Integer(ENV.fetch('TYPESENSE_BREAKER_THRESHOLD', nil), exception: false)
      value&.positive? ? value : DEFAULT_THRESHOLD
    end

    def self.configured_open_seconds
      value = Float(ENV.fetch('TYPESENSE_BREAKER_SECONDS', nil), exception: false)
      value&.positive? ? value : DEFAULT_OPEN_SECONDS
    end

    attr_reader :threshold, :open_seconds

    # @param threshold [Integer] transient failures in a row that open it
    # @param open_seconds [Numeric] how long it stays open
    # @param clock [#call] monotonic seconds
    def initialize(threshold:, open_seconds:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @threshold = threshold
      @open_seconds = open_seconds
      @clock = clock
      @mutex = Mutex.new
      @open = false
      @failures = 0
      @opened_at = nil
      @probing = false
    end

    # @return [Symbol] :closed, :open or :half_open
    def state
      @mutex.synchronize { current_state }
    end

    # Whether this request may go to Typesense. Half-open, only the first
    # caller may, as the probe.
    # @return [Boolean]
    def allow_request?
      @mutex.synchronize do
        case current_state
        when :closed then true
        when :open then false
        else
          next false if @probing

          @probing = true
        end
      end
    end

    # Typesense answered.
    # @return [Symbol, nil] :closed when this closed an open breaker
    def record_success
      @mutex.synchronize do
        was_open = @open
        @open = false
        @failures = 0
        @opened_at = nil
        @probing = false
        :closed if was_open
      end
    end

    # Typesense failed transiently.
    # @return [Symbol, nil] :opened when this opened it (or the probe failed)
    def record_failure
      @mutex.synchronize do
        if @open
          # A request let through before it opened; only the probe counts.
          next nil unless @probing
        else
          @failures += 1
          next nil if @failures < @threshold
        end

        @open = true
        @opened_at = @clock.call
        @failures = 0
        @probing = false
        :opened
      end
    end

    # The probe ended in neither success nor failure (an error that is not
    # Typesense's): let the next request probe instead.
    def release_probe
      @mutex.synchronize { @probing = false }
    end

    private

    def current_state
      return :closed unless @open

      @clock.call - @opened_at >= @open_seconds ? :half_open : :open
    end
  end
end
