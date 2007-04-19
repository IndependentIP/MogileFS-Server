package MogileFS::Worker::Fsck;

use strict;
use base 'MogileFS::Worker';
use fields (
            'last_stop_check',  # unixtime 'should_stop_running' last called
            );
use MogileFS::Util qw(every error debug);
use List::Util ();
use Time::HiRes ();

use constant SUCCESS => 0;
use constant TEMPORARY => 1;
use constant PERMANENT => 2;
use constant REPLICATE => 3;

use constant EV_NO_PATHS         => "NOPA";
use constant EV_POLICY_VIOLATION => "POVI";
use constant EV_FILE_MISSING     => "MISS";
use constant EV_BAD_LENGTH       => "BLEN";
use constant EV_CANT_FIX         => "PERM";
use constant EV_FOUND_FID        => "FIND";

sub watchdog_timeout { 30 }

sub work {
    my $self = shift;

    my $run_count = 0;

    # <debug crap>
    my $running = 0; # start time
    my $n_check = 0; # items checked
    my $start = sub {
        return if $running;
        $running = time();
        print "START @" . time() . "\n";
    };
    my $stats = sub {
        return unless $running;
        my $now = time();
        my $elap = $now - $running;
        printf("In %d secs, %d fids, %0.02f fids/sec\n", $elap, $n_check, ($n_check / ($elap || 1)));
    };
    my $last_beat = 0;
    my $beat = sub {
        my $now = time();
        return unless $now >= $last_beat + 5;
        $stats->();
        $last_beat = $now;
    };
    my $stop = sub {
        return unless $running;
        $stats->();
        print "DONE.\n";
        $running = 0;
    };
    # </debug crap>

    every(5.0, sub {
        my $sleep_set = shift;
        $self->parent_ping;

        # see if we're even enabled for this host.
        return unless $self->should_be_running;

        # checking doesn't go well if the monitor job hasn't actively started
        # marking things as being available
        unless ($self->monitor_has_run) {
            # only warn on runs after the first.  gives the monitor job some time to work
            # before we throw a message.
            error("waiting for monitor job to complete a cycle before beginning checking")
                if $run_count++ > 0;
            return;
        }

        my $sto        = Mgd::get_store();
        my $max_check  = MogileFS::Config->server_setting('fsck_highest_fid_checked') || 0;
        my $opt_nostat = MogileFS::Config->server_setting('fsck_opt_skip_stat')       || 0;
        my @fids       = $sto->get_fids_above_id($max_check, 100);

        unless (@fids) {
            $stop->();
            return;
        }
        $start->();

        MogileFS::FID->mass_load_devids(@fids);

        my $new_max;
        my $hit_problem = 0;
        foreach my $fid (@fids) {
            $self->still_alive;
            last if $self->should_stop_running;
            if (!$self->check_fid($fid, no_stat => $opt_nostat)) {
                # some connectivity problem... abort checking more
                # for now.
                $hit_problem = 1;
                last;
            }
            $new_max = $fid->id;
            $n_check++;
            $beat->();
        }

        if ($new_max) {
            MogileFS::Config->set_server_setting('fsck_highest_fid_checked', $new_max);
            # don't sleep in every() loop next time:
            $sleep_set->(0);
        }

        # if we had connectivity problems, let's sleep a bit
        if ($hit_problem) {
            warn "Reachability problems.  Sleeping.\n";
            sleep 5;
        }
    });
}

# this version is accurate,
sub should_be_running {
    my $self = shift;
    my $fhost = MogileFS::Config->server_setting('fsck_host')
        or return;
    return $fhost eq MogileFS::Config->hostname;
}

# this version is sloppy, optimized for speed.  only checks db every 5 seconds.
sub should_stop_running {
    my $self = shift;
    my $now  = time();
    return 0 if $now < ($self->{last_stop_check} || 0) + 5;
    $self->{last_stop_check} = $now;
    return ! $self->should_be_running;
}

