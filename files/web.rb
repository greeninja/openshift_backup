#!/usr/bin/env ruby

require 'sinatra'

set :bind, '0.0.0.0'
set :port, '8080'

get '/' do
  `/backup_script.rb status`
end
