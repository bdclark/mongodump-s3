#!/usr/bin/env bash
set -euf -o pipefail

# Set defaults, can be overriden with config_file (-f)
host="127.0.0.1"
port="27017"
username=
password=
authdb=
backup_dir=$(pwd)
rotate=false    # true enables weekly/monthly rotation (copy)
do_monthly="01" # 01 to 31, 0 to disable monthly
do_weekly="6"   # day of week 1-7, 1 is Monday, 0 disables weekly
do_latest=true
bucket=
config_file=
region="us-east-1"
s3_prefix=
s3_daily_prefix="daily"
s3_weekly_prefix="weekly"
s3_monthly_prefix="monthly"
s3_latest_prefix="latest"
dry_run=false
prefer_slave=true
oplog=true
dump_basename=

usage(){
  echo "Usage: $0 args
    -f PATH config file to use rather than specifying CLI arguments
    -u USER username
    -p PWD  password
    -a DB   authentication database
    -H HOST host (default: 127.0.0.1)
    -P PORT port (default: 27017)
    -s      prefer slave (will attempt to find a slave)
    -B DIR  backup directory (defaults to current directory)
    -b BKT  S3 bucket name
    -n NAME Basename for backup files (will be basename_YYYY-MM-DD_HHhMMm.tgz)
    -d DIR  S3 prefix (will append daily/weekly/monthly if rotate enabled)
    -R RGN  AWS Region (default: us-east-1)
    -r      enable weekly/monthly rotation, files will be copied to
            weekly/monthly S3 prefixes if this option is enabled.
            Note: UTC is used when calculating day of week and month
    -m INT  day of month to do monthly backup (01 to 31) (default: 01)
            use 0 to disable monthly backups (only relevant if -r specified)
    -w INT  day of week to do weekly backups (1-7, 1 is Monday) (default: 6)
            use 0 to disable weekly backups (only relevant if -r specified)
    -D      dry-run, explain only, will not pause replication or perform backups" >&2
  exit 1
}

die() {
  if [ -n "$1" ]; then echo "Error: $1" >&2; fi
  exit 1
}

# calculate number of days in month; taken from automysqlbackup
# $1 = month, $2 = year
days_in_month() {
  m="$1"; y="$2"; a=$(( 30+(m+m/8)%2 ))
  (( m==2 )) && a=$((a-2))
  (( m==2 && y%4==0 && ( y<100 || y%100>0 || y%400==0) )) && a=$((a+1))
  printf '%d' $a
}

while getopts ":f:u:p:a:B:H:P:sb:d:n:R:rm:w:lDh" opt; do
  case $opt in
    f) config_file=$OPTARG;;
    u) username=$OPTARG;;
    p) password=$OPTARG;;
    a) authdb=$OPTARG;;
    B) backup_dir=$OPTARG;;
    H) host=$OPTARG;;
    P) port=$OPTARG;;
    s) prefer_slave=true;;
    b) bucket=$OPTARG;;
    d) s3_prefix=$OPTARG;;
    n) dump_basename=$OPTARG;;
    R) region=$OPTARG;;
    r) rotate=true;;
    m) do_monthly=$OPTARG;;
    w) do_weekly=$OPTARG;;
    l) do_latest=false;;
    D) dry_run=true;;
    h) usage;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [ -n "$config_file" ]; then
  if [ ! -f "$config_file" ]; then die "config file '$config_file' does not exist"; fi
  if [ ! -r "$config_file" ]; then die "unable to access config file '$config_file'"; fi
  # shellcheck source=/dev/null
  source "$config_file"
fi

# option validation
if [ -z "$host" ]; then die "host is required"; fi
if [ -z "$bucket" ]; then die "bucket is required"; fi
if [[ ! $do_weekly =~ ^[0-7]$ ]]; then die "invalid weekday"; fi
if [[ ! $do_monthly =~ ^(0|0[0-9]|[12][0-9]|3[01])$ ]]; then die "invalid month day: $do_monthly"; fi
if [ ! -d "$backup_dir" ]; then die "$backup_dir does not exist"; fi

# don't override these
auth_opts=""
opts=""
secondary=""
date_day_of_week=$(date -u +%u)
date_day_of_month=$(date -u +%d)
date_year=$(date -u +%Y)
last_day_of_month=$(days_in_month "$date_day_of_month" "$date_year")
backup_name=$(date -u +%Y-%m-%d_%Hh%Mm)
s3_archive_fname_match='????-??-??_??h??m.tgz'
db_host="$host:$port"

