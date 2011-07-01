package SHARYANTO::Proc::Daemon;
# ABSTRACT: Create preforking, autoreloading daemon

=for Pod::Coverage .

=cut

use 5.010;
use strict;
use warnings;

use Fcntl qw(:DEFAULT :flock);
use FindBin;
use IO::Select;
use POSIX;
use Symbol;

# --- globals

my @daemons; # list of all daemons

=head1 METHODS

=head2 new(%args)

Arguments:

=over 4

=item * run_as_root => BOOL (default 1)

If true, bails out if not running as root.

=item * error_log_path (required if daemonize=1)

=item * access_log_path => STR (required if daemonize=1)

=item * pid_path* => STR

=item * scoreboard_path => STR (default none)

=item * daemonize => BOOL (default 1)

=item * prefork => INT (default 3, 0 means a nonforking/single-threaded daemon)

=item * max_children => INT (default 150)

Initially the number of children spawned will follow the 'prefork' setting. If
while serving requests, all children are busy, parent will automatically
increase the number of children gradually until 'max_children'. If afterwards
these children are idle, they will be killed off until there are 'prefork'
number of children again.

=item * auto_reload_check_every => INT (default undef, meaning never)

In seconds.

=item * auto_reload_handler => CODEREF (required if auto_reload_check_every is set)

=item * after_init => CODEREF (default none)

Run after the daemon initializes itself (daemonizes, writes PID file, etc),
before spawning children. You usually bind to sockets here (if your daemon is a
network server).

=item * main_loop* => CODEREF

Run at the beginning of each child process. This is the main loop for your
daemon. You usually do this in your main loop routine:

 for(my $i=1; $i<=$MAX_REQUESTS_PER_CHILD; $i++) {
     # accept loop, or process job loop
 }

=item * before_shutdown => CODEREF (optional)

Run before killing children and shutting down.

=back

=cut

sub new {
    my ($class, %args) = @_;

    # defaults
    if (!$args{name}) {
        $args{name} = $0;
        $args{name} =~ s!.+/!!;
    }
    $args{run_as_root}            //= 1;
    $args{daemonize}              //= 1;
    $args{prefork}                //= 3;
    $args{max_children}           //= 150;

    die "BUG: Please specify main_loop routine"
        unless $args{main_loop};

    $args{parent_pid} = $$;
    $args{children} = {}; # key = pid
    my $self = bless \%args, $class;
    push @daemons, $self;
    $self;
}

sub check_pidfile {
    my ($self) = @_;
    return unless -f $self->{pid_path};
    open my($pid_fh), $self->{pid_path};
    my $pid = <$pid_fh>;
    $pid = $1 if $pid =~ /(\d+)/; # untaint
    # XXX check timestamp to make sure process is the one meant by pidfile
    return unless $pid > 0 && kill(0, $pid);
    $pid;
}

sub write_pidfile {
    my ($self) = @_;
    die "BUG: Overwriting PID without checking it" if $self->check_pidfile;
    open my($pid_fh), ">$self->{pid_path}";
    print $pid_fh $$;
    close $pid_fh or die "Can't write PID file: $!\n";
}

sub unlink_pidfile {
    my ($self) = @_;
    my $old_pid = $self->check_pidfile;
    die "BUG: Deleting active PID which isn't ours"
        if $old_pid && $old_pid != $$;
    unlink $self->{pid_path};
}

sub kill_running {
    my ($self) = @_;
    for ({sig=>"TERM", delay=>1},
         {sig=>"TERM", delay=>3},
         {sig=>"KILL"},
     ) {
        my $pid = $self->check_pidfile;
        return unless $pid;
        kill $_->{sig} => $pid;
        sleep $_->{delay} // 0;
        my $pid2 = $self->check_pidfile;
        return unless $pid2 && $pid2 == $pid;
    }
}

sub open_logs {
    my ($self) = @_;

    $self->{error_log_path} or die "BUG: Please specify error_log_path";
    open my($fhe), ">>", $self->{error_log_path}
        or die "Cannot open error log file $self->{error_log_path}: $!\n";
    $self->{_error_log} = $fhe;

    $self->{access_log_path} or die "BUG: Please specify access_log_path";
    open my($fha), ">>", $self->{access_log_path}
        or die "Cannot open access log file $self->{access_log_path}: $!\n";
    $self->{_access_log} = $fha;

}

sub close_logs {
    my ($self) = @_;
    if ($self->{_access_log}) {
        close $self->{_access_log};
    }
    if ($self->{_error_log}) {
        close $self->{_error_log};
    }
}

