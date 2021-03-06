#!/usr/bin/env perl
### This is a watchdog for snagc[.pl]

use strict;

use FindBin qw($Bin $Script);

use SNAG;
use Config::General qw/ParseConfig/; 
use Cwd qw(abs_path);
use File::Basename;
use File::Spec::Functions qw/rootdir catpath catfile devnull catdir/;
use File::stat;
use Mail::Sendmail;
use Proc::ProcessTable;
use Sys::Hostname;
use Sys::Syslog;
use Data::Dumper;


if($SNAG::flags{compile})
{
  unless($ENV{PAR_SPAWNED})
  {
    my $dest_bin = 'snagw';
    my $src_script = catfile( $Bin, $Script );

    my $includes;
    for my $include_file ($ENV{PP_INCLUDES}, $ENV{SNAGW_INCLUDES}) {
        unless ( -r $include_file ) {
            warn "$include_file does not exist - skipping\n";
            next;
        }
        open (my $fh, '<', $include_file) || die "Could not open $include_file - $!\n";
        while (<$fh>) {
            chomp;
            next unless (/\w+/);
            $includes .= " -M $_";
        }
        close($fh);
    }

    my $cmd = "pp $0 --compile --cachedeps=/var/tmp/snag.pp --execute --bundle";
    $cmd .= " $includes";
    $cmd .= " -a /opt/snag/snag.conf --reusable -o snagw";
    #-a "/opt/snag/lib/perl5/site_perl/5.12.1/XML/SAX/ParserDetails.ini;ParserDetails.ini"

    print "Compiling $src_script to $dest_bin ... ";
    print "with cmd $cmd\n";
    my $out;
    open LOG, "$cmd |" || die "DIED: $!\n";
    while (<LOG>)
    {
      print $_;
      $out .= $_;
    }

    print "Done!\n";

    if($out =~ /\w/)
    {
      print "=================== DEBUG ==================\n";
      print $out;
    }
  }
  else
  {
    print "This is already a compile binary!\n";
  }

  exit;
}

my $script   = BASE_DIR . "/bin/" . "snagc";
my $script_x = BASE_DIR . "/bin/" . "snagx";

#
# safety check to detect any abnormal snagc behaviour
#

my %pids;
# are snag[cx] already running?
my $procs = Proc::ProcessTable->new();
for my $proc (@{$procs->table()}) {
  if ($proc->cmndline() =~ /($script|$script_x)/) {
    my $foundproc = $1;
    $pids{basename($foundproc)} = $proc->pid();
    print "Found " . basename($foundproc) . " running.\n" if $SNAG::flags{debug};
  }
}

# FIXME: if we ever need snagw to run on windows, the mountpoint usage check will need re-writing...
print "Checking mountpoint usage...\n" if $SNAG::flags{debug};
my %mountpoints;
open(my $df, "df -k |") || die "Could not run df - $!\n";
while (<$df>) {
  next if (/^Filesystem/);
  my (undef, undef, undef, undef, $used, $mount) = split();
  $used =~ s/%//;
  $mountpoints{$mount} = $used;
}
close($df);

# where is BASE_DIR mounted?
my $absdirname = abs_path(BASE_DIR);
my ($basedir) = (File::Spec->splitdir($absdirname))[1];
$basedir = '/' . $basedir;
my $snag_mounted_on = $mountpoints{$basedir} ? $basedir : '/';

print "Checking available disk space...\n" if $SNAG::flags{debug};
# check to ensure whatever mount point BASE_DIR is found is under 98% full...
my $above_disk_threshold = $mountpoints{$snag_mounted_on} >= 98 ? 1 : 0;
if ($above_disk_threshold) {
  # we're above the disk usage threshold, if any snag daemons are running, kill them...
  openlog('snagw', 'ndelay', 'user');
  syslog('notice', "disk usage threshold: $snag_mounted_on is $mountpoints{$snag_mounted_on}% full " . HOST_NAME);
  closelog();
  for my $daemon (keys(%pids)) {
    # for safety, to ensure queue files don't fill up the disk we'll kill the daemons...
    for my $attempt (1..3) {
      kill 'TERM', $pids{$daemon};
      sleep 1;
      last unless ((kill 0, $pids{$daemon}));
      if ($attempt == 3) {
        print "Tried to kill $daemon with PID $pids{$daemon} $attempt times, failed.\n" if $SNAG::flag{debug};
      }
    }
  }
  print "$snag_mounted_on is $mountpoints{$snag_mounted_on}% full.  Exiting.\n" if $SNAG::flags{debug};
  exit();
}
     