if [ -n "$dump_basename" ]; then
  backup_name="${dump_basename}_${backup_name}"
  s3_archive_fname_match="${dump_basename}_${s3_archive_fname_match}"
fi
archive_fname="${backup_name}.tgz"

dump_dir="${backup_dir}/${backup_name}"
if [ -d "$dump_dir" ]; then die "backup directory $dump_dir already exists"; fi

if [ -n "$s3_prefix" ]; then bucket="$bucket/$s3_prefix"; fi

if [ -n "$username" ]; then
  auth_opts="--username=$username --password=$password"
  if [ -n "$authdb" ]; then auth_opts="$auth_opts --authenticationDatabase=$authdb"; fi
fi

if [ "$oplog" = true ]; then opts="$opts --oplog"; fi

if [ "$dry_run" = true ]; then echo "Dry run enabled"; fi

cleanup() {
  rm -rf "$dump_dir"
}

trap cleanup ERR INT TERM EXIT

if [ "$prefer_slave" = true ]; then
  rs=$(
    mongo --quiet --host "$db_host" --eval 'printjson(rs.conf())' $auth_opts
  ) || die "failed to get replica set config"
  if [ "$rs" != "null" ]; then
    members=( $(
      mongo --quiet --host "$db_host" $auth_opts \
        --eval 'rs.conf().members.forEach(function(x){ print(x.host) })'
    ) ) || die "failed to get replica set members"
    if [ ${#members[@]} -gt 1 ]; then
      for member in "${members[@]}"; do
        is_secondary=$(
          mongo --quiet --host "$member" --eval 'rs.isMaster().secondary' $auth_opts
        ) || die "failed to get secondary status"
        case "$is_secondary" in
          'true') secondary=$member; break;;
          'false') continue;;
          *) continue;;
        esac
      done
    fi
  fi

  if [ -n "$secondary" ]; then
    echo "Found secondary at $secondary"
    db_host=$secondary
  else
    echo "No secondaries found, using $db_host"
  fi
fi

echo "Starting mongodump at $(date -u +%Y-%m-%dT%H:%M:%SZ) from $db_host to $dump_dir"
if [ "$dry_run" != true ]; then
  mongodump --host="$db_host" --out="$dump_dir" $auth_opts $opts || die "mongodump failed"
fi

if [ "$rotate" = true ]; then
  s3_path="s3://$bucket/$s3_daily_prefix/$archive_fname"
else
  s3_path="s3://$bucket/$archive_fname"
fi

echo "Archiving backup from $dump_dir to $s3_path"
if [ "$dry_run" != true ]; then
  cd "$backup_dir"
  tar -czf - "$backup_name" | aws s3 cp - "$s3_path" --region "$region"
fi

if [ "$rotate" = true ]; then
  # weekly
  if (( do_weekly == date_day_of_week )); then
    s3_weekly_path="s3://$bucket/$s3_weekly_prefix/$archive_fname"
    if [ "$dry_run" = true ]; then
      echo "aws s3 cp \"$s3_path\" \"$s3_weekly_path\" --region \"$region\""
    else
      aws s3 cp "$s3_path" "$s3_weekly_path" --region "$region"
    fi
  fi

  # monthly
  if (( date_day_of_month == do_monthly || date_day_of_month == last_day_of_month && last_day_of_month < do_monthly )); then
    s3_monthly_path="s3://$bucket/$s3_monthly_prefix/$archive_fname"
    if [ "$dry_run" = true ]; then
      echo "aws s3 cp \"$s3_path\" \"$s3_monthly_path\" --region \"$region\""
    else
      aws s3 cp "$s3_path" "$s3_monthly_path" --region "$region"
    fi
  fi

  # latest
  if [ "$do_latest" = true ]; then
    if [ "$dry_run" = true ]; then
      echo "aws s3 cp $s3_path s3://$bucket/$s3_latest_prefix/$archive_fname"
      echo "aws s3 rm s3://$bucket/$s3_latest_prefix/ --recursive --exclude=\"*\" --include=\"$s3_archive_fname_match\" --exclude=\"$archive_fname\""
    else
      aws s3 cp "$s3_path" "s3://$bucket/$s3_latest_prefix/$archive_fname"
      # delete all matching except for the one just copied
      aws s3 rm "s3://$bucket/$s3_latest_prefix/" --recursive --exclude="*" --include="$s3_archive_fname_match" --exclude="$archive_fname"
    fi
  fi
fi

echo "Done. Completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