sub daemonize {
    my ($self) = @_;

    local *ERROR_LOG;
    $self->open_logs;
    *ERROR_LOG = $self->{_error_log};

    chdir '/'                  or die "Can't chdir to /: $!\n";
    open STDIN, '/dev/null'    or die "Can't read /dev/null: $!\n";
    open STDOUT, '>&ERROR_LOG' or die "Can't dup ERROR_LOG: $!\n";
    defined(my $pid = fork)    or die "Can't fork: $!\n";
    exit if $pid;

    unless (0) { #$self->{force}) {
        my $old_pid = $self->check_pidfile;
        die "Another daemon already running (PID $old_pid)\n" if $old_pid;
    }

    setsid                     or die "Can't start a new session: $!\n";
    open STDERR, '>&STDOUT'    or die "Can't dup stdout: $!\n";
    $self->{daemonized}++;
    $self->write_pidfile;
    $self->{parent_pid} = $$;
}

sub parent_sig_handlers {
    my ($self) = @_;
    die "BUG: Setting parent_sig_handlers must be done in parent"
        if $self->{parent_pid} ne $$;

    $SIG{INT}  = sub { $self->shutdown("INT")  };
    $SIG{TERM} = sub { $self->shutdown("TERM") };
    #$SIG{HUP} = \&reload_server;

    $SIG{CHLD} = \&REAPER;
}

# for children
sub child_sig_handlers {
    my ($self) = @_;
    die "BUG: Setting child_sig_handlers must be done in children"
        if $self->{parent_pid} eq $$;

    $SIG{INT}  = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';
}

sub init {
    my ($self) = @_;

    $self->{pid_path} or die "BUG: Please specify pid_path";
    #$self->{scoreboard_path} or die "BUG: Please specify scoreboard_path";
    $self->{run_as_root} //= 1;
    if ($self->{run_as_root}) {
        $> and die "Permission denied, daemon must be run as root\n";
    }

    $self->init_scoreboard;
    $self->daemonize if $self->{daemonize};
    warn "Daemon (PID $$) started at ", scalar(localtime), "\n";
}

# XXX use shared memory for better performance
my $SC_RECSIZE = 20;
sub init_scoreboard {
    my ($self) = @_;
    return unless $self->{scoreboard_path};
    sysopen($self->{_scoreboard_fh}, $self->{scoreboard_path}, O_RDWR | O_CREAT)
        or die "Can't initialize scoreboard path: $!";
}

sub update_scoreboard {
    my ($self, $state) = @_;
    return unless $self->{_scoreboard_fh};

    my $lock;

    if (defined $self->{_scoreboard_pos}) {
    } else {
        sysseek $self->{_scoreboard_fh}, 0, 0;
        my $rec;
        my $i = 0;
        while (sysread($self->{_scoreboard_fh}, $rec, $SC_RECSIZE)) {
            my ($pid, $state, $ts) = unpack("NCN", $rec);
            $state = chr($state);
            $i++;
            next unless $pid == $$;
            $self->{_scoreboard_pos} = ($i-1)*$SC_RECSIZE;
        }
        if (!defined($self->{_scoreboard_pos})) {
            flock $self->{_scoreboard_fh}, 2;
            $lock++;
            $self->{_scoreboard_pos} = $i*$SC_RECSIZE;
        }
    }
    if ($lock) {
        syswrite($self->{_scoreboard_fh},
                 sprintf("%-${SC_RECSIZE}s",
                         pack("NCN", $$, ord($state), time())));
        flock $self->{_scoreboard_fh}, 8;
    } else {
        sysseek $self->{_scoreboard_fh}, $self->{_scoreboard_pos}+4, 0;
        syswrite($self->{_scoreboard_fh},
                 sprintf("%-${SC_RECSIZE}s",
                         pack("CN", ord($state), time())));
    }
}

sub delete_process_from_scoreboard {
    my ($self, $pid) = @_;
    return unless $self->{_scoreboard_fh};

    my $rec;
    sysseek $self->{_scoreboard_fh}, 0, 0;
    while (sysread($self->{_scoreboard_fh}, $rec, $SC_RECSIZE)) {
        my ($pid, $state, $ts) = unpack("NCN", $rec);
        $state = chr($state);
        next unless $pid == $$;
        flock $self->{_scoreboard_fh}, 2;
        syswrite($self->{_scoreboard_fh},
                 sprintf("%-${SC_RECSIZE}s",
                         pack("NCN", 0, ".", time())));
        flock $self->{_scoreboard_fh}, 8;
        last;
    }
}

sub summarize_scoreboard {
    my ($self) = @_;
    return unless $self->{_scoreboard_fh};

    my $rec;
    my $res = {num_children=>0, num_busy=>0, num_idle=>0};
    sysseek $self->{_scoreboard_fh}, 0, 0;
    while (sysread($self->{_scoreboard_fh}, $rec, $SC_RECSIZE)) {
        my ($pid, $state, $ts) = unpack("NCN", $rec);
        $state = chr($state);
        next unless $pid;
        $res->{num_children}++;
        if ($state =~ /^[_.]$/) {
            $res->{num_idle}++;
        } else {
            $res->{num_busy}++;
        }
    }
    $res;
}

