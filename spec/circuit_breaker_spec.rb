require 'spec_helper'

RSpec.describe SpreeTypesense::CircuitBreaker do
  let(:now) { [1_000.0] }
  let(:breaker) { described_class.new(threshold: 3, open_seconds: 30, clock: -> { now.first }) }

  def advance(seconds) = now[0] += seconds
  def fail_times(count) = count.times.map { breaker.record_failure }

  it 'starts closed and lets requests through' do
    expect(breaker.state).to eq(:closed)
    expect(breaker.allow_request?).to be(true)
  end

  it 'stays closed below the threshold' do
    fail_times(2)

    expect(breaker.state).to eq(:closed)
    expect(breaker.allow_request?).to be(true)
  end

  it 'counts only failures in a row: a success resets the count' do
    fail_times(2)
    breaker.record_success
    fail_times(2)

    expect(breaker.state).to eq(:closed)
  end

  it 'opens at the threshold, saying so once, and stops letting requests through' do
    expect(fail_times(3)).to eq([nil, nil, :opened])
    expect(breaker.state).to eq(:open)
    expect(breaker.allow_request?).to be(false)
  end

  it 'ignores failures of requests already in flight when it opened' do
    fail_times(3)

    expect(breaker.record_failure).to be_nil
    expect(breaker.state).to eq(:open)
  end

  describe 'once the period has passed' do
    before do
      fail_times(3)
      advance(30)
    end

    it 'lets exactly one request through to probe' do
      expect(breaker.state).to eq(:half_open)
      expect(breaker.allow_request?).to be(true)
      expect(breaker.allow_request?).to be(false)
    end

    it 'closes when the probe succeeds, saying so' do
      breaker.allow_request?

      expect(breaker.record_success).to eq(:closed)
      expect(breaker.allow_request?).to be(true)
    end

    it 're-opens for another period when the probe fails' do
      breaker.allow_request?

      expect(breaker.record_failure).to eq(:opened)
      expect(breaker.allow_request?).to be(false)
      advance(29)
      expect(breaker.allow_request?).to be(false)
      advance(1)
      expect(breaker.allow_request?).to be(true)
    end

    it 'lets another request probe when the probe ended in neither' do
      breaker.allow_request?
      breaker.release_probe

      expect(breaker.allow_request?).to be(true)
    end

    it 'lets exactly one of many threads probe' do
      allowed = Array.new(20) { Thread.new { breaker.allow_request? } }.map(&:value)

      expect(allowed.count(true)).to eq(1)
    end
  end

  it 'says nothing when a success finds it closed already' do
    expect(breaker.record_success).to be_nil
  end

  describe '.for' do
    before { described_class.reset_all! }
    after { described_class.reset_all! }

    it 'keeps one breaker per Typesense URL for the process' do
      expect(described_class.for('http://a:8108')).to be(described_class.for('http://a:8108'))
      expect(described_class.for('http://a:8108')).not_to be(described_class.for('http://b:8108'))
    end

    it 'takes its threshold and period from the environment' do
      with_env('TYPESENSE_BREAKER_THRESHOLD' => '5', 'TYPESENSE_BREAKER_SECONDS' => '12.5') do
        breaker = described_class.for('http://env:8108')

        expect(breaker.threshold).to eq(5)
        expect(breaker.open_seconds).to eq(12.5)
      end
    end

    it 'defaults to 3 failures and 30 seconds when unset or not a positive number' do
      with_env('TYPESENSE_BREAKER_THRESHOLD' => 'lots', 'TYPESENSE_BREAKER_SECONDS' => '-1') do
        breaker = described_class.for('http://default:8108')

        expect(breaker.threshold).to eq(3)
        expect(breaker.open_seconds).to eq(30)
      end
    end
  end
end
