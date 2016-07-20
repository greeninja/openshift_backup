#!/usr/bin/env ruby

require 'sinatra'

set :bind, '0.0.0.0'
set :port, '8080'

get '/health' do
  '<html><body>OK</body></html>'
end

get '/' do
  cache_file = '/dev/shm/status_cache'
  if !File.exist?(cache_file) || (File.mtime(cache_file) < (Time.now - 60*15)) # cache result for 15 minutes
    data = `/backup_script.rb status`
    File.open(cache_file,"w"){ |f| f << data }
  end
  "<html><body>#{File.read(cache_file)}</body></html>"
end

