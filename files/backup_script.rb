#!/usr/bin/env ruby
require 'fileutils'
require 'yaml'
require 'time'
require 'logger'

# metadata required for backups on pods
# metadata.labels.needs_backup: yes
# metadata.labels.backup_type: mysql|rsync|etcd|mongodb
# metadata.annotations.backup_src: /path/to/files/for/rsync (ignored for other backup types)

# uses: pod.container.securityContext.runAsUser


# backup destination tree
# project/dc/pod_name/container_name/yyyy-mm/

if ENV.include? 'DEBUG' then
  DEBUG=ENV['DEBUG']
else
  DEBUG=false
end

if ENV.include? 'MASTERURL' then
  MASTERURL=ENV['MASTERURL']
else
  MASTERURL="openshift-cluster.fhpaas.fasthosts.co.uk"
end

if ENV.include? 'MASTERINSECURE' then
  MASTERINSECURE="--insecure-skip-tls-verify=true"
else
  MASTERINSECURE="--insecure-skip-tls-verify=false"
end

@global_logger = Logger.new("| tee backup_script.log")
if DEBUG then
  @global_logger.level = Logger::DEBUG
else
  @global_logger.level = Logger::INFO
end

if ENV.include? 'FAKESYSTEM' then
  FAKESYSTEM=ENV['FAKESYSTEM']
else
  FAKESYSTEM=false
end

BACKUP_DEST_ROOT='/backup-data'

def die (msg)
  @global_logger.info msg
  exit 1
end

class PodBackup
  def initialize (pod_spec={}, backup_dest_root='.', log)
    @log = log
    # metadata should be the output from "oc get pod x -o yaml"
    @backup_time = Time.now.strftime("%Y-%m-%d_%H:%M")
    @pod_spec = pod_spec
    @metadata = @pod_spec['metadata']
    @podname = @metadata['name']
    @project = @metadata['namespace']
    @dc = @metadata['labels']['deploymentconfig']
    @backup_dest_root = backup_dest_root
    @backup_dest_pod_root = "#{backup_dest_root}/#{@project}/#{@dc}/#{@backup_time}/#{@podname}"
    @success_file = "#{backup_dest_root}/#{@project}/#{@dc}/success"

    @backup_type = @metadata['labels']['backup_type']
    @backup_src = @metadata['annotations']['backup_src'].split(':') if @metadata['annotations'].key? 'backup_src'
    @local_backup_dest = @metadata['annotations']['backup_dest'] if @backup_type == 'etcd'
    @runasuser = @pod_spec['spec']['securityContext']['runAsUser'] if @pod_spec['spec']['securityContext'].key? 'runAsUser'

    # For multi container pods, typically only one container will require backup. Look for
    # a 'backup_containers' label, otherwise backup all containers
    @backup_container_names = if @metadata['labels'].key? 'backup_containers' then
      @metadata['labels']['backup_containers'].split(',').map(&:strip)
    else
      @pod_spec['spec']['containers'].map{|c| c['name']}
    end

    @containers = @pod_spec['spec']['containers'].select {|container| @backup_container_names.include?(container['name'])}
  end

  def system_wrapper(cmd)
    @log.debug "Running command: #{cmd}"
    if FAKESYSTEM then
      @log.info "Mocking success from: #{cmd}"
      return true
    else
      return system(cmd)
    end
  end

  def container_backup_dir (container_name, root=@backup_dest_pod_root)
    "#{root}/#{container_name}"
  end

  # this assumes that "root" maps to <project>/<dc> on gluster
  def etcd_local_backup_dir (container_name, root=@local_backup_dest)
    "#{root}/#{@backup_time}/#{@podname}/#{container_name}"
  end

  def create_backup_dir (container_name)
    @log.debug "mkdir_p and chown_R on #{container_backup_dir(container_name)}"
    FileUtils.mkdir_p container_backup_dir(container_name), :mode => 0700
    FileUtils.chown_R @runasuser, @runasuser, container_backup_dir(container_name) if defined? @runasuser
  end

  def project_dc_chown
    FileUtils.chown_R @runasuser, @runasuser, "#{@backup_dest_root}/#{@project}/#{@dc}" if defined? @runasuser
  end

  def touch_success_file
    FileUtils.touch @success_file
  end

  def get_success_time
    if File.exists?(@success_file)
      File.stat(@success_file).mtime
    else
      Time.at(0)
    end
  end

  def age
    last = Time.parse(get_success_time)
    return ((Time.now.to_i - last)/60.0/60).round 1
  end

  def last_success
    get_success_time
  end

  # Returns true if pod backups are within 24 hours, false otherwise
  def within_24?
    all_good = true
    yesterday = Time.at(Time.now.to_i - 86400)
    if get_success_time < yesterday then
      all_good = false
    end
    all_good
  end

  def remove_old_backups
    Dir["#{@backup_dest_pod_root}/*"].select {|x| x.split("/").last =~ /^(backup_)?[0-9_\-:]+(\.log)?$/ }.each { |d| check_age_and_remove d }
    dir = "#{@backup_dest_root}/#{fqdn}/local"
    # backup_2016-07-18_14:30
    Dir["#{dir}/*"].select {|x| x.split("/").last =~ /^backup_[0-9_\-:]+(\.tar\.gz$|\.log$)/ }.each { |d| check_age_and_remove d }
    return true
  end

  def backup
    ret = false
    if File.exists? @backup_dest_pod_root then
      @log.info "Skipping #{@podname} as backup with same timestamp already exists"
      return true
    end
    @containers.each do |container|

      case @backup_type
        when 'mysql'
          create_backup_dir container['name']
          ret = backup_mysql container
        when 'rsync'
          create_backup_dir container['name']
          ret = backup_rsync container
        when 'etcd'
          create_backup_dir container['name']
          ret = backup_etcd container
        when 'mongodb'
          create_backup_dir container['name']
          ret = backup_mongodb container
        else
          @log.info "no backup_type for #{container['name']}"
          ret = false
      end

      container['backup_success'] = ret
    end

    overall_success = @containers.all? {|container| container['backup_success']}
    touch_success_file if overall_success
    return overall_success
  end

  def backup_etcd (container)
  # local backup dir needs to map to gluster share /storage/infra01/infra-backups/<project>/<dc>

    backup_path = container_backup_dir container['name']
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"
    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} > \"#{logfile}\" 2>&1 -- "
    backup_cmd << "/etcd/etcdctl backup"
    backup_cmd << " --data-dir=\"#{@backup_src[0]}\""
    backup_cmd << " --backup-dir=\"#{etcd_local_backup_dir container['name']}\""

    @log.debug "Running: #{backup_cmd}"

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    project_dc_chown
    return system_wrapper(backup_cmd)
  end

  def backup_mysql (container)
    backup_path = "#{container_backup_dir container['name']}"

    metapw = container['env'].select { |env| env['name'] == 'MYSQL_ROOT_PASSWORD' }
    root_pw = ''
    root_pw = metapw[0]['name'] if defined? metapw[0]['name']

    mysqldump_cmd = "mysqldump -u root --all-databases"
    mysqldump_cmd += " -p\\\$#{root_pw}" unless root_pw.empty?

    sqlfile = "#{backup_path}/#{container['name']}.sql.gz"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"

    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} 2> \"#{logfile}\" -- "
    backup_cmd << "bash -c \"#{mysqldump_cmd}\" | gzip > \"#{sqlfile}\""
    @log.debug "Running: #{backup_cmd}"

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    return system_wrapper(backup_cmd)
  end

  def backup_rsync (container)

    backup_path = "#{container_backup_dir container['name']}"

    if defined? @backup_src then
      source_paths = " " + @backup_src.map{ |e| '"' + e + '"' }.join(' ')
    else
      source_paths = '"/"'
    end

    tarfile = "#{backup_path}/#{container['name']}.tar.gz"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"

    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} -- "
    backup_cmd << "bash -c \"tar czf - #{source_paths}\" 2> \"#{logfile}\" 1> \"#{tarfile}\""
    @log.debug "Running: #{backup_cmd}"

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    return system_wrapper(backup_cmd)
  end

  def backup_mongodb (container)
    backup_path = "#{container_backup_dir container['name']}"

    mongodump_cmd = "mongodump --archive --gzip"

    archiveFile = "#{backup_path}/#{container['name']}-archive.gz"
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"

    backup_cmd = "oc exec -n #{@project} #{@podname} -c #{container['name']} 2> \"#{logfile}\" -- "
    backup_cmd << "bash -c \"#{mongodump_cmd}\" > \"#{archiveFile}\""
    @log.debug "Running: #{backup_cmd}"

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    return system_wrapper(backup_cmd)
  end

