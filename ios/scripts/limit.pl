#!/usr/bin/perl
# Runs a command with a wall-clock limit, as common.sh's run_limited (widget-proof.sh,
# spike-proof.sh). Usage: limit.pl <seconds> <command> [args...]
#
# The command runs in a process group of its own (as watchdog.sh runs xcodebuild). Past the
# limit, or when this script gets INT or TERM, the whole group gets TERM (watchdog.sh passes it
# on to xcodebuild's own group and waits), then KILL after IOS_LIMIT_GRACE_SECS (default 15) if
# anything of it is left. When the command exits by itself, whatever it left running in its
# group is ended the same way, so nothing it started outlives it.
#
# The command is reaped only at the very end, after everything in its group has stopped, so its
# pid, which is the group's id, can't be reused while anything here signals it: its exit is seen
# as a zombie (ps), never by reaping.
#
# Exits with the command's status (128 + the signal if a signal ended it), 124 (as timeout(1))
# when the limit stopped it, or 130 / 143 when INT / TERM stopped it.
use strict;
use warnings;
use POSIX qw(setpgid _exit);
use Time::HiRes qw(time sleep);

my ($limit, @command) = @ARGV;
die "usage: limit.pl <seconds> <command> [args...]\n" unless defined $limit && $limit =~ /^\d+$/ && @command;
my $grace = $ENV{IOS_LIMIT_GRACE_SECS} // 15;

my $interrupted = 0;
$SIG{INT} = sub { $interrupted = 130 };
$SIG{TERM} = sub { $interrupted = 143 };

my $pid = fork() // die "limit: fork: $!\n";
if ($pid == 0) {
    $SIG{INT} = $SIG{TERM} = 'DEFAULT';
    setpgid(0, 0);
    exec { $command[0] } @command or do { print STDERR "limit: cannot run $command[0]: $!\n"; _exit(127) };
}
setpgid($pid, $pid);    # also from this side: the group exists before anything is signalled

# The group's members still running (the command too while it runs; not zombies).
sub members {
    my @live = grep { my ($group, $stat) = split; $group == $pid && $stat !~ /^Z/ } `ps -axo pgid=,stat=`;
    return scalar @live;
}
sub leader_running {
    my $stat = `ps -o stat= -p $pid`;
    return $stat =~ /\S/ && $stat !~ /^\s*Z/;
}

# TERM to the group, then KILL after the grace if any of it is left.
sub stop_group {
    kill('TERM', -$pid);
    my $deadline = time + $grace;
    while (time < $deadline) {
        return unless members();
        sleep 0.2;
    }
    kill('KILL', -$pid);
    for (1 .. 25) {
        return unless members();
        sleep 0.2;
    }
}

my $start = time;
my $timed_out = 0;
while (1) {
    last unless leader_running();
    if ($interrupted) { stop_group(); last }
    if (time - $start >= $limit) {
        print STDERR "ios: $command[0] passed its ${limit}s limit: stopping it\n";
        stop_group();
        $timed_out = 1;
        last;
    }
    sleep 0.25;
}
stop_group() if members();    # what the command left behind
waitpid($pid, 0);
my $status = $?;

exit $interrupted if $interrupted;
exit 124 if $timed_out;
exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
