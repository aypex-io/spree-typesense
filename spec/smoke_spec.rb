require 'spec_helper'

RSpec.describe Spree::Typesense do
  it 'has a version' do
    expect(Spree::Typesense::VERSION).to match(/\A\d+\.\d+\.\d+(\.(alpha|beta|rc)\d+)?\z/)
  end

  it 'can reach the Typesense server' do
    expect(typesense_client.health.retrieve).to include('ok' => true)
  end
end
