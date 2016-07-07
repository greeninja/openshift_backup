#!/usr/bin/env ruby
require 'fileutils'
require 'yaml'
require 'pp'

# metadata required for backups on pods
# metadata.labels.needs_backup: yes
# metadata.labels.backup_type: mysql|rsync|etcd
# metadata.annotations.backup_src: /path/to/files/for/rsync (ignored for other backup types)

# backup destination tree
# project/dc/pod_name/container_name/yyyy-mm/
# each backup dir is a git repo

if ENV.include? 'DEBUG' then
  DEBUG=ENV['DEBUG']
else
  DEBUG=false
end
puts "debug: #{DEBUG}"


# NEED TO MAKE THIS BETTER
ret = system('oc status >/dev/null 2>&1')
unless ret then
  puts "Logging into openshift with serviceaccount" if DEBUG
  ret = system('oc login https://openshift-cluster.fhpaas.fasthosts.co.uk:8443 --token=$(cat /run/secrets/kubernetes.io/serviceaccount/token)')
  unless ret then
    puts "Unable to log into openshift"
    exit 1
  end
end

class PodBackup
  def initialize (pod_spec={}, backup_dest_root='.')
    # metadata should be the output from "oc get pod x -o yaml"
    @pod_spec = pod_spec
    @metadata = @pod_spec['metadata']
    @podname = @metadata['name']
    @project = @metadata['namespace']
    @backup_dest = "#{backup_dest_root}/#{@project}/#{@podname}"

    @backup_type = @metadata['labels']['backup_type']
    @backup_src = @metadata['annotations']['backup_src'].split(":") if @backup_type == 'rsync'
    @backup_src = @metadata['annotations']['backup_src'] if @backup_type == 'etcd'
    @backup_local_dest = @metadata['annotations']['backup_dest'] if @backup_type == 'etcd'
  end

  def container_backup_dir (container_name)
    return "#{@backup_dest}/#{container_name}/#{Time.now.strftime("%Y-%m")}"
  end

  def create_backup_dir (container_name)
    FileUtils.mkdir_p container_backup_dir(container_name), :mode => 0700
  end

  def commit_backup (dir)
    system "cd #{dir} && git init" unless Dir.exists? "#{dir}/.git"
    system "cd #{dir} && git add * && git commit -a -m 'Backup commited at #{Time.now}'"
  end

  def backup
    ret = -1
    @pod_spec['spec']['containers'].each do |container|
      create_backup_dir container['name']

      case @backup_type
        when 'mysql'
          puts "backing up mysql" if DEBUG
          ret = backup_mysql container
        when 'rsync'
          ret = backup_rsync container
        when 'etcd'
          puts "something etcd" if DEBUG
          ret = backup_etcd container
        else
          puts "no backup_type for #{container['name']}"
          next
      end
    commit_backup container_backup_dir(container['name'])
    end

    return ret
  end

  def backup_etcd (container)
    backup_path = "#{container_backup_dir container['name']}"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"
    backup_cmd = "oc exec -n #{@project} #{@podname} > #{logfile} 2>&1 -- /etcdctl backup --data-dir=#{@backup_src} --backup-dir=#{@backup_local_dest}"
    puts "Running: #{backup_cmd}" if DEBUG
    ret = system(backup_cmd)

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    puts "would run - #{backup_cmd}"
    return ret
  end

  def backup_mysql (container)

    backup_path = "#{container_backup_dir container['name']}"

    metapw = container['env'].select { |env| env['name'] == 'MYSQL_ROOT_PASSWORD' }
    begin
      root_pw = metapw[0]['name']
    rescue
      root_pw = ''
    end

    mysqldump_cmd = "mysqldump -u root --all-databases"
    mysqldump_cmd += " -p\\\$#{root_pw}" unless root_pw.empty?

    sqlfile = "#{backup_path}/#{container['name']}.sql"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"

    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} -- bash -c \"#{mysqldump_cmd}\" 2> #{logfile} > #{sqlfile}"
    puts "Running: #{backup_cmd}" if DEBUG

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    ret = system(backup_cmd)
    return ret
  end

  def backup_rsync (container)

    backup_path = "#{container_backup_dir container['name']}"

    if defined? @backup_src then
      source_paths = @backup_src.join(' ')
    else
      source_paths = '/'
    end

    tarfile = "#{backup_path}/#{container['name']}.tar.gz"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"

    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} -- bash -c \"tar czf - #{source_paths}\" 2> #{logfile} 1> #{tarfile}"

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    puts "Running: #{backup_cmd}" if DEBUG
    ret = system(backup_cmd)
    return ret

  end

end

##########################################################################

YAML.load(`oc get pods --all-namespaces  -l needs_backup="yes" -o yaml`)['items'].each do |pod|

  p = PodBackup.new pod
  ret = p.backup
  puts "Backup of #{pod['metadata']['name']} completed successfully." if ret
  puts "Backup of #{pod['metadata']['name']} FAILED." unless ret

end


exit 0

##########################################################################
pods_to_backup = {
  'paas-staging' => {
    'custapi-mysql'  => { 'type' => 'mysql'   },
    'clusterbuilder' => { 'type' => 'unknown' },
    'etcd'           => { 'type' => 'unknown' },
    'fitnesse'       => { 'type' => 'rsync', 'src_paths' => [ '/opt/fitnesse/FitNesseRoot', ] },
  },
  'library' => {
    'dependencygraph-mysql'    => { 'type' => 'mysql' },
    'gogs-mysql'               => { 'type' => 'mysql' },
    'image-drone-mysql'        => { 'type' => 'mysql' },
    'template-drone-mysql'     => { 'type' => 'mysql' },
    'templaterepository-mysql' => { 'type' => 'mysql' },
    'templateupdater-mysql'    => { 'type' => 'mysql' },
  },
}

