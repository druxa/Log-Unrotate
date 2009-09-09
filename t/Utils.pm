package t::Utils;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
    devnull_stderr
    devnull_stdout
    restore_stderr
    restore_stdout
);

my $stderr_backup;
my $stdout_backup;

sub devnull_stderr()
{
    open($stderr_backup, ">&STDERR") or die "Can't dup STDERR: $!";
    open(STDERR, '>/dev/null') or die "Can't dup STDERR: $!";
}
sub restore_stderr()
{
    open(STDERR, '>&', $stderr_backup) or die "Can't dup STDERR: $!";
}
sub devnull_stdout()
{
    open($stdout_backup, ">&STDOUT") or die "Can't dup STDOUT: $!";
    open(STDOUT, '>/dev/null') or die "Can't dup STDOUT: $!";
}
sub restore_stdout()
{
    open(STDOUT, '>&', $stdout_backup) or die "Can't dup STDOUT: $!";
}
1;
