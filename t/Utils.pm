package t::Utils;

use strict;
use warnings;

use Carp;

require Exporter;
our @ISA = qw(Exporter);

our @EXPORT = qw(
    devnull_stderr
    devnull_stdout
    restore_stderr
    restore_stdout
    xsystem
    xqx
    xprint
    xopen
    xclose
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

# exception version of builtin 'system' call
sub xsystem (@) {
    return if system(@_) == 0;
    if ($? == -1) {
        croak "failed to execute '@_': $!";
    } elsif ($? & 127) {
        croak "'@_' died with signal %d, %s coredump", ($? & 127),  ($? & 128) ? 'with' : 'without';
    } else {
        croak sprintf "'@_' exited with value %d\n", $? >> 8;
    }
}

sub xopen ($;$) {
    my ($mode, $file) = @_;
    my $fh;
    unless (defined $file) {
        open $fh, $mode or croak "open '$mode ' failed: $!";
    } else {
        open $fh, $mode, $file or croak "open '$mode$file' failed: $!";
    }
    return $fh;
}

sub xclose ($) {
    my ($fh) = @_;
    close $fh or croak "close failed: $!";
    return;
}

sub xprint ($@) {
    my $fh = shift;
    print $fh @_ or croak "print failed: $!";
    return;
}

sub xqx (@) {
    # exception version of builtin 'qx{}' call
    my $res = qx{@_};
    croak "xqx '@_' failed: $?" if $? != 0;
    return $res;
}

1;