# check to ensure queue files are not above 200MB
print "Checking size of queue files in " . LOG_DIR . "...\n" if $SNAG::flags{debug};
opendir(my $logdir, LOG_DIR) || die "Could not open " . LOG_DIR . " - $!\n";
for my $filefound (grep /queue/, readdir($logdir)) {
  my $queue_file_path = File::Spec->catfile($logdir, $filefound);
  my $filesize = (-s $queue_file_path);
  if ($filesize >= 100000000) {
    openlog('snagw', 'ndelay', 'user');
    syslog('notice', "queue file error: file is $filesize bytes " . HOST_NAME);
    closelog();
    print "$queue_file_path is $filesize bytes, wrote to syslog\n" if $SNAG::flags{debug};
  }
}
closedir($logdir);

# check that snagc is updating the queue file...
print "Checking mtime of files in " . LOG_DIR . "...\n" if $SNAG::flags{debug};
# not doing the queue file mtime check for snagx queue files because it's possible for a product
# to be purposely down and thus *_snagx will not run and thus not update queue files...
my $check_time = 600;
my @files_to_check = qw (snagc_sysrrd_client_queue.dat service_monitor.state);
foreach my $file (@files_to_check)
{
  my $file_to_check = File::Spec->catfile(LOG_DIR, $file);
  my $now  = time();
  eval
  {
    my $stat = stat($file_to_check) or die "error checking file $file_to_check: $!";
    # we're concerned if the file has not been modified in $check_time seconds
    if (($now - $stat->mtime()) >= $check_time) 
    {
      openlog('snagw', 'ndelay', 'user');
      syslog('notice', "snag: $file_to_check older than $check_time seconds " . HOST_NAME);
      closelog();
      print "$file_to_check is older than $check_time seconds, wrote to syslog\n" if $SNAG::flags{debug};
    }
  };
  if ($@)
  {
    print "$@\n" if $SNAG::flags{debug};
  }
}
print "Checks complete.\n" if $SNAG::flags{debug};

#start snagc unless it's already running...
unless ($pids{snagc}) {
  if (-x $script) {
    print "Starting $script ... " if $SNAG::flags{debug};
    system $script;
    print "Done!\n" if $SNAG::flags{debug};
  }
}

# start snagx unless it's aready running...
unless ($pids{snagx}) {
   if (-x $script_x) {
    print "Starting $script_x ... " if $SNAG::flags{debug};
    system $script_x;
    print "Done!\n" if $SNAG::flags{debug};
  }
}

### Start any additional snags.pl or snagp.pl, if configured to run on this host
my $conf = CONF;

if($conf->{server})
{
  foreach my $server (keys %{$conf->{server}})
  {
    my $script_bin = $server . '_snags';
    my $script_path = BASE_DIR . "/bin/" . $script_bin;

    print "Starting $script_path ... " if $SNAG::flags{debug};
    system $script_path;
    print "Done!\n" if $SNAG::flags{debug};
  }
}

if($conf->{poller})
{
  foreach my $poller (keys %{$conf->{poller}})
  {
    my $default_bin   = BASE_DIR . "/bin/" . $poller . '_snagp';
    my $alternate_bin = BASE_DIR . "/bin/" . $poller . '_snagp.pl';
    for my $script_path ($default_bin, $alternate_bin) {
      if (-e $script_path) {
        print "Starting $script_path ..." if $SNAG::flags{debug};
        system $script_path;
        print "Done!\n" if $SNAG::flags{debug};
        last;
      }
    }
  }
}

exit 0 if $SNAG::flags{nosyslog};

print "Sending syslog heartbeat ... " if $SNAG::flags{debug};
openlog('snagw', 'ndelay', 'user');
syslog('notice', 'syslog heartbeat from ' . HOST_NAME);
closelog();
print "Done!\n" if $SNAG::flags{debug};
