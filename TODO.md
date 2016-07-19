How to monitor?
Better checking on backup return codes to determine success/failure

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

