#!/usr/bin/env ruby
require 'yaml'
require 'pp'

#ret = system('oc login https://openshift-cluster.fhpaas.fasthosts.co.uk:8443 --token=$(cat /run/secrets/kubernetes.io/serviceaccount/token)')
#puts ret

pods_to_backup = {
  'paas-staging' => {
    'custapi-mysql':            { 'type' => 'mysql'   },
    'clusterbuilder':           { 'type' => 'unknown' },
    'etcd':                     { 'type' => 'unknown' },
    'fitnesse':                 { 'type' => 'rsync', 'src_paths' => [ '/opt/fitnesse/FitNesseRoot', ] },
  },
  'library' => {
    'dependencygraph-mysql':    { 'type' => 'mysql' },
    'gogs-mysql':               { 'type' => 'mysql' },
    'image-drone-mysql':        { 'type' => 'mysql' },
    'template-drone-mysql':     { 'type' => 'mysql' },
    'templaterepository-mysql': { 'type' => 'mysql' },
    'templateupdater-mysql':    { 'type' => 'mysql' },
  },
}

def etcd_backup (pod)
  puts "No idea how to back up etcd so doing nothing"
  return -1
end

def unknown_backup (pod)
  puts "No idea how to back up unknown so doing nothing"
  return -1
end

def rsync_backup (pod)
  pod_name = pod['items'][0]['metadata']['name']

  if pod['src_paths'] then
    source_paths = pod['src_paths'].join(' ')
  else
    source_paths = '/'
  end

  backup_cmd = "oc exec -n #{pod['project']} #{pod_name} -- bash -c 'tar czf - #{source_paths}' 2> #{pod_name}.log 1> #{pod_name}.tar.gz"
  puts "Running: #{backup_cmd}"

  system("echo #{backup_cmd} > #{pod_name}.cmd")

  ret = system(backup_cmd)
  return ret
end

def mysql_backup (pod)

  pod_name = pod['items'][0]['metadata']['name']

  root_pw = ''
  pod['items'][0]['spec']['containers'].each do |c|
    pwenv = c['env'].select { |env| env['name'] == 'MYSQL_ROOT_PASSWORD' }
    root_pw = pwenv[0]['name'] unless pwenv.empty?
  end

    mysqldump_cmd = "mysqldump -u root --all-databases"
  unless root_pw.empty? then
    mysqldump_cmd += " -p$#{root_pw}"
  end

  backup_cmd = "oc exec  -n #{pod['project']} #{pod_name} -- bash -c '#{mysqldump_cmd}' 2> #{pod_name}.log | gzip > #{pod_name}.sql.gz"
  puts "Running: #{backup_cmd}"

  system("echo #{backup_cmd} > #{pod_name}.cmd")

  ret = system(backup_cmd)
  return ret
end

pod_hash = {}

pods_to_backup.each do |proj,pods|
  pods.each do |pod,v|
    pod_hash[pod] ||= {}
    pod_hash[pod] = YAML.load(`oc get pods -l="deploymentconfig=#{pod}" -n #{proj} -o yaml`)
    pod_hash[pod]['project'] = proj
    pod_hash[pod]['type'] = v['type']
    pod_hash[pod]['src_paths'] = v['src_paths']
  end
end

pod_hash.each do |name,v|
 puts "name: #{name}"
 puts "project: #{v['project']}"
 puts "type: #{v['type']}"
end

pod_hash.each do  |name,pod|
  puts "backing up pod #{name}"
  case pod['type']
    when 'mysql'
      mysql_backup pod
    when 'etcd'
      etcd_backup pod
    when 'rsync'
      rsync_backup pod
    when 'unknown'
      unknown_backup pod
  end
end