sub run {
    my ($self) = @_;

    $self->init;
    $self->set_label('parent');
    $self->{after_init}->() if $self->{after_init};

    if ($self->{prefork}) {
        # prefork children
        for (1 .. $self->{prefork}) {
            $self->make_new_child();
        }
        $self->parent_sig_handlers;

        # and maintain the population
        my $i = 0;
        while (1) {
            #sleep; # wait for a signal (i.e., child's death)
            sleep 1;
            if ($self->{auto_reload_check_every} &&
                    $i++ >= $self->{auto_reload_check_every}) {
                $self->check_reload_self;
                $i = 0;
            }
            for (my $i = keys(%{$self->{children}});
                 $i < $self->{prefork}; $i++) {
                $self->make_new_child(); # top up the child pool
            }
        }
    } else {
        $self->{main_loop}->();
    }
}

sub make_new_child {
    my ($self) = @_;

    # i don't understand this, ignoring
    ## block signal for fork
    #my $sigset = POSIX::SigSet->new(SIGINT);
    #sigprocmask(SIG_BLOCK, $sigset)
    #    or die "Can't block SIGINT for fork: $!\n";

    my $pid;
    die "fork: $!" unless defined ($pid = fork);

    if ($pid) {
        # i don't understand this, ignoring
        ## Parent records the child's birth and returns.
        #sigprocmask(SIG_UNBLOCK, $sigset)
        #    or die "Can't unblock SIGINT for fork: $!\n";
        $self->{children}{$pid} = 1;
        return;
    } else {
        # i don't understand this, ignoring
        ## Child can *not* return from this subroutine.
        #$SIG{INT} = 'DEFAULT';      # make SIGINT kill us as it did before
        ## unblock signals
        #sigprocmask(SIG_UNBLOCK, $sigset)
        #    or die "Can't unblock SIGINT for fork: $!\n";
        $self->child_sig_handlers;
        $self->set_label('child');
        $self->{main_loop}->();
        exit;
    }
}

sub set_label {
    my ($self, $label) = @_;
    $0 = $self->{name} . " [$label]";
}

sub kill_children {
    my ($self) = @_;
    warn "Killing children processes ...\n" if keys %{$self->{children}};
    for my $pid (keys %{$self->{children}}) {
        kill TERM => $pid;
    }
}

sub is_parent {
    my ($self) = @_;
    $$ == $self->{parent_pid};
}

sub shutdown {
    my ($self, $reason, $exitcode) = @_;
    $exitcode //= 1;

    warn "Shutting down daemon".($reason ? " (reason=$reason)" : "")."\n";
    $self->{before_shutdown}->() if $self->{before_shutdown};
    $self->kill_children if $self->is_parent;

    if ($self->{daemonized}) {
        $self->unlink_pidfile;
        $self->close_logs;
    }

    exit $exitcode;
}

sub REAPER {
    $SIG{CHLD} = \&REAPER;
    my $pid = wait;
    for (@daemons) {
        delete $_->{children}{$pid};
    }
}

#    check_reload_self() if (rand()*150 < 1.0); # +- every 150 secs or reqs

sub check_reload_self {
    my ($self) = @_;

    # XXX use Filesystem watcher instead of manually checking -M
    state $self_mtime;
    state $modules_mtime = {};

    my $should_reload;
    {
        my $new_self_mtime = (-M "$FindBin::Bin/$FindBin::Script");
        if (defined($self_mtime)) {
            do { $should_reload++; last } if $self_mtime != $new_self_mtime;
        } else {
            $self_mtime = $new_self_mtime;
        }

        for (keys %INC) {
            # sometimes it's undef, e.g. Params/ValidateXS.pm (directly manipulate %INC?)
            next unless defined($INC{$_});
            my $new_module_mtime = (-M $INC{$_});
            if (defined($modules_mtime->{$_})) {
                #warn "$$: Comparing file $_ on disk\n";
                if ($modules_mtime->{$_} != $new_module_mtime) {
                    #warn "$$: File $_ changes on disk\n";
                    $should_reload++;
                    last;
                }
            } else {
                $modules_mtime->{$_} = $new_module_mtime;
            }
        }
    }

    if ($should_reload) {
        warn "$$: Reloading self because script/one of the modules ".
            "changed on disk ...\n";
        # XXX not yet working, needs --force somewhere
        $self->{auto_reload_handler}->($self);
    }
}

1;
