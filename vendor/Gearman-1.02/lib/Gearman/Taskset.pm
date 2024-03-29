package Gearman::Taskset;

use strict;
use Carp ();
use Gearman::Client;
use Gearman::Util;
use Gearman::ResponseParser::Taskset;

sub new {
    my $class = shift;
    my Gearman::Client $client = shift;

    my $self = $class;
    $self = fields::new($class) unless ref $self;

    $self->{waiting} = {};
    $self->{need_handle} = [];
    $self->{client} = $client;
    $self->{loaned_sock} = {};

    return $self;
}

sub DESTROY {
    my Gearman::Taskset $ts = shift;

    if ($ts->{default_sock}) {
        $ts->{client}->_put_js_sock($ts->{default_sockaddr}, $ts->{default_sock});
    }

    while (my ($hp, $sock) = each %{ $ts->{loaned_sock} }) {
        $ts->{client}->_put_js_sock($hp, $sock);
    }
}

sub _get_loaned_sock {
    my Gearman::Taskset $ts = shift;
    my $hostport = shift;
    if (my $sock = $ts->{loaned_sock}{$hostport}) {
        return $sock if $sock->connected;
        delete $ts->{loaned_sock}{$hostport};
    }

    my $sock = $ts->{client}->_get_js_sock($hostport);
    return $ts->{loaned_sock}{$hostport} = $sock;
}

# event loop for reading in replies
sub wait {
    my Gearman::Taskset $ts = shift;

    my %parser;  # fd -> Gearman::ResponseParser object

    my ($rin, $rout, $eout) = ('', '', '');
    my %watching;

    for my $sock ($ts->{default_sock}, values %{ $ts->{loaned_sock} }) {
        next unless $sock;
        my $fd = $sock->fileno;
        vec($rin, $fd, 1) = 1;
        $watching{$fd} = $sock;
    }

    my $tries = 0;
    while (keys %{$ts->{waiting}}) {
        $tries++;

        my $nfound = select($rout=$rin, undef, $eout=$rin, 0.5);
        next if ! $nfound;

        foreach my $fd (keys %watching) {
            next unless vec($rout, $fd, 1);
            # TODO: deal with error vector

            my $sock   = $watching{$fd};
            my $parser = $parser{$fd} ||= Gearman::ResponseParser::Taskset->new(source  => $sock,
                                                                                taskset => $ts);
            eval { $parser->parse_sock($sock); };

            if ($@) {
                # TODO this should remove the fd from the list, and reassign any tasks to other jobserver, or bail.
                # We're not in an accessable place here, so if all job servers fail we must die to prevent hanging.
                die( "Job server failure: $@" );
            }
        }

        # TODO: timeout jobs that have been running too long.  the _wait_for_packet
        # loop only waits 0.5 seconds.
    }
}

# ->add_task($func, <$scalar | $scalarref>, <$uniq | $opts_hashref>
#      opts:
#        -- uniq
#        -- on_complete
#        -- on_fail
#        -- on_status
#        -- retry_count
#        -- fail_after_idle
#        -- high_priority
# ->add_task(Gearman::Task)
#

sub add_task {
    my Gearman::Taskset $ts = shift;
    my $task;

    if (ref $_[0]) {
        $task = shift;
    } else {
        my $func = shift;
        my $arg_p = shift;   # scalar or scalarref
        my $opts = shift;    # $uniq or hashref of opts

        my $argref = ref $arg_p ? $arg_p : \$arg_p;
        unless (ref $opts eq "HASH") {
            $opts = { uniq => $opts };
        }

        $task = Gearman::Task->new($func, $argref, $opts);
    }
    $task->taskset($ts);

    my $req = $task->pack_submit_packet;
    my $len = length($req);
    my $rv = $task->{jssock}->syswrite($req, $len);
    die "Wrote $rv but expected to write $len" unless $rv == $len;

    push @{ $ts->{need_handle} }, $task;
    while (@{ $ts->{need_handle} }) {
        my $rv = $ts->_wait_for_packet($task->{jssock});
        if (! $rv) {
            shift @{ $ts->{need_handle} };  # ditch it, it failed.
            # this will resubmit it if it failed.
            print " INITIAL SUBMIT FAILED\n";
            return $task->fail;
        }
    }

    return $task->handle;
}