end

##########################################################################
@yaml_loaded = false

def load_pod_yaml
  ret = YAML.load(`oc get pods --all-namespaces  -l needs_backup="yes" -o yaml`)
  @yaml_loaded = true
  return ret
end

def oc_login(silent=false)
  if File.exists? '/var/run/secrets/kubernetes.io/serviceaccount/token' then
    @global_logger.info "Logging into openshift with serviceaccount" unless silent
    ret = system("oc login https://#{MASTERURL}:8443 --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) #{MASTERINSECURE} > /dev/null 2>&1")
  end
  ret = system('oc status >/dev/null 2>&1')
  die "Unable to log into openshift" unless ret
end

if ARGV.include? 'status' then
  oc_login true
  y = load_pod_yaml
  all_good = true
  errors = []
  y['items'].each do |pod|
    p = PodBackup.new pod, BACKUP_DEST_ROOT, @global_logger
    unless p.within_24? then
      errors << "Pod #{pod['metadata']['namespace']}/#{pod['metadata']['name']} does not have a backup within 24 hours"
      all_good = false
    end
  end
  if all_good then
    puts "OK: ALL BACKUPS WITHIN 24 HOURS"
  else
    puts errors.join("\n")
    puts errors.map{ |e| '<p>' + e + '</p>' }.join("\n")
  end
  exit all_good
end

if ARGV.include? 'purge' then
  oc_login
  y = load_pod_yaml
  y['items'].each do |pod|
    p = PodBackup.new pod, BACKUP_DEST_ROOT, @global_logger
    puts p.remove_old_backups
  end
end

if ARGV.include? 'run' then
  oc_login
  y = load_pod_yaml
  all_good = true
  y['items'].each do |pod|
    @global_logger.info "Backing up pod #{pod['metadata']['namespace']}/#{pod['metadata']['name']}"
    p = PodBackup.new pod, BACKUP_DEST_ROOT, @global_logger
    ret = p.backup
    @global_logger.info "pod:success: #{p.last_success}"
    all_good = false unless ret
    unless ret then
      @global_logger.info "Backup for pod: #{pod['metadata']['namespace']}/#{pod['metadata']['name']} failed"
    end

  end
  puts all_good
  exit all_good
end

##########################################################################
