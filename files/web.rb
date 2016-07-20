#!/usr/bin/env ruby

require 'sinatra'

set :bind, '0.0.0.0'
set :port, '8080'

get '/' do
  cache_file = '/status_cache'
  if !File.exist?(cache_file) || (File.mtime(cache_file) < (Time.now - 60*60)) # cache result for an hour
    data = `/backup_script.rb status`
    File.open(cache_file,"w"){ |f| f << data }
  end
  "<html><body>#{File.read(cache_file)}</body></html>"
end

get '/health' do
  '<html><body>OK</body></html>'
end