# given a $fid (MogileFS::FID, with pre-populated ->devids data)
# return 0 if reachability problems.
# return 1 if fid was checked (regardless of there being problems or not)
#   if no problems, no action.
#   if problems, log & enqueue fixes
use constant STALLED => 0;
use constant HANDLED => 1;
sub check_fid {
    my ($self, $fid, %opts) = @_;
    my $opt_no_stat = delete $opts{no_stat};
    die "badopts" if %opts;

    my $fix = sub {
        my $fixed = eval { $self->fix_fid($fid) };
        if (! defined $fixed) {
            error("Fsck stalled: $@");
            return STALLED;
        }
        $fid->fsck_log(EV_CANT_FIX) if ! $fixed;
        return HANDLED;
    };

    # first obvious fucked-up case:  no devids even presumed to exist.
    unless ($fid->devids) {
        # first, log this weird condition.
        $fid->fsck_log(EV_NO_PATHS);

        # weird, schedule a fix (which will do a search over all
        # devices as a last-ditch effort to locate it)
        return $fix->();
    }

    # first, see if the assumed devids meet the replication policy for
    # the fid's class.
    unless ($fid->devids_meet_policy) {
        # log a policy violation
        $fid->fsck_log(EV_POLICY_VIOLATION);
        return $fix->();
    }

    # in the fast case, do nothing else (don't check if assumed file
    # locations are actually there).  in the fast case, all we do is
    # check the replication policy, which is already done, so finish.
    return HANDLED if $opt_no_stat;

    # iterate and do HEAD requests to determine some basic information about the file
    my %devs;
    foreach my $devid ($fid->devids) {
        # setup and do the request.  these failures are total failures in that we expect
        # them to work again later, as it's probably transient and will persist no matter
        # how many paths we try.
        my $dfid = MogileFS::DevFID->new($devid, $fid);
        my $dev  = $dfid->device;

        my $disk_size = $dfid->size_on_disk;

        if (! defined $disk_size) {
            warn("Connectivity problem reaching device " . $dev->id . " on host " . $dev->host->ip . "\n");
            return STALLED;
        }

        # great, check the size against what's in the database
        if ($disk_size == $fid->length) {
            # yay!
            next;
        }

        # Note: not doing fsck_log, as fix_fid will log status for each device.

        # no point continuing loop now, once we find one problem.
        # fix_fid will fully check all devices...
        return $fix->();
    }

    return HANDLED;
}

# this is the slow path.  if something above in check_fid finds
# something amiss in any way, we went the slow path on a fid and try
# really hard to fix the situation.
#
# return true if situation handled, 0 if nothing could be done.
# die on errors (like connectivity problems).
use constant CANT_FIX => 0;
sub fix_fid {
    my ($self, $fid) = @_;

    printf("Fixing FID %d (len=%d; cldid=%d; on: %s)\n",
           $fid->id,
           $fid->length,
           $fid->classid,
           join(",", $fid->devids),
           );

    # make devfid objects from the devids that this fid is on,
    my @dfids = map { MogileFS::DevFID->new($_, $fid) } $fid->devids;

    # track all known good copies (dev objects), as well as all bad
    # copies (places it should've been, but isn't)
    my @good_devs;
    my @bad_devs;
    my %already_checked;  # devid -> 1.

    my $check_dfids = sub {
        my $is_desperate_mode = shift;

        # stat all devices.
        foreach my $dfid (@dfids) {
            my $dev = $dfid->device;
            next if $already_checked{$dev->id}++;

            my $disk_size = $dfid->size_on_disk;
            die "dev unreachable" unless defined $disk_size;

            if ($disk_size == $fid->length) {
                push @good_devs, $dfid->device;
                # if we were doing a desperate search, one is enough, we can stop now!
                return if $is_desperate_mode;
                next;
            }

            # don't log in desperate mode, as we'd have "file missing!" log entries
            # for every device in the normal case, which is expected.
            unless ($is_desperate_mode) {
                if (! $disk_size) {
                    $fid->fsck_log(EV_FILE_MISSING, $dev);
                } else {
                    $fid->fsck_log(EV_BAD_LENGTH, $dev);
                }
            }

            push @bad_devs, $dfid->device;
        }
    };

    $check_dfids->();

    # if we didn't find it anywhere, let's go do an exhaustive search over
    # all devices, looking for it...
    unless (@good_devs) {
        # replace @dfids with list of all (alive) devices.  dups will be ignored by
        # check_dfids
        @dfids =
            map  { MogileFS::DevFID->new($_, $fid)  }
            grep { ! $_->is_marked_dead }
            MogileFS::Device->devices;
        $check_dfids->("desperate");

        # still can't fix it?
        return CANT_FIX unless @good_devs;

        # wow, we actually found it!
        $fid->fsck_log(EV_FOUND_FID);
        $fid->note_on_device($good_devs[0]); # at least one good one.

        # fall through to check policy (which will most likely be
        # wrong, with only one file_on record...) and re-replicate
    }

    # remove the file_on mappings for devices that were bogus/missing.
    foreach my $bdev (@bad_devs) {
        debug("[fsck] removing file_on mapping for fid=" . $fid->id . ", dev=" . $bdev->id);
        $fid->forget_about_device($bdev);
    }

    # Note: this will reload devids, if they called 'note_on_device'
    # or 'forget_about_device'
    unless ($fid->devids_meet_policy) {
        $fid->enqueue_for_replication;
        return HANDLED;
    }

    return HANDLED;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
