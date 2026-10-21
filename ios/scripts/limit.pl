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
# The command is reaped only here, after its group was signalled, so while it runs (or is a
# zombie) its pid, which is the group's id, can't be reused. Once it is reaped, the group's id
# stays reserved for as long as any member is left; the one window is between reaping a command
# whose group is already empty and the check that finds it empty (microseconds, and a new
# process would also have to make itself a group leader with that exact id).
#
# Exits with the command's status (128 + the signal if a signal ended it), 124 (as timeout(1))
# when the limit stopped it, or 130 / 143 when INT / TERM stopped it.
use strict;
use warnings;
use POSIX qw(WNOHANG setpgid _exit);
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

my $status;    # the command's wait status, once reaped
sub reap { $status = $? if !defined $status && waitpid($pid, WNOHANG) == $pid }
sub group_left { kill(0, -$pid) }

# TERM to the group, then KILL after the grace if any of it is left.
sub stop_group {
    return unless kill('TERM', -$pid);
    my $deadline = time + $grace;
    while (time < $deadline) {
        reap();
        return unless group_left();
        sleep 0.2;
    }
    kill('KILL', -$pid);
    for (1 .. 25) {
        reap();
        return unless group_left();
        sleep 0.2;
    }
}

my $start = time;
my $timed_out = 0;
while (1) {
    reap();
    last if defined $status;
    if ($interrupted) { stop_group(); last }
    if (time - $start >= $limit) {
        print STDERR "ios: $command[0] passed its ${limit}s limit: stopping it\n";
        stop_group();
        $timed_out = 1;
        last;
    }
    sleep 0.2;
}
stop_group() if group_left();    # what the command left behind
unless (defined $status) { waitpid($pid, 0); $status = $? }

exit $interrupted if $interrupted;
exit 124 if $timed_out;
exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
