package Log::Unrotate;

use strict;
use warnings;

=head1 NAME

Log::Unrotate - Reader of rotated logs.

=head1 VERSION

Version 1.04

=cut

our $VERSION = '1.04';

=head1 SYNOPSIS

  use Log::Unrotate;

  my $reader = Log::Unrotate->new({
      log => 'xxx.log',
      pos => 'xxx.pos',
  });

  $reader->read();
  $reader->read();
  $reader->read();
  $reader->commit();
  my $position = $reader->position();
  $reader->read();
  $reader->read();
  $reader->commit($position); # rollback the last 2 reads
  my $lag = $reader->lag();

=head1 DESCRIPTION

The C<Log::Unrotate> is a class that implements incremental and transparent reading of a log file which correctly handles logrotates.

It tries really hard to never skip any data from logs. If it's not sure about what to do, it fails, and you should either fix your position file manually, or remove it completely.

=cut

use Carp;

use IO::Handle;
use File::Basename;
use File::Temp;
use Digest::MD5 qw(md5_hex);
use Fcntl qw(:flock);

sub _defaults ($) {
    my ($class) = @_;
    return {
        start => 'begin',
        lock => 'none',
        end => 'fixed',
        check_inode => 0,
        check_lastline => 1,
        check_log => 0,
    };
}

our %_start_values = map { $_ => 1 } qw(begin end first);
our %_lock_values = map { $_ => 1 } qw(none blocking nonblocking);
our %_end_values = map { $_ => 1 } qw(fixed future);

=head1 METHODS

=over

=cut

=item B<< new($params) >>

Creates new unrotate object.

=over

=item I<pos>

Name of file to store log reading position. Will be created automatically if missing.

Value '-' means not use position file. I.e., pretend it doesn't exist at start and ignore commit calls.

=item I<log>

Name of log file. Value '-' means standard input stream.

=item I<start>

Describes behavior when position file doesn't exist. Allowed values: C<begin> (default), C<end>, C<first>.

=over 4

=item *

When I<start> is C<begin>, we'll read current I<log> from beginning.

=item *

When I<start> is C<end>, we'll put current position in C<log> at the end (useful for big files when some new script don't need to read everything).

=item *

When I<start> is C<first>, C<Log::Unrotate> will find oldest log file and read everything.

=back

=item I<end>

Describes behavior when the log is asynchronously appended while read. Allowed values: C<fixed> (default), C<future>.

=over 4

=item *

When I<end> is C<fixed>, the log is read up to the position it had when the reader object was created.

=item *

When I<end> is C<future>, it allows reading the part of the log that was appended after the reader creation (useful for reading from stdin).

=back

=item I<lock>

Describes locking behaviour. Allowed values: C<none> (default), C<blocking>, C<nonblocking>.

=over 4

=item *

When I<lock> is C<blocking>, lock named I<pos>.lock will be acquired in blocking mode.

=item *

When I<lock> is C<nonblocking>, lock named I<pos>.lock will be acquired in nonblocking mode; if lock file is already locked, exception will be thrown.

=back

=item I<check_inode>

This flag is set by default. It enables inode checks when detecting log rotations. This option should be disabled when retrieving logs via rsync or some other way which modifies inodes.

=item I<check_lastline>

This flag is set by default. It enables content checks when detecting log rotations. There is actually no reason to disable this option.

=item I<filter>

You can specify subroutine ref here to filter each line. If subroutine will throw exception, it will be passed through to B<read()> caller. Subroutine can transform line to any scalar, including hashrefs or objects.

=back

