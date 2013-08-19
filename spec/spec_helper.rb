require 'simplecov'
require 'redis'
require 'rails'
require 'action_view'
require 'active_support/core_ext/numeric/time'
require 'curb'
require 'timecop'
require 'ostruct'

SimpleCov.start
require_relative "../lib/redis_template_resolver"

RSpec.configure do |config|
  config.order = "random"
  config.mock_with :rspec

  config.before( :each ) do
    logger = double( "Logger" ).as_null_object
    Rails.logger = logger
  end
end
