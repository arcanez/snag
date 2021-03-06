package SNAG::Source::SystemInfo;
use base qw/SNAG::Source/;

use SNAG;
use POE;
use POE::Filter::Reference;
use Carp qw(carp croak);
use Data::Dumper;
use FreezeThaw qw/freeze/;
use Try::Tiny;
use Date::Parse;
use Date::Format;
use DBM::Deep;
use DBM::Deep::Engine::File; 
use DBM::Deep::Iterator::File;      

if(OS ne 'Windows')
{
  require POE::Wheel::Run;
}

my $timeout = 6000; #Seconds

my $debug = $SNAG::flags{debug};

my $shared_data = $SNAG::Dispatch::shared_data;

##################################
sub new
##################################
{
  my $package = shift;
  $package->SUPER::new(@_);

  my $mi = $package . '->new()';

  croak "$mi requires an even number of parameters" if (@_ & 1);
  my %params = @_;

  foreach my $p (keys %params)
  {
    warn "Unknown parameter $p";
  }

  my $module = 'SNAG/Source/SystemInfo/' . OS;
  (my $namespace = $module) =~ s#/#::#g;

  eval
  {
    require $module . '.pm';
    import $namespace ':all';
  };
  if($@)
  {
    die "SystemInfo: Problem loading $module: $@";
  }

  my ($config, %symbol_table);
  {
    no strict 'refs';
    $config = ${$namespace . '::config'};
    %symbol_table = %{$package . '::'};
  }

  my ($schedule, $min_period);
  while(my ($piece, $ref) = each %$config)
  {
    if(defined $min_period)
    {
      $min_period = $ref->{period} if $ref->{period} < $min_period;
    }
    else
    {
      $min_period = $ref->{period};
    }
  }

  $poe_kernel->call('logger' => 'log' => "Sysinfo: processed config") if $debug;

  POE::Session->create
  (
    inline_states =>
    {
      _start => sub
      {
        my ($kernel, $heap) = @_[KERNEL, HEAP];
        $kernel->sig( CHLD => 'catch_sigchld' ); ## Does this even need to be here?

        $kernel->delay('get_info' => 2);

      },

      check_state_file => sub
      {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        my ($state_file, $state_dbm, $reset);

        $state_file = catfile(LOG_DIR, 'sysinfo_conf_files.state');

        #hope to catch 
	#config_files_check aborted: DBM::Deep: Wrong file version found - 4 - expected 3 at /opt/snag/bin/snagc line 384
        try
        {
          $state_dbm = DBM::Deep->new
          (
            file => $state_file,
            autoflush => 1,
          ) or die $!;
        } 
        catch
        {
	  $reset = 1;
          $kernel->call('logger' => 'log' => "Sysinfo: unable to open state file: $state_file: $_" );
        }
	try
	{
	  unlink $state_file if ( -w $state_file && $reset );
	}
      },

      get_info => sub
      {
        my ($kernel, $heap) = @_[KERNEL, HEAP];
        $kernel->delay($_[STATE] => $min_period);

        my $subs_to_run;

        while(my ($sub, $args) = each %$config)
        {
          if( $SNAG::Dispatch::shared_data->{control}->{ 'sysinfo_' . $sub } eq 'off' )
          {
            next;
          }

          if(my $tag = $args->{if_tag})
          {
            my $tag_match = $SNAG::Dispatch::shared_data->{tags};
            foreach my $item (split /\./, $tag)
            {
              $tag_match = $tag_match->{$item};
              last unless $tag_match;
            }

            next unless $tag_match;
          }

          unless($symbol_table{$sub})
          {
            $kernel->call('logger' => 'log' => "Sysinfo: Subroutine $sub does not exist in SNAG::Source::SystemInfo's symbol table, skipping" );
            next;
          }

          unless(($schedule->{$sub} -= $min_period) > 0)
          {
            $subs_to_run->{$sub} = $args;
            $schedule->{$sub} = $args->{period};
          }
        }

        if(%$subs_to_run)
        {
          if($heap->{wheels} && scalar(keys %{$heap->{wheels}}))
          {  
            my $count = scalar(keys %{$heap->{wheels}} );
    
	    $kernel->post('client' => 'dashboard' => 'load' => join REC_SEP, ('events', HOST_NAME, 'snagc', 'sysinfo', 'Too many forked processes', "$count processes already running", '', time2str("%Y-%m-%d %T", time())));
            $kernel->call('logger' => 'log' => "Sysinfo: $count forked processes were already running when I wanted to start a new one" );
          }
          else
          {
            if(OS eq 'Windows')
            {
	      $kernel->call('logger' => 'log' => 'Sysinfo: Running (' . (join ", ", keys %$subs_to_run) . ")\n") if $debug;
  
              my $sysinfo = info($subs_to_run);
              $kernel->yield('info_stdio' => $sysinfo);
            }
            else
            {
	      $kernel->call('logger' => 'log' => 'Sysinfo: Starting a new wheel to run (' . (join ", ", keys %$subs_to_run) . ")\n") if $debug;
    
	      my $wheel = POE::Wheel::Run->new
	      (
	        Program => sub { info($subs_to_run) },
	        StdioFilter  => POE::Filter::Reference->new('Storable'),
	        StdoutEvent  => 'info_stdio',
	        StderrEvent  => 'info_stderr',
	        CloseEvent   => "info_close",
	        Priority     => +5,
	        CloseOnCall  => 1,
	      );
    
	      $heap->{wheels}->{$wheel->ID} = $wheel;
	      $heap->{timeouts}->{$wheel->ID} = $kernel->alarm_set('timeout' => time() + $timeout => $wheel->ID);
            }
          }
        }
      },

      timeout => sub
      {
        my ($kernel, $heap, $id) = @_[KERNEL, HEAP, ARG0];

        $kernel->call('logger' => 'log' => "Sysinfo: PWR exceeded its timeout and killed after $timeout seconds:  $heap->{sysinfo_debug}"); 

        $kernel->alarm_remove($id);
        delete $heap->{timeouts}->{$id};

        $heap->{wheels}->{$id}->kill or $heap->{wheels}->{$id}->kill(9);
        delete $heap->{wheels}->{$id};
 
        $kernel->post('client' => 'dashboard' => 'load' => join REC_SEP, ('events', HOST_NAME, 'snagc', 'sysinfo', 'A Sysinfo PWR exceeded its timeout', "$timeout seconds: $heap->{sysinfo_debug}", '', time2str("%Y-%m-%d %T", time())));
      },

      info_stdio => sub
      {
        my ($kernel, $heap, $info, $wheel_id) = @_[KERNEL, HEAP, ARG0, ARG1];

        if(defined $info->{cpumem} && defined $info->{cpumem}->{cpu_count})
        {
          $shared_data->{cpu_count} = $info->{cpumem}->{cpu_count};
        }
        elsif(defined $info->{iface})
        {
          $shared_data->{iface} = $info->{iface};
        }
        elsif(defined $info->{md})
        {
          $shared_data->{mdmap} = delete $info->{mdmap};
        }
        elsif(defined $info->{lsscsi})
        {
          $shared_data->{lsscsi} = delete $info->{lsscsi};
        }
        
        if(%$info && ( my $pruned = SNAG::Source::sysinfo_prune($info) ) )
        {
          $pruned->{host} = HOST_NAME;
          $pruned->{seen} = time2str("%Y-%m-%d %T", time);

          $kernel->post('client' => 'sysinfo' => 'load' => freeze($pruned));
        }
      },

      info_stderr => sub
      {
        my ($kernel, $heap, $output) = @_[KERNEL, HEAP, ARG0];

        #shell-init: could not get current directory: getcwd: cannot access parent directories: No such file or directory
        #bash: /root/.bashrc: Permission denied
        #print STDERR join REC_SEP, ('events', HOST_NAME, 'sysinfo', 'service_state', 'service state change', "service $service is not running.  usual run rate is $pct%", '', $seen);  print STDERR "\n";

        if($output =~ /^events/)
        {
          $kernel->post('client' => 'dashboard' => 'load' => $output);
        }
        elsif($output =~ s/^\s*sysinfo_debug://)
        {
          $kernel->call('logger' => 'log' => "Sysinfo: $output") if $debug; 
          $heap->{sysinfo_debug} = $output;
        }
        else
        {
          unless($output =~ /got duplicate tcp line/
             || $output =~ /got bogus tcp line/
             || $output =~ /could not get current directory/
             || $output =~ /bashrc: Permission denied/
             || $output =~ /dev\/mem: No such file or directory/
             || $output =~ /(lspci|pcilib)/) ### annoying messages from broken lspci on xenU
          {
    	    $kernel->post('client' => 'dashboard' => 'load' => join REC_SEP, ('events', HOST_NAME, 'snagc', 'sysinfo', 'Error getting sysinfo', "$output", '', time2str("%Y-%m-%d %T", time())));
          #$kernel->call('logger' => 'log' => "Sysinfo: Error getting sysinfo: $output"); 
          }
        }
      },

      info_close => sub
      {
        my ($kernel, $heap, $id) = @_[KERNEL, HEAP, ARG0];
        $kernel->alarm_remove(delete $heap->{timeouts}->{$id});
        delete $heap->{wheels}->{$id};
      },

      catch_sigchld => sub
      {
      },
    }
  );
}

sub info
{
  POE::Kernel->stop();

  local $/;

  my $subs = shift;

  my $info = {};

  while(my ($sub, $args) = each %$subs)
  {
    no strict 'refs';

    print STDERR "sysinfo_debug:PWR: running $sub \n" if $debug;
    eval
    {
      if(my $new_info = $sub->($args))
      {
        $info = SNAG::Source::merge_hashref($info, $new_info);
      }
    };
    if ($@)
    {
      print STDERR "PWR: $sub aborted: $@ \n" if $debug;
    }
  }

  if(OS eq 'Windows')
  {
    return $info;
  }
  else
  {
    my $filter = POE::Filter::Reference->new('Storable');
    my $return = $filter->put( [ $info ] );
    print @$return;
  }

  print STDERR "sysinfo_debug:PWR subs done!\n" if $debug;
}

sub apache_version
{
  my ($execs, $contents);

  require Proc::ProcessTable;
  my $procs = Proc::ProcessTable->new;

  foreach my $proc ( @{$procs->table} )
  {
    if($proc->fname eq 'httpd' || $proc->fname eq 'masond' || $proc->fname eq 'apache' || $proc->fname eq 'apache2')
    {
      (my $exec) = (split /\s+/, $proc->{cmndline})[0];
      $execs->{ $exec } = 1;
    }
  }

  my $info;
  foreach my $exe (sort keys %$execs)
  {
    my $output = `$exe -v 2>/dev/null`;
    chomp $output;

    push @$contents, "Server binary: $exe\n$output";
  }

  $info->{conf}->{apache_version} = { contents => join "\n-------------\n", @$contents };

  return $info;
}

sub tags
{
  my $args = shift;

  eval
  {
    my $info;

    if(my $tags_data = $args->{data}->{tags})
    {
      my $tags = _get_tags($tags_data, []);

      foreach my $tag (@$tags)
      {
        push @{$info->{tags}}, { tag => $tag };
      }
    }
    return $info;
  };
}

sub listening_ports
{
  my $args = shift;

  eval
  {
    if($args->{data}->{listening_ports})
    {
      my $info;

      foreach my $port (sort keys %{$args->{data}->{listening_ports}})
      {
        foreach my $addr (sort keys %{$args->{data}->{listening_ports}->{$port}})
        {
          push @{$info->{listening_ports}}, { port => $port, addr => $addr };
        }
      }

      return $info;
    }
  };
}

sub _get_tags
{
  my ($struct, $pre) = @_;

  my $return;

  while(my ($key, $val) = each %$struct)
  {
    push @$return, (join '.', (@$pre, $key));

    if(ref $val)
    {
      push @$return, @{ _get_tags($val, [ @$pre, $key ]) };
    }
  }

  return $return;
}

1;