=cut
sub new ($$)
{
    my ($class, $args) = @_;
    my $self = {
        %{$class->_defaults()},
        %$args,
    };

    croak "unknown start value: '$self->{start}'" unless $_start_values{$self->{start}};
    croak "unknown end value: '$self->{end}'" unless $_end_values{$self->{end}};
    croak "unknown lock value: '$self->{lock}'" unless $_lock_values{$self->{lock}};
    croak "filter should be subroutine ref" if $self->{filter} and ref($self->{filter}) ne 'CODE';
    croak "either check_inode or check_lastline should be on" unless $self->{check_inode} or $self->{check_lastline};

    bless $self => $class;

    $self->{LogNumber} = 0;
    my $pos;

    if ($self->{pos} eq '-' or not -e $self->{pos}) {
        if (not defined $self->{log}) {
            croak "Position file $self->{pos} not found and log not specified";
        }
    }

    if ($self->{pos} ne '-' and $self->{lock} ne 'none') {
        # locks
        unless (open $self->{lock_fh}, '>>', "$self->{pos}.lock") {
            delete $self->{lock_fh};
            croak "Can't open $self->{pos}.lock: $!";
        }
        if ($self->{lock} eq 'blocking') {
            flock $self->{lock_fh}, LOCK_EX or croak "Failed to obtain lock: $!";
        }
        elsif ($self->{lock} eq 'nonblocking') {
            flock $self->{lock_fh}, LOCK_EX | LOCK_NB or croak "Failed to obtain lock: $!";
        }
    }

    if ($self->{pos} ne '-' and -e $self->{pos}) {
        open my $fh, '<', $self->{pos} or die "Can't open '$self->{pos}': $!";
        my $posfile = do {local $/; <$fh>};
        $posfile =~ /position:\s*(\d+)/ and $pos->{Position} = $1;
        die "missing 'position:' in $self->{pos}" unless defined $pos->{Position};
        $posfile =~ /inode:\s*(\d+)/ and $pos->{Inode} = $1;
        $posfile =~ /lastline:\s(.*)/ and $pos->{LastLine} = $1;
        $posfile =~ /logfile:\s(.*)/ and my $logfile = $1;
        if ($self->{log}) {
            die "logfile mismatch: $logfile ne $self->{log}" if $self->{check_log} and $logfile and $self->{log} ne $logfile;
        } else {
            $self->{log} = $logfile or die "'logfile:' not found in position file $self->{pos} and log not specified";
        }
    }


    $self->{LogNumber} = 0;
    $self->_set_last_log_number();
    $self->_set_eof();

    if ($pos) {
        $self->_find_log($pos);
    } else {
        $self->_start();
    }

    return $self;
}

sub _get_last_line ($) {
    my ($self) = @_;
    my $handle = $self->{Handle};
    my $number = $self->{LogNumber};
    my $position = tell $handle if $handle;

    unless ($position) { # 'if' not 'while'!
        $number++;
        my $log = $self->_log_file($number);
        undef $handle; # need this to keep $self->{Handle} unmodified!
        open $handle, '<', $log or return ""; # missing prev log
        seek $handle, 0, 2;
        $position = tell $handle;
    }

    my $backstep = 256; # 255 + "\n"
    $backstep = $position if $backstep > $position;
    seek $handle, -$backstep, 1;
    my $last_line;
    read $handle, $last_line, $backstep;
    return $last_line;
}

sub _last_line ($) {
    my ($self) = @_;
    my $last_line = $self->{LastLine} || $self->_get_last_line();
    $last_line =~ /(.{0,255})$/ and $last_line = $1;
    return $last_line;
}

# pos not found, reading log for the first time
sub _start($)
{
    my $self = shift;
    if ($self->{start} eq 'end') { # move to the end of file
        $self->_reopen(0, 2);
    } elsif ($self->{start} eq 'begin') { # move to the beginning of last file
        $self->_reopen(0);
    } elsif ($self->{start} eq 'first') { # find oldest file
        $self->{LogNumber} = $self->{LastLogNumber};
        $self->_reopen(0);
    } else {
        die; # impossible
    }
}

sub _reopen ($$;$$)
{
    my ($self, $position, $from) = @_;
    $from ||= 0;

    my $log = $self->_log_file();

    if (open my $FILE, "<$log") {

        my @stat = stat $FILE;
        return 0 if $from == 0 and $stat[7] < $position;
        return 0 if $stat[7] == 0 and $self->{LogNumber} == 0 and $self->{end} eq 'fixed';
        seek $FILE, $position, $from;
        $self->{Handle} = $FILE;
        $self->{Inode} = $stat[1];
        return 1;

    } elsif (-e $log) {
        die "log '$log' exists but is unreadable";
    } else {
        return;
    }
}

sub _set_last_log_number ($)
{
    my ($self) = @_;
    my $log = $self->{log};
    my @numbers = sort { $b <=> $a } map { /\.(\d+)$/ ? $1 : () } glob "$log.*";
    $self->{LastLogNumber} = $numbers[0] || 0;
}

sub _set_eof ($)
{
    my ($self) = @_;
    return unless $self->{end} eq 'fixed';
    my @stat = stat $self->{log};
    my $eof = $stat[7];
    $self->{EOF} = $eof || 0;
}

sub _log_file ($;$)
{
    my ($self, $number) = @_;
    $number = $self->{LogNumber} unless defined $number;
    my $log = $self->{log};
    $log .= ".$number" if $number;
    return $log;
}

sub _print_position ($$)
{
    my ($self, $pos) = @_;
    my $lastline = defined $pos->{LastLine} ? $pos->{LastLine} : "[unknown]";
    my $inode = defined $pos->{Inode} ? $pos->{Inode} : "[unknown]";
    my $position = defined $pos->{Position} ? $pos->{Position} : "[unknown]";
    my $logfile = $self->{log};
    my $posfile = $self->{pos};
    return "PosFile: $posfile, LogFile: $logfile, Inode: $inode, Position: $position, LastLine: $lastline";
}

