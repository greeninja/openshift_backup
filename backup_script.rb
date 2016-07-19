#!/usr/bin/env ruby
require 'fileutils'
require 'yaml'
require 'time'
require 'pp'

# metadata required for backups on pods
# metadata.labels.needs_backup: yes
# metadata.labels.backup_type: mysql|rsync|etcd
# metadata.annotations.backup_src: /path/to/files/for/rsync (ignored for other backup types)

# uses: pod.container.securityContext.runAsUser


# backup destination tree
# project/dc/pod_name/container_name/yyyy-mm/
# each backup dir is a git repo

if ENV.include? 'DEBUG' then
  DEBUG=ENV['DEBUG']
else
  DEBUG=false
end

BACKUP_DEST_ROOT='backup-data'

def die (msg)
  puts msg
  exit 1
end

if File.exists? '/var/run/secrets/kubernetes.io/serviceaccount/token' then
  puts "Logging into openshift with serviceaccount" if DEBUG
  ret = system('oc login https://openshift-cluster.fhpaas.fasthosts.co.uk:8443 --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)')
end
ret = system('oc status >/dev/null 2>&1')
die "Unable to log into openshift" unless ret

# make sure we have git config correct
`git config --global user.name "Backup Service"` unless system('git config --global user.name >/dev/null 2>&1')
`git config --global user.email "linuxteam@fasthosts.com"` unless system('git config --global user.email > /dev/null 2>&1')

class PodBackup
  def initialize (pod_spec={}, backup_dest_root='.')
    # metadata should be the output from "oc get pod x -o yaml"
    @pod_spec = pod_spec
    @metadata = @pod_spec['metadata']
    @podname = @metadata['name']
    @project = @metadata['namespace']
    @backup_dest_root = backup_dest_root
    @backup_dest = "#{backup_dest_root}/#{@project}/#{@podname}"

    @backup_type = @metadata['labels']['backup_type']
    @backup_src = @metadata['annotations']['backup_src'].split(':') if @metadata['annotations'].key? 'backup_src'
    @local_backup_dest = @metadata['annotations']['backup_dest'] if @backup_type == 'etcd'
    @runasuser = @pod_spec['spec']['securityContext']['runAsUser'] if @pod_spec['spec']['securityContext'].key? 'runAsUser'
    @containers = {}
    @pod_spec['spec']['containers'].each {|c| @containers[c['name']] ||= {} }
  end

  def container_backup_dir (container_name, root=@backup_dest_root)
    if @backup_type == 'etcd' then
      backup_dir = "#{root}/#{@project}/#{@podname}/#{container_name}/#{Time.now.strftime("%Y-%m-%d_%H:%M")}"
    else
      backup_dir = "#{root}/#{@project}/#{@podname}/#{container_name}/#{Time.now.strftime("%Y-%m")}"
    end
    return backup_dir
  end

  def create_backup_dir (container_name)
    puts "mkdir_p on #{container_backup_dir(container_name)}" if DEBUG
    FileUtils.mkdir_p container_backup_dir(container_name), :mode => 0700
    FileUtils.chown_R @runasuser, @runasuser, container_backup_dir(container_name) if defined? @runasuser
  end

  def commit_backup (dir)
    system "cd #{dir} && git init" unless Dir.exists? "#{dir}/.git"
    system "cd #{dir} && git add * && git commit -a -m 'Backup commited at #{Time.now}' > /dev/null 2>&1"
  end

  def age (container) #returns age of last git log entry in hours
    gitdate = `cd #{container_backup_dir(container['name'])} && git log -1 --format="%ad" --date=local 2>/dev/null`
    begin
      lastlogentry = Time.parse(gitdate.to_i)
    rescue
      lastlogentry = 0
    end
    return ((Time.now.to_i - lastlogentry)/60.0/60).round 1
  end

  def backup
    ret = -1
    @pod_spec['spec']['containers'].each do |container|

      case @backup_type
        when 'mysql'
          puts "backing up mysql" if DEBUG
          create_backup_dir container['name']
          ret = backup_mysql container
        when 'rsync'
          create_backup_dir container['name']
          ret = backup_rsync container
        when 'etcd'
          puts "something etcd" if DEBUG
          create_backup_dir container['name']
          ret = backup_etcd container
        else
          puts "no backup_type for #{container['name']}"
          ret = false
      end

      gitcommitret = commit_backup container_backup_dir(container['name'])
      unless gitcommitret then
        @containers[container['name']]['errors'] ||= []
        @containers[container['name']]['errors'] << 'git commit failed'
      end

      @containers[container['name']]['age'] = age(container)
      @containers[container['name']]['success'] = ret
    end

    return @containers
  end

  def backup_etcd (container)

    local_backup_subdir = Time.now.strftime("%Y-%m-%d_%H:%M")

    backup_path = container_backup_dir container['name']
    logfile = "#{backup_path}/#{container['name']}.log"
    cmdfile = "#{backup_path}/#{container['name']}.cmd"
    backup_cmd = "oc exec -n #{@project} #{@podname} > #{logfile} 2>&1 -- "
    backup_cmd << "/etcdctl backup"
    backup_cmd << " --data-dir=#{@backup_src[0]}"
    backup_cmd << " --backup-dir=#{@local_backup_dest}/#{local_backup_subdir}"

    puts "Running: #{backup_cmd}" if DEBUG

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    ret = system(backup_cmd)
    return ret
  end

  def backup_mysql (container)

    backup_path = "#{container_backup_dir container['name']}"

    metapw = container['env'].select { |env| env['name'] == 'MYSQL_ROOT_PASSWORD' }
    root_pw = ''
    root_pw = metapw[0]['name'] if defined? metapw[0]['name']

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
    puts "Running: #{backup_cmd}" if DEBUG

    File.open(cmdfile, 'w') { |f| File.write f, "#{backup_cmd}\n" }

    ret = system(backup_cmd)
    return ret
  end

end

##########################################################################

YAML.load(`oc get pods --all-namespaces  -l needs_backup="yes" -o yaml`)['items'].each do |pod|

  p = PodBackup.new pod, BACKUP_DEST_ROOT
  ret = p.backup
  ret.each do |k,v|
    msg = "Backup of #{pod['metadata']['namespace']} - #{pod['metadata']['name']} - #{k} "
    msg += "completed successfully." if v['success']
    msg += "FAILED." unless v['success']
    puts msg
  end
  PP.pp ret

end

exit 0

##########################################################################