sub _get_default_sock {
    my Gearman::Taskset $ts = shift;
    return $ts->{default_sock} if $ts->{default_sock};

    my $getter = sub {
        my $hostport = shift;
        return
            $ts->{loaned_sock}{$hostport} ||
            $ts->{client}->_get_js_sock($hostport);
    };

    my ($jst, $jss) = $ts->{client}->_get_random_js_sock($getter);
    $ts->{loaned_sock}{$jst} ||= $jss;

    $ts->{default_sock} = $jss;
    $ts->{default_sockaddr} = $jst;
    return $jss;
}

sub _get_hashed_sock {
    my Gearman::Taskset $ts = shift;
    my $hv = shift;

    my Gearman::Client $cl = $ts->{client};

    for (my $off = 0; $off < $cl->{js_count}; $off++) {
        my $idx = ($hv + $off) % ($cl->{js_count});
        my $sock = $ts->_get_loaned_sock($cl->{job_servers}[$idx]);
        return $sock if $sock;
    }

    return undef;
}

# returns boolean when given a sock to wait on.
# otherwise, return value is undefined.
sub _wait_for_packet {
    my Gearman::Taskset $ts = shift;
    my $sock = shift;  # socket to singularly read from

    my ($res, $err);
    $res = Gearman::Util::read_res_packet($sock, \$err);
    return 0 unless $res;
    return $ts->_process_packet($res, $sock);
}

sub _ip_port {
    my $sock = shift;
    return undef unless $sock;
    my $pn = getpeername($sock) or return undef;
    my ($port, $iaddr) = Socket::sockaddr_in($pn);
    return Socket::inet_ntoa($iaddr) . ":$port";
}

# note the failure of a task given by its jobserver-specific handle
sub _fail_jshandle {
    my Gearman::Taskset $ts = shift;
    my $shandle = shift;

    my $task_list = $ts->{waiting}{$shandle} or
        die "Uhhhh:  got work_fail for unknown handle: $shandle\n";

    my Gearman::Task $task = shift @$task_list or
        die "Uhhhh:  task_list is empty on work_fail for handle $shandle\n";

    $task->fail;
    delete $ts->{waiting}{$shandle} unless @$task_list;
}

sub _process_packet {
    my Gearman::Taskset $ts = shift;
    my ($res, $sock) = @_;

    if ($res->{type} eq "job_created") {
        my Gearman::Task $task = shift @{ $ts->{need_handle} } or
            die "Um, got an unexpected job_created notification";

        my $shandle = ${ $res->{'blobref'} };
        my $ipport = _ip_port($sock);

        # did sock become disconnected in the meantime?
        if (! $ipport) {
            $ts->_fail_jshandle($shandle);
            return 1;
        }

        $task->handle("$ipport//$shandle");
        push @{ $ts->{waiting}{$shandle} ||= [] }, $task;
        return 1;
    }

    if ($res->{type} eq "work_fail") {
        my $shandle = ${ $res->{'blobref'} };
        $ts->_fail_jshandle($shandle);
        return 1;
    }

    if ($res->{type} eq "work_complete") {
        ${ $res->{'blobref'} } =~ s/^(.+?)\0//
            or die "Bogus work_complete from server";
        my $shandle = $1;

        my $task_list = $ts->{waiting}{$shandle} or
            die "Uhhhh:  got work_complete for unknown handle: $shandle\n";

        my Gearman::Task $task = shift @$task_list or
            die "Uhhhh:  task_list is empty on work_complete for handle $shandle\n";

        $task->complete($res->{'blobref'});
        delete $ts->{waiting}{$shandle} unless @$task_list;

        return 1;
    }

    if ($res->{type} eq "work_status") {
        my ($shandle, $nu, $de) = split(/\0/, ${ $res->{'blobref'} });

        my $task_list = $ts->{waiting}{$shandle} or
            die "Uhhhh:  got work_status for unknown handle: $shandle\n";

        # FIXME: the server is (probably) sending a work_status packet for each
        # interested client, even if the clients are the same, so probably need
        # to fix the server not to do that.  just put this FIXME here for now,
        # though really it's a server issue.
        foreach my Gearman::Task $task (@$task_list) {
            $task->status($nu, $de);
        }

        return 1;
    }

    die "Unknown/unimplemented packet type: $res->{type}";

}

1;