# look through .log .log.1 .log.2, etc., until we'll find log with correct inode and/or checksum.
sub _find_log ($$)
{
    my ($self, $pos) = @_;

    for ($self->{LogNumber} = 0; $self->{LogNumber} <= $self->{LastLogNumber}; $self->{LogNumber}++) {

        next unless $self->_reopen($pos->{Position});
        next if ($self->{check_inode} and $pos->{Inode} and $self->{Inode} and $pos->{Inode} ne $self->{Inode});
        next if ($self->{check_lastline} and $pos->{LastLine} and $pos->{LastLine} ne $self->_last_line());
        return;
    }

    die "unable to find the log: ", $self->_print_position($pos);
}

sub _next ($)
{
    my ($self) = @_;
    return 0 unless $self->{LogNumber};
    # $self->_find_log($self->position());
    $self->{LogNumber}--; #FIXME: logrotate could invoke between _next calls! #TODO: call _find_log!
    return $self->_reopen(0);
}

################################################# Public methods ######################################################

=item B<< read() >>

Read a string from the file I<log>.

=cut
sub read($)
{
    my ($self) = @_;

    my $line;
    while (1) {
        my $FILE = $self->{Handle};
        return unless defined $FILE;
        if (defined $self->{EOF} and $self->{LogNumber} == 0) {
            my $position = tell $FILE;
            return if $position >= $self->{EOF};
        }
        $line = <$FILE>;
        last if defined $line;
        return unless $self->_next();
    }

    if ($line !~ /\n$/ and $self->lag() == 0) {
        # incomplete line => backstep
        seek $self->{Handle}, - length $line, 1;
        return;
    }

    $self->{LastLine} = $line;
    $line = $self->{filter}->($line) if $self->{filter};
    return $line;
}

=item B<< position() >>

Get your current position in I<log> as an object passible to commit.

=cut
sub position($)
{
    my $self = shift;
    my $pos = {};

    if ($self->{Handle}) {
        $pos->{Position} = tell $self->{Handle};
        $pos->{Inode} = $self->{Inode};
        $pos->{LastLine} = $self->_last_line();  # undefined LastLine forces _last_line to backstep
    }

    return $pos;
}

=item B<< commit(;$) >>

Save current position in the file I<pos>. You can also save some other position, previosly taken with B<position>.

Position file gets commited using temporary file, so it'll not be lost if disk space is depleted.

=cut
sub commit($;$)
{
    my ($self, $pos) = @_;
    return if $self->{pos} eq '-';
    $pos = $self->position() unless $pos;

    return unless defined $pos->{Position}; # pos is missing and log either => do nothing

    my $fh = File::Temp->new(DIR => dirname($self->{pos}));

    $fh->print("logfile: $self->{log}\n");
    $fh->print("position: $pos->{Position}\n");
    if ($pos->{Inode}) {
        $fh->print("inode: $pos->{Inode}\n");
    }
    if ($pos->{LastLine}) {
        $fh->print("lastline: $pos->{LastLine}\n");
    }
    if ($fh->error) {
        die 'print into '.$fh->filename.' failed';
    }

    chmod(0644, $fh->filename) or die "Failed to chmod ".$fh->filename.": $!";
    rename($fh->filename, $self->{pos}) or die "Failed to commit pos $self->{pos}: $!";
    $fh->unlink_on_destroy(0);
}

=item B<< lag() >>

Get the lag between current position and the end of the log in bytes.

=cut
sub lag ($)
{
    my ($self) = @_;
    die "lag failed: missing log file" unless defined $self->{Handle};

    my $lag = 0;

    my $number = $self->{LogNumber};
    while () {
        my @stat = stat $self->_log_file($number);
        $lag += $stat[7] if @stat;
        last unless $number;
        $number--;
    }

    $lag -= tell $self->{Handle};
    return $lag;
}

sub DESTROY {
    my ($self) = @_;
    if ($self->{lock_fh}) {
        flock $self->{lock_fh}, LOCK_UN;
    }
}

=back

=head1 BUGS & CAVEATS

To find and open correct log is a race-condition-prone task.

This module was used in production environment for 3 years, and many bugs were found and fixed. The only known case when position file can become broken is when logrotate is invoked twice in *very* short amount of time, which should never be a case.

Don't set I<check_inode> option on virtual hosts, especially on openvz-based ones. When host migrates, inodes of files will change and your position file will become broken.

The logrotate config should not use the "compress" option to make that module function properly. If you need to compress logs, set "delaycompress" option too.

=head1 AUTHORS

Andrei Mishchenko C<druxa@yandex-team.ru>, Vyacheslav Matjukhin C<mmcleric@yandex-team.ru>.

=head1 SEE ALSO

L<File::LogReader> - another implementation of the same idea.

L<unrotate(1)> - console script to unrotate logs.

=head1 COPYRIGHT

Copyright (c) 2006-2009 Yandex LTD. All rights reserved.

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See <http://www.perl.com/perl/misc/Artistic.html>

=cut

1;
