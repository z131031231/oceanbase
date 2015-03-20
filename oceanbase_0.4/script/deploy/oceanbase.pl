#!/usr/bin/perl -w

# Time-stamp: <2014-09-23 17:06:54 fufeng.syd>
# Author: 符风 <fufeng.syd@alipay.com>
#
# require: oceanbase 0.5, perl 5.10+
use threads;
use Data::Dumper;
use Getopt::Long;
use Pod::Usage;
use strict;
use warnings;
use vars qw($init_cfg @clusters $settings $action $debug);

#########################################################################
### configure file parser
package config;
sub init {
  # Check the file
  my $file = shift or common::perror_exit('You did not specify a file name');
  common::perror_exit("File '$file' does not exist")               unless -e $file;
  common::perror_exit("'$file' is a directory, not a file")        unless -f _;
  common::perror_exit("Insufficient permissions to read '$file'")  unless -r _;

  # Slurp in the file
  local $/ = undef;
  open my $fh, '<', $file;
  my $contents = <$fh>;
  close $fh;

  read_string($contents);
}

sub read_string($) {
  # Parse the string
  my $server_type = 'public';
  my $group       = undef;
  my $self        = undef;
  my $counter     = 0;
  my @servers     = ();
  my $appname     = undef;
  foreach ( split /(?:\015{1,2}\012|\015|\012)/, shift ) {
    $counter++;

    # Handle real a server
    if (/^\s*(\d+\.\d+\.\d+\.\d+)\s*$/) {
      my $cluster_id = '0';
      if ($group =~ /cluster_(\d+)/) {
        $cluster_id = $1;
      } else {
        common::perror_exit('wrong group name');
      }
      $appname = $self->{global}->{public}{appname};
      push @servers, { %{$self->{global}{public}},
                       %{$self->{global}{$server_type}},
                       %{$self->{$group}{public}},
                       %{$self->{$group}{$server_type}},
                       'server_type' => $server_type,
                       'ip'          => $_,
                       'cluster_id'  => $cluster_id };
      # add lms if match rootserver
      if ($server_type eq 'rootserver') {
        my $devname = $servers[-1]{devname};
        push @servers, { %{$self->{global}{public}},
                         %{$self->{global}{mergeserver}},
                         %{$self->{$group}{public}},
                         'server_type' => 'listener_mergeserver',
                         'ip'          => $_,
                         'devname'     => $devname,
                         'cluster_id'  => $cluster_id };
      }
      next;
    }

    # Handle begin group
    if (/^#\@begin_(.+)$/) {
      if (not $group) {
        $self->{$group = $1} ||= {};
        $server_type = 'public';
      } else {
        # multi begin group line
        return common::perror_exit("Syntax error at line $counter: '$_'");
      }
      next;
    }

    # Handle end group
    if (/^#\@end_(.+)$/) {
      common::perror_exit("end_$1 not match start_$group (line $counter)") unless ($1 eq $group);
      $group = undef;
      my $cur_group = $1;
      my $cluster_id = 0;
      if ($cur_group =~ /^cluster_(\d+)$/) {
        $cluster_id = $1;
      } else {
        next;
      }

      my $cluster = {
                     'rootserver'           => [grep {$_->{server_type} eq 'rootserver'} @servers],
                     'updateserver'         => [grep {$_->{server_type} eq 'updateserver'} @servers],
                     'chunkserver'          => [grep {$_->{server_type} eq 'chunkserver'} @servers],
                     'mergeserver'          => [grep {$_->{server_type} eq 'mergeserver'} @servers],
                     'listener_mergeserver' => [grep {$_->{server_type} eq 'listener_mergeserver'} @servers],
                     'cluster_id'           => $cluster_id,
                     'appname'              => $appname,
                    };
      $cluster = {
                  %$cluster,
                  'master_rootserver' => 'x',
                  'rs_port'  => $cluster->{rootserver}[0]{port},
                  'lms_port' => $cluster->{listener_mergeserver}[0]{lms_port}
                 };
      push @main::clusters, new Cluster($cluster);
      @servers = ();

      next;
    }

    # Skip comments and empty lines
    next if /^\s*(?:\#|\;|$)/;

    # Remove inline comments
    s/\s\;\s.+$//g;

    # Handle section headers
    if ( /^\s*\[\s*(.+?)\s*\]\s*$/ ) {
      if ($group) {
        $self->{$group}{$server_type = $1} ||= {};
      } else {
        $self->{$server_type = $1} ||= {};
      }
      next;
    }

    # Handle properties
    if ( /^\s*([^=]+?)\s*=\s*(.*?)\s*$/ ) {
      if ($group eq 'settings') {
        $main::settings->{$1} = $2;
      }

      if ($group) {
        $self->{$group}{$server_type}{$1} = $2;
      } else {
        $self->{$server_type}{$1} = $2;
      }
      next;
    }

    common::perror_exit("Syntax error at line $counter: '$_'");
  }

  $main::init_cfg = $self->{init_config};
  $main::settings = $self->{global}{settings};
}

sub common_extra_init_cfg {
  my @root_server = map { map {$_->{ip}} @{$_->{rootserver}} } @main::clusters;
  my $root_server_list = join ';', @root_server;
  return "root_server_list=$root_server_list";
}

sub rs_extra_init_cfg {
  my $ups_cnt = scalar map { @{$_->{updateserver}} } @main::clusters;
  my $rs_cnt = scalar map { @{$_->{rootserver}} } @main::clusters;
  return "ups_count_limit=$ups_cnt,max_candidate_count=$rs_cnt";
}

######################################################################
### common functions
package common;
sub pinfo($) {
  print "\033[32m[  INFO ]\033[0m $_[0]\n";
}

sub perror($) {
  print "\033[31m[ ERROR ]\033[0m $_[0]\n";
}

sub perror_exit($) {
  $main::debug and die shift;
  perror(shift);
  exit(1);
}

sub pwarn($) {
  print "\033[35m[  WARN ]\033[0m $_[0]\n";
}

sub pdebug($) {
  $main::debug and print "[ DEBUG ] $_[0]\n";
}

sub do_ssh {
  my ($ip, $cmd, $prompt) = @_;
  my $ignore_error = (@_ > 3 and $_[3]);
  $cmd = "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib:/usr/local/lib64:$main::settings->{ob_home}/lib "
    . "&& cd $main::settings->{ob_home} && ulimit -c unlimited && $cmd 2>&1";

  my $ssh_cmd = "ssh admin\@$ip '$cmd' 2>&1";
  pdebug($ssh_cmd);
  my $retcode = 0;
  my $output = '';
  if ($prompt) {
    pinfo($prompt);
    $output = qx($ssh_cmd);
    chomp $output;
    pinfo($output) unless ($? == 0 or $ignore_error);
  } else {
    system $ssh_cmd;
  }
  $retcode = $? >> 8;
  return wantarray ? ($retcode, $output) : $retcode;
}

sub do_local {
  my ($cmd, $prompt) = @_;
  my $ignore_error = (@_ > 3 and $_[3]);
  $cmd = "(export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib:/usr/local/lib64:/home/admin/oceanbase/lib "
    . "&& cd /home/admin/oceanbase && ulimit -c unlimited && $cmd) 2>&1";

  pdebug($cmd);
  my $retcode = 0;
  my $output = '';
  if ($prompt) {
    pinfo($prompt);
    $output = qx($cmd);
    chomp $output;
    perror($output) unless ($? == 0 or $ignore_error);
  } else {
    system $cmd;
  }
  $retcode = $? >> 8;
  return wantarray ? ($retcode, $output) : $retcode;
}

sub do_server($$$$) {
  my ($op, $server, $force, $supervisor) = @_;
  my $cmd = "bin/$server";
  my $ob_home = "/home/admin/oceanbase";
  my $pid_file = "$ob_home/run/${server}.pid";
  $pid_file = "$ob_home/run/mergeserver.pid" if $server eq 'listener_mergeserver';
  if ($op eq 'start') {
    if ($server eq 'importserver') {
      common::do_local("python2.6 bin/importserver.py -f etc/importserver.conf", "start importserver") == 0
          and pinfo("start importserver successfully")
            or perror("start importserver failed");
    } elsif ($server eq 'proxyserver') {
      common::do_local("bin/proxyserver -f etc/proxyserver.conf -p2650", "start proxyserver") == 0
          and pinfo("start proxyserver successfully")
            or perror("start proxyserver failed");
    } elsif (($server eq 'listener_mergeserver' or $server eq 'mergeserver') and $supervisor) {
      my $select = sub { return $_[0]->{$_[1]} };
      my $short_name = $select->({'mergeserver'=>'ms', 'listener_mergeserver'=>'lms'}, $server);
      my $conf_name = $select->({'mergeserver'=>'supervisor', 'listener_mergeserver'=>'lms_supervisor'}, $server);
      common::do_local("supervisorctl reread > /dev/null",
                       "Reload supervisor config")
          and common::perror_exit("reload supervisor daemon conf failed");

      common::do_local("supervisorctl status $short_name | grep -q RUNNING",
                       "check $short_name running status")
          or common::pwarn("$short_name is already started") and return;

      common::do_local("supervisorctl add $short_name > /dev/null",
                       "start $short_name using supervisor");

      common::do_local("supervisorctl start $short_name > /dev/null",
                       "start $short_name using supervisor");

      common::do_local("supervisorctl status $short_name | grep -q RUNNING",
                       "check $short_name running status")
          and common::pinfo("$short_name is started");
    } else {
      $cmd = "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/local/lib:/usr/local/lib64:/home/admin/oceanbase/lib:./lib "
        . "&& cd /home/admin/oceanbase && ulimit -c unlimited && $cmd";
      pdebug($cmd);
      if (system($cmd)) {
        pwarn("No $server running now!");
      } else {
        pinfo("Start $server successfully!");
      }
    }
  } elsif ($op eq 'stop') {
    my $select = sub { return $_[0]->{$_[1]} };
    my $short_name = $select->({'mergeserver'=>'ms', 'listener_mergeserver'=>'lms'}, $server);
    my $conf_name = $select->({'mergeserver'=>'supervisor', 'listener_mergeserver'=>'lms_supervisor'}, $server);
    if (($server eq 'listener_mergeserver' or $server eq 'mergeserver') and $supervisor) {
      common::do_local("supervisorctl reread > /dev/null",
                       "Reload supervisor config")
          and common::perror_exit("reload supervisor daemon conf failed");

      common::do_local("supervisorctl status $short_name | grep -q RUNNING",
                       "check $short_name running status")
          and common::pwarn("$short_name is already stopped") and return;

      common::do_local("supervisorctl stop $short_name > /dev/null",
                       "stop $short_name using supervisor");

      common::do_local("supervisorctl status $short_name | grep -q RUNNING",
                       "check $short_name running status")
          and common::pinfo("stop $short_name done");
    } else {
      perror_exit("$pid_file doesn't exist!") unless -e $pid_file;
      if (system("kill `cat $pid_file 2>/dev/null` 2>/dev/null")) {
        pwarn("No $server running now!");
      } else {
        pinfo("Kill $server");
      }
    }
  } else {
    perror_exit("Unknow operate `$op'");
  }
}

sub check_ssh {
  pinfo("Checking ssh [$_[0]]");
  system("ssh -T -o PreferredAuthentications=publickey $_[0] -l admin -o ConnectTimeout=1 true") == 0
    or perror_exit ("ssh check failed! host: [$_[0]]");
  return $?;
}

sub bootstrap() {
  for (my $i = 0; $i < 100; $i++) {
    pinfo("Waiting prepare bootstrap");
    return 0 unless do_init_sql("alter system bootstrap");
    sleep(1);
  }
  return 1;
}

sub get_mmrs() {
  #TODO: select from system table
  perror_exit('no clusters') if @main::clusters <= 0;
  ($main::clusters[0]->{master_rootserver}, $main::clusters[0]->{rs_port});
}

sub get_one_lms() {
  perror_exit('no clusters') if @main::clusters <= 0;
  ($main::clusters[0]{listener_mergeserver}[0]{ip}, $main::clusters[0]->{lms_port});
}

sub do_sql($) {
  my $sql = shift;
  my ($host, $port) = get_one_lms();
  my ($user, $password) = ('admin', 'admin');
  system(qq{mysql -h$host -P$port -u$user -p$password -Bs -e "$sql" >/dev/null 2>&1});
}

sub do_init_sql($) {
    my $sql = shift;
    my ($host, $port) = get_one_lms();
    my ($user, $password) = ('__ob_server', 'admin');
    system(qq{mysql -h$host -P$port -u$user -p$password -Bs -e "$sql" >/dev/null 2>&1});
}

sub do_sql_query($) {
  my $sql = shift;
  my ($host, $port) = get_one_lms();
  my ($user, $password) = ('admin', 'admin');
  qx(mysql -h$host -P$port -u$user -p$password -Bs -e "$sql");
}

sub verify_bootstrap {
  for my $cluster (@main::clusters) {
    my $cluster_id = $cluster->{cluster_id};
    $cluster_id =~ s/^cluster_//;
    my $sql = "SELECT count(1) FROM __all_cluster "
      . "WHERE cluster_id = $cluster_id "
        . "AND cluster_port = $cluster->{lms_port} AND status = 1";
    my $cnt = do_sql_query($sql);
    if ($cnt == 1) {
      pinfo("Verify cluster [$cluster_id] OK!");
    } else {
      # not ok
      pinfo("__all_cluster table is not legal!");
      return 0;
    }
  }

  for my $cluster (@main::clusters) {
    my @servers = ('rootserver', 'mergeserver', 'chunkserver', 'updateserver');
    while (my ($k, $v) = each %$cluster) {
      my @server_name = grep { $k =~ /^$_$/ } @servers;
      if (@server_name > 0) {
        my $server_bin = shift @server_name;
        map {
          my $sql = "SELECT count(1) FROM __all_server WHERE svr_type='$server_bin'"
            . " AND svr_ip = '$_->{ip}'";
          chomp (my $cnt = do_sql_query($sql));
          if ($cnt == 1) {
            pinfo("Verify server OK! [<$server_bin> $_->{ip}]");
          } else {
            # not ok
            pinfo("__all_server table is not legal! [<$server_bin> $_->{ip}]");
            return 0;
          }
        } @$v;
      }
    }
  }

  for my $cluster (@main::clusters) {
    my @servers = ('rootserver', 'mergeserver', 'chunkserver', 'updateserver');
    while (my ($k, $v) = each %$cluster) {
      my @server_name = grep { $k =~ /^$_$/ } @servers;
      if (@server_name > 0) {
        my $server_bin = shift @server_name;
        map {
          my $sql = "SELECT count(1) FROM __all_sys_config_stat WHERE svr_type='$server_bin'"
            . " AND svr_ip = '$_->{ip}' AND svr_port = '$_->{port}'";
          chomp (my $cnt = do_sql_query($sql));
          if ($cnt > 1 or ($_->{server_type} eq 'rootserver' and $_->{ip} ne $_->{master_rootserver})) {
            pinfo("Verify config OK! [<$server_bin> $_->{ip}:$_->{port} cnt:$cnt]");
          } else {
            # not ok
            pinfo("__all_sys_config_stat table is not legal! [<$server_bin> $_->{ip}]");
            return 0;
          }
        } @$v;
      }
    }
  }
  pinfo("Verify okay.");
  return 1;
}

sub run_mysql() {
  my ($host, $port)     = get_one_lms();
  my ($user, $password) = ('admin', 'admin');
  my $cmd               = "mysql -h$host -P$port -u$user -p$password";
  system split / /, $cmd;
}

sub get_devname($) {
    my $host = shift;
    my $cmd = "ip r l |grep $host";
    my ($ret, $output) = do_ssh($host, $cmd, "Geting devname: $host");
    common::perror_exit("Get devname failed!") if $ret;
    my @t = (split ' ', $output);
    return $t[2];
}

#######################################################################
### cluster manipulation
package Cluster;

sub new {
  my ($class, $self) = @_;
  bless ($self, $class);
}

sub delete_data($) {
  my $cluster = shift;

  map main::async ( sub {
                      my $cs = $_[0];
                      my $cmd = join ' ', map { "rm -rf /data/$_/$cs->{appname} &" } (1..$cs->{max_disk_num});
                      $cmd .= 'rm -rf $main::settings->{ob_home}/{log,data,run,etc/*.bin} &';
                      $cmd .= 'wait';
                      common::do_ssh($cs->{ip}, $cmd, "Deleting data of cs: $cs->{ip}");
                    }, $_
                  ), @{$cluster->{chunkserver}};

  map {
    my $cmd = "rm -rf $main::settings->{ob_home}/{log,data,run,etc/*.bin}";
    common::do_ssh($_->{ip}, $cmd, "Deleting data of ms: $_->{ip}");
  } (@{$cluster->{mergeserver}}, @{$cluster->{listen_mergeserver}});

  map {
    my $ups = $_;
    my $cmd = join ' ', map { "rm -rf /data/$_/ups_data/$ups->{appname}/ &" } (1..$ups->{max_disk_num});
    $cmd .= "rm -rf $ups->{commitlog_dir} &";
    $cmd .= "rm -rf $ups->{storage_commitlog_dir} &";
    $cmd .= "rm -rf $main::settings->{ob_home}/{log,data,run,etc/*.bin} &";
    $cmd .= "wait";
    common::do_ssh($ups->{ip}, $cmd, "Deleting data of ups: $ups->{ip}");
  } @{$cluster->{updateserver}};

  map {
    my $cmd = "rm -rf $main::settings->{ob_home}/{log,data,run,etc/*.bin}";
    common::do_ssh($_->{ip}, $cmd, "Deleting data of rs: $_->{ip}");
  } @{$cluster->{rootserver}};

  $_->join() for threads->list();
}

sub stop {
  my $self = shift;
  my $force_stop = undef;
  my $first_stop = undef;
  my $opts = (shift or undef);
  if ($opts) {
    $force_stop = 1 if (exists $opts->{force_stop} and $opts->{force_stop});
    $first_stop = 1 if (exists $opts->{first_stop} and $opts->{first_stop});
  }

  my $kill_opts = ($force_stop and '-9' or '');
  while (my ($k, $v) = each %$self) {
    if ($k eq 'rootserver') {
      map { common::do_ssh($_->{ip},
                           "kill $kill_opts `cat run/rootserver.pid`",
                           "Stopping $_->{server_type} [$_->{ip}]", 1) } @$v;
    } elsif ($k eq 'updateserver') {
      map { common::do_ssh($_->{ip},
                           "kill $kill_opts `cat run/updateserver.pid`",
                           "Stopping $_->{server_type} [$_->{ip}]", 1) } @$v;
    } elsif ($k eq 'chunkserver') {
      map { common::do_ssh($_->{ip},
                           "kill $kill_opts `cat run/chunkserver.pid`",
                           "Stopping $_->{server_type} [$_->{ip}]", 1) } @$v;
    } elsif ($k eq 'mergeserver' or $k eq 'listener_mergeserver') {
      my $select = sub { return $_[0]->{$_[1]} };
      my $short_name = $select->({'mergeserver'=>'ms', 'listener_mergeserver'=>'lms'}, $k);
      my $conf_name = $select->({'mergeserver'=>'supervisor', 'listener_mergeserver'=>'lms_supervisor'}, $k);
      for (@$v) {
        if ($first_stop or not $_->{$conf_name} =~ m/true/i) {
          common::do_ssh($_->{ip}, "kill $kill_opts `cat run/mergeserver.pid`",
                         "Stopping $_->{server_type} [$_->{ip}]", 1);
        } else {
          common::do_ssh($_->{ip},
                         "supervisorctl reread > /dev/null",
                         "Reloading supervisor config [$_->{ip}]")
              and common::perror_exit("Reload supervisor daemon conf failed");

          common::do_ssh($_->{ip},
                         "supervisorctl status $short_name | grep -q RUNNING",
                         "Checking lms running status [$_->{ip}]")
              and common::pwarn("$short_name is already stopped") and next;

          common::do_ssh($_->{ip},
                         "supervisorctl stop $short_name > /dev/null",
                         "Stopping $short_name using supervisor [$_->{ip}]");

          common::do_ssh($_->{ip},
                         "supervisorctl status $short_name | grep -q RUNNING",
                         "Checking $short_name running status [$_->{ip}]")
              and common::pinfo("Stop $short_name done");
        }
      }
    }
  }
}

sub status($) {
  my $self = shift;
  my ($absense_any, $found_any) = (0, 0);

  my @servers = ('rootserver', 'mergeserver', 'chunkserver', 'updateserver');
  my %ip_list = ();
  map { $ip_list{$_} = [] } @servers;
  while (my ($k, $v) = each %$self) {
    my @server_name = grep { $k =~ /(?<!master_)$_$/ } @servers;
    if (@server_name > 0) {
      my $server_bin = shift @server_name;
      map { push @{$ip_list{$server_bin}}, $_->{ip} } @$v;
    }
  }

  common::pinfo("cluster id: [$self->{cluster_id}]");
  while (my ($k, $v) = each %ip_list) {
    common::pinfo("$k:");
    map {
      printf "%10s%-16s: ", '', $_;
      if (common::do_ssh($_, "ps -C $k -o cmd,user,pid | grep admin", "", 1)) {
        print "absense of *$k*\n";
        $absense_any = 1;
      } else {
        $found_any = 1;
      }
    } @$v;
  }
  ($absense_any, $found_any);
}

sub check_ssh($) {
  my $cluster = shift;
  my @all_servers_type = grep { /^[^_]+server$/ } keys %$cluster;
  my %all_ips;
  for my $server_type (@all_servers_type) {
    map { $all_ips{$_->{ip}} = 1; } @{$cluster->{$server_type}};
  }
  map { common::check_ssh($_) } keys %all_ips;
}

sub start_rootservers($) {
  my $self = shift;
  my $rootservers = $self->{rootserver};
  map {
    $self->__start_one_rootserver($_);
  } @$rootservers;
}

sub start_chunkservers($) {
  my $self = shift;
  my $chunkservers = $self->{chunkserver};
  map {
    $self->__start_one_chunkserver($_);
  } @$chunkservers;
}

sub start_mergeservers($) {
  my $self = shift;
  my ($mergeservers, $master_rootserver, $rs_port) = ($self->{mergeserver},
                                                      $self->{master_rootserver}, $self->{rs_port});
  my $cfg = $main::init_cfg->{mergeserver};
  my $init_cfg_str = join ',',map { "$_=$cfg->{$_}" } keys %$cfg;
  $init_cfg_str .= ',' . config::common_extra_init_cfg();
  for my $ms (@$mergeservers) {
    my $cmd = "bin/mergeserver -r $master_rootserver:$rs_port -p $ms->{port} -z $ms->{sql_port} -n $ms->{appname} -C $ms->{cluster_id}";
    $cmd .= " -i " . common::get_devname($ms->{ip});
    $cmd .= " -o \"$init_cfg_str\"" if $init_cfg_str;
    common::do_ssh($ms->{ip}, $cmd, "Start $ms->{server_type} [$ms->{ip}]");
  }
}

sub start_updateservers($$$) {
  my $self = shift;
  my $updateservers = $self->{updateserver};
  map {
    $self->__start_one_updateserver($_);
  } @$updateservers;
}

sub start_lms($) {
  my $self = shift;
  my ($lmss, $master_rootserver, $rs_port) = ($self->{listener_mergeserver},
                                              $self->{master_rootserver}, $self->{rs_port});

  my $init_cfg = $main::init_cfg->{mergeserver};
  my $init_cfg_str = join ',',map { "$_=$init_cfg->{$_}" } keys %$init_cfg;
  $init_cfg_str .= ',' . config::common_extra_init_cfg();

  for my $lms (@$lmss) {
    my $cmd = "bin/mergeserver -r $master_rootserver:$rs_port -p $lms->{port} -z $lms->{lms_port} -t lms -n $lms->{appname} -C $lms->{cluster_id}";
    $cmd .= " -i " . common::get_devname($lms->{ip});
    $cmd .= " -o \"$init_cfg_str\"" if $init_cfg_str;
    common::do_ssh($lms->{ip}, $cmd, "Start $lms->{server_type} [$lms->{ip}]");
  }
}

sub start($$) {
  my ($self, $first) = @_;

  if ($first) {
    $self->start_rootservers();
    $self->start_updateservers();
    $self->start_chunkservers();
    $self->start_mergeservers();
    $self->start_lms();
  } else {
    while (my ($k, $v) = each %$self) {
      if ($k eq 'rootserver') {
        map { common::do_ssh($_->{ip}, "bin/rootserver", "Start $_->{server_type} [$_->{ip}]") } @$v;
      } elsif ($k eq 'updateserver') {
        map { common::do_ssh($_->{ip}, "bin/updateserver", "Start $_->{server_type} [$_->{ip}]") } @$v;
      } elsif ($k eq 'chunkserver') {
        map { common::do_ssh($_->{ip}, "bin/chunkserver", "Start $_->{server_type} [$_->{ip}]") } @$v;
      } elsif ($k eq 'mergeserver' or $k eq 'listener_mergeserver') {
        my $select = sub { return $_[0]->{$_[1]} };
        my $short_name = $select->({'mergeserver'=>'ms', 'listener_mergeserver'=>'lms'}, $k);
        my $conf_name = $select->({'mergeserver'=>'supervisor', 'listener_mergeserver'=>'lms_supervisor'}, $k);
        # start ms using supervisor
        for (@$v) {
          unless ($_->{$conf_name} =~ m/true/i) {
            common::do_ssh($_->{ip}, "bin/mergeserver", "Start $_->{server_type} [$_->{ip}]");
          } else {
            common::do_ssh($_->{ip},
                           "supervisorctl reread > /dev/null",
                           "Reload supervisor config [$_->{ip}]")
                and common::perror_exit("reload supervisor daemon conf failed");

            common::do_ssh($_->{ip},
                           "supervisorctl status $short_name | grep -q RUNNING",
                           "Checking $short_name running status [$_->{ip}]")
                or common::pwarn("$short_name is already started") and next;

            common::do_ssh($_->{ip},
                           "supervisorctl add $short_name > /dev/null",
                           "start $short_name using supervisor [$_->{ip}]");

            common::do_ssh($_->{ip},
                           "supervisorctl start $short_name > /dev/null",
                           "start $short_name using supervisor [$_->{ip}]");

            common::do_ssh($_->{ip},
                           "supervisorctl status $short_name | grep -q RUNNING",
                           "Checking $short_name running status [$_->{ip}]")
                  and common::pinfo("$short_name is started");
          }
        }
      }
    }
  }
}

sub enable_cluster($) {
  my $self = shift;
  my $cmd = "alter system start cluster cluster_id=" . $self->{cluster_id};
  common::do_init_sql($cmd);
}

# belows are private functions
sub __start_one_rootserver($$) {
  my ($self, $rs) = @_;
  common::perror_exit("Not rootserver!") unless $rs->{server_type} eq 'rootserver';

  my $init_cfg = $main::init_cfg->{rootserver};
  my $init_cfg_str = join ',',map { "$_=$init_cfg->{$_}" } keys %$init_cfg;
  $init_cfg_str .= config::rs_extra_init_cfg() . ',' . config::common_extra_init_cfg();
  my $cmd = '';
  $cmd .= "bin/rootserver -p $rs->{port} -C $rs->{cluster_id} -n $rs->{appname}";
  $cmd .= " -i " . common::get_devname($rs->{ip});
  $cmd .= " -o \"$init_cfg_str\"" if $init_cfg_str;
  common::do_ssh($rs->{ip}, $cmd, "Start $rs->{server_type} [$rs->{ip}]");
}

sub __start_one_chunkserver($$$) {
  my ($self, $cs) = @_;
  my ($master_rootserver, $rs_port) = ($self->{master_rootserver}, $self->{rs_port});
  common::perror_exit("Not chunkserver!") unless $cs->{server_type} eq 'chunkserver';

  my $init_cfg = $main::init_cfg->{chunkserver};
  my $init_cfg_str = join ',',map { "$_=$init_cfg->{$_}" } keys %$init_cfg;
  $init_cfg_str = config::common_extra_init_cfg() . ',' . $init_cfg_str;
  my $cmd = 'true';
  if ($main::action eq "init") {
    $cmd = <<EOF;
for ((i=1; i<=$cs->{max_disk_num}; i++))
do
  mkdir -p /data/\$i/$cs->{appname}/sstable;
done &&
mkdir -p data &&
for ((i=1; i<=$cs->{max_disk_num}; i++))
do
  ln -s -T /data/\$i data/\$i;
done
EOF
    common::do_ssh($cs->{ip}, $cmd, , "Prepare $cs->{server_type} [$cs->{ip}]");
  }
  $cmd = "bin/chunkserver -r $master_rootserver:$rs_port "
      . "-p $cs->{port} -n $cs->{appname} -C $cs->{cluster_id}";
  $cmd .= " -i " . common::get_devname($cs->{ip});
  $cmd .= " -o \"$init_cfg_str\"" if $init_cfg_str;
  common::do_ssh($cs->{ip}, $cmd, , "Start $cs->{server_type} [$cs->{ip}]");
}

sub __start_one_updateserver($) {
  my ($self, $ups) = @_;
  my ($master_rootserver, $rs_port) = ($self->{master_rootserver}, $self->{rs_port});
  common::perror_exit("Not updateserver!") unless $ups->{server_type} eq 'updateserver';

  my $cfg = $main::init_cfg->{updateserver};
  my $init_cfg_str = join ',',map { "$_=$cfg->{$_}" } keys %$cfg;
  $init_cfg_str = config::common_extra_init_cfg() . $init_cfg_str;
  my $cmd = 'true';
  if ($main::action eq "init") {
    $cmd = <<EOF;
for ((i=1; i<=$ups->{max_disk_num}; i++))
do
  mkdir -p /data/\$i/ups_data/$ups->{appname}/sstable;
done &&
mkdir -p data/ups_data &&
for ((i=1; i<=$ups->{max_disk_num}; i++))
do
  ln -s -T /data/\$i/ups_data data/ups_data/\$i;
done &&
mkdir -p $ups->{commitlog_dir} &&
ln -s $ups->{commitlog_dir} data/ups_commitlog &&
mkdir -p $ups->{storage_commitlog_dir} &&
ln -s $ups->{storage_commitlog_dir} data/storage_tablet_commitlog;
EOF
    common::do_ssh($ups->{ip}, $cmd, "Prepare $ups->{server_type} [$ups->{ip}]");
  }
  $cmd = "bin/updateserver -r $master_rootserver:$rs_port "
      . "-p $ups->{port} -m $ups->{inner_port} -n $ups->{appname} -C $ups->{cluster_id}";
  $cmd .= " -i " . common::get_devname($ups->{ip});
  $cmd .= " -o \"$init_cfg_str\"" if $init_cfg_str;
  common::do_ssh($ups->{ip}, $cmd, "Start $ups->{server_type} [$ups->{ip}]");
}

#############################################################################
## start server and cluster
package main;
local *main::pinfo = *common::pinfo;
local *main::pdebug = *common::pdebug;
local *main::perror_exit = *common::perror_exit;

sub local_op($$$) {
  $_ = $_[0];
  my ($op, $server) = ();
  my %svr_map = ('cs' => 'chunkserver', 'ms' => 'mergeserver',
                 'ups' => 'updateserver', 'rs' => 'rootserver',
                 'lms' => 'listener_mergeserver', 'is' => 'importserver',
                 'ps' => 'proxyserver');

  if (/^(start|stop)_(lms|cs|ms|ups|rs|is|ps)$/) {
    $op = $1;
    $server = $svr_map{$2};
  } else {
    perror_exit("`$_' is an unvalid action!");
  }
  common::do_server($op, $server, $_[1], $_[2]);
}

sub create_server_list($) {
  my $clusters = shift;
  pinfo ("create server list.");

  my $all_rs_list = '/tmp/all_rs_list.' . $clusters->[0]->{appname};
  my $all_cs_list = '/tmp/all_cs_list.'  . $clusters->[0]->{appname};
  my $all_ups_list = '/tmp/all_ups_list.' . $clusters->[0]->{appname};

  my @all_list_file = ($all_rs_list, $all_cs_list, $all_ups_list);
  map {
     open my $fh, '>', $_;
     close $fh;
  } @all_list_file;

  map {
    my $filename = '/tmp/rs_list.' . $_->{cluster_id} . '.' . $_->{appname};
    open my $fh, '>', $filename;
    map { print $fh "$_->{ip}\n" } @{$_->{rootserver}};
    close $fh;
    system("cat $filename >> $all_rs_list");
  } @$clusters;
  map {
    my $filename = '/tmp/ups_list.' . $_->{cluster_id} . '.' . $_->{appname};
    open my $fh, '>', $filename;
    map { print $fh "$_->{ip}\n" } @{$_->{updateserver}};
    close $fh;
    system("cat $filename >> $all_ups_list");
  } @$clusters;
  map {
    my $filename = '/tmp/cs_list.' . $_->{cluster_id}. '.' . $_->{appname};
    open my $fh, '>', $filename;
    map { print $fh "$_->{ip}\n" } @{$_->{chunkserver}};
    close $fh;
    system("cat $filename >> $all_cs_list");
  } @$clusters;
  map {
    my $rs_list_name = '/tmp/rs_list.' . $_->{cluster_id}. '.' . $_->{appname};
    my $ups_list_name = '/tmp/ups_list.' . $_->{cluster_id}. '.' . $_->{appname};
    my $cs_list_name = '/tmp/cs_list.' . $_->{cluster_id}. '.' . $_->{appname};
    map {
      system ("scp -q $rs_list_name $_->{ip}:~/oceanbase/rs_list");
      system ("scp -q $ups_list_name $_->{ip}:~/oceanbase/ups_list");
      system ("scp -q $cs_list_name $_->{ip}:~/oceanbase/cs_list");
      system ("scp -q $all_cs_list $_->{ip}:~/oceanbase/all_cs_list");
      system ("scp -q $all_rs_list $_->{ip}:~/oceanbase/all_rs_list");
      system ("scp -q $all_ups_list $_->{ip}:~/oceanbase/all_ups_list");
    } @{$_->{rootserver}};
  } @$clusters;
  pinfo ("create server list done!");
}

sub stop_all_server_until_success {
  my $clusters = shift;
  my $opts = (shift or undef);

  ### restart all servers
  map {
    $_->stop($opts);
  } @$clusters;

  my $found_any = 0;
  for (1..20) {
    map {
      $found_any = ($_->status())[1];
      pdebug("found_any: $found_any");
      pinfo("Waiting all server stop!") if $found_any;
      sleep 3 && next if $found_any;
    } @$clusters;
    last if not $found_any;
  }
  $opts->{force_stop} = 1;
  map {
    $_->stop($opts);
  } @$clusters;

  for (1..20) {
    map {
      $found_any = ($_->status())[1];
      pdebug("found_any: $found_any");
      pinfo("Waiting all server stop!") if $found_any;
      sleep 3 && next if $found_any;
    } @$clusters;
    last if not $found_any;
  }
  perror_exit("Stop all servers not successfully.") if $found_any;
  pinfo("Stop all done!");
}

sub start_all_server_until_success($) {
  my $clusters = shift;

  map {
    $_->start();
  } @$clusters;

  my $absense_any = 0;
  for (1..20) {
    map {
      $absense_any = ($_->status())[0];
      pdebug("absense_any: $absense_any");
      pinfo("Waiting all server start!") if $absense_any;
      sleep 3 && next if $absense_any;
    } @$clusters;
    last if not $absense_any;
  }
  perror_exit("Start all servers not successfully.") if $absense_any;
  pinfo("Start all done!")
}

sub all_op {
  my $help = '';
  my $force = '';
  my $cluster_id = '';
  my $cfg_file = 'default.conf';
  my $supervisor = undef;
  my $result = GetOptions("force"     => \$force,
                          "cluster=s" => \$cluster_id,
                          "supervisor" => \$supervisor,
                          "debug"     => \$debug) or pod2usage(1);
  if (@ARGV == 1) {
    return local_op($ARGV[0], $force, $supervisor);
  } elsif (@ARGV == 2) {
    $action = shift @ARGV;
    $cfg_file = pop @ARGV;
    unless ($action =~ m/^dump$|^init$|^clean$|^stop$|^start$|^check$|^mysql$|^status$|^force_stop$/) {
      pod2usage(1);
      exit(1);
    }
  } else {
    pod2usage(1);
    exit(1);
  }

  config::init($cfg_file);
  my @cur_clusters = grep { (not $cluster_id) or $_->{cluster_id} eq $cluster_id } @clusters;

  if ($action eq "dump") {
    print Dumper(@clusters);
    exit(0);
  } elsif ($action eq "clean") {
    $|=1;
    print "Will *DELETE ALL DATA* from servers, sure? [y/N] ";
    read STDIN, my $char, 1;
    exit (0) if $char ne 'y' and $char ne 'Y';

    pinfo("");
    pinfo("Begin check ssh connection");
    map { $_->check_ssh() } @cur_clusters;
    pinfo("");
    pinfo("Begin check servers alive");
    map {
      my $found_any = ($_->status())[1];
      perror_exit("There're still servers running, can't clean data") if $found_any;
    } @cur_clusters;
    pinfo("");
    pinfo("Begin delete data");
    map { $_->delete_data() } @cur_clusters;
    exit(0);
  } elsif ($action =~ "start") {
    map { $_->check_ssh() } @cur_clusters;
    map {
      $_->start(0);
    } @cur_clusters;
  } elsif ($action =~ "init") {
    if (not $force) {
      $|=1;
      print "Will *DELETE ALL DATA* from servers, sure? [y/N] ";
      read STDIN, my $char, 1;
      exit (0) if $char ne 'y' and $char ne 'Y';
    }

    pinfo("");
    pinfo("Begin check ssh connection");
    map { $_->check_ssh() } @cur_clusters;
    pinfo("");
    pinfo("Begin create servers list");
    create_server_list(\@cur_clusters);
    pinfo("");
    pinfo("Begin start servers");
    map {
      $_->start(1);
    } @cur_clusters;

    sleep(10);                  # waiting for rootserver election
    if (0 != common::bootstrap()) {
      perror_exit("Bootstrap fail.");
    } else {
      pinfo("Bootstrap successfully.");
    }
    map {
      0 == $_->enable_cluster() and pinfo("Enable cluster $_->{cluster_id} done");
    } @cur_clusters;

    pinfo("");
    pinfo("Begin verifing status");
    my $verify_ok = 1;
    for (1..6) {
      sleep 10;
      $verify_ok = common::verify_bootstrap() and last;
    }
    perror_exit("OceanBase verify failed.") unless $verify_ok;

    pinfo("");
    pinfo("Begin restart servers");
    stop_all_server_until_success(\@cur_clusters, {first_stop => 1});
    start_all_server_until_success(\@cur_clusters);

    pinfo("");
    for (1..100) {
      last if common::do_sql("select 1") == 0;
      pinfo("Waiting for oceanbase initialization");
      sleep 1;
    }

    pinfo("Enjoy it!");
    exit(0);
  } elsif ($action eq "stop") {
    if (not $force) {
      $|=1;
      print "Stop all server!! Sure? [y/N] ";
      read STDIN, my $char, 1;
      exit (0) if $char ne 'y' and $char ne 'Y';
    }
    map { $_->check_ssh() } @cur_clusters;
    stop_all_server_until_success(\@cur_clusters);
  } elsif ($action eq "force_stop") {
    if (not $force) {
      $|=1;
      print "Force stop all server (kill -9)!! Sure? [y/N] ";
      read STDIN, my $char, 1;
      exit (0) if $char ne 'y' and $char ne 'Y';
    }
    map { $_->check_ssh() } @cur_clusters;
    stop_all_server_until_success(\@cur_clusters, {force_stop => 1});
  } elsif ($action eq 'status') {
    map { $_->check_ssh() } @cur_clusters;
    map { $_->status() } @cur_clusters;
  } elsif ($action eq "check") {
    map { $_->check_ssh() } @cur_clusters;
    common::verify_bootstrap;
  } elsif ($action eq "mysql") {
    common::run_mysql;
  }
}

sub main {
  pod2usage(1) if ((@ARGV < 1) && (-t STDIN));
  return all_op($ARGV[0]);
}

main;

__END__

=head1 NAME

    oceanbase.pl - a script to deploy oceanbase clusters.

=head1 SYNOPSIS

=item oceanbase.pl B<Action> [L<Options>] config_file  (1st form)

=item oceanbase.pl B<Local_Action> [L<Options>]        (2nd form)

=back

=begin pod

    +----------------------------------------------------------------------+
    | Normal order using this script:                                      |
    |                                                                      |
    | 1. edit config_file as you like.                                     |
    | 2. run `./oceanbase.pl init config_file' to init all ob cluster.     |
    | 3. run `./oceanbase.pl check config_file' to verify weather ob is ok.|
    +----------------------------------------------------------------------+

=end pod

=head2 ACTION

=item init

Init oceanbase as L<config_file> descripted. It'll create necessary directories and links.

=item check

[not support now] Run quick test for oceanbase to check if instance is running correctly.

=item start

Only start servers.

=item stop

Stop all servers.

=item force_stop

Stop all servers using `kill -9' which is differ from `stop' action with `--force' option.
`--force' option is used for whether oceanbase.pl would asking user to performe action before execute this action.

=item dump

Dump configuration read from config_file.

=item clean

B<clean> all data involving user data and system data, besure all servers are stopped.

=item mysql

Connect to ob with listener ms.

=head2 LOCAL_ACTION

=item start_rs|stop_rs

=item start_cs|stop_cs

=item start_ms|stop_ms [--supervisor]

=item start_ups|stop_ups

=item start_lms|stop_lms [--supervisor]

=item start_is|stop_is

=item start_ps|stop_ps

=head1 OPTIONS

=item B<--cluster,-c> CLUSTER_ID

All actions is for that cluster except for dump.

=item B<--force>

Force run command without asking anything.

=item B<--debug>

Run in debug mode.

=back

=head1 AUTHOR

Yudi Shi - L<fufeng.syd@alipay.com>

=head1 DESCRIPTION

=cut
