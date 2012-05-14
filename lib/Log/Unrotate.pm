package Log::Unrotate;

use strict;
use warnings;

# ABSTRACT: Reader of rotated logs.

=head1 NAME

Log::Unrotate - Reader of rotated logs.

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
use Digest::MD5 qw(md5_hex);

use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
use Log::Unrotate::Cursor::File;
use Log::Unrotate::Cursor::Null;

sub _defaults ($) {
    my ($class) = @_;
    return {
        start => 'begin',
        lock => 'none',
        end => 'fixed',
        check_inode => 0,
        check_lastline => 1,
        check_log => 0,
        autofix_cursor => 0,
        rollback_period => 300,
    };
}

our %_start_values = map { $_ => 1 } qw(begin end first);
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

=item I<cursor>

Instead of C<pos> file, you can specify any custom cursor. See C<Log::Unrotate::Cursor> for cursor API details.

=item I<autofix_cursor>

Recreate cursor if it's broken.

Warning will be printed. This option is dangerous and shouldn't be enabled light-heartedly.

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

This flag is disabled by default.

It enables inode checks when detecting log rotations. This option should not be enabled when retrieving logs via rsync or some other way which modifies inodes.

=item I<check_lastline>

This flag is set by default. It enables content checks when detecting log rotations. There is actually no reason to disable this option.

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
    croak "either check_inode or check_lastline should be on" unless $self->{check_inode} or $self->{check_lastline};

    bless $self => $class;

    if ($self->{pos} and $self->{cursor}) {
        croak "only one of 'pos' and 'cursor' should be specified";
    }
    unless ($self->{pos} or $self->{cursor}) {
        croak "one of 'pos' and 'cursor' should be specified";
    }

    my $posfile = delete $self->{pos};
    if ($posfile) {
        if ($posfile eq '-') {
            croak "Log not specified and posfile is '-'" if not defined $self->{log};
            $self->{cursor} = Log::Unrotate::Cursor::Null->new();
        }
        else {
            croak "Log not specified and posfile is not found" if not defined $self->{log} and not -e $posfile;
            $self->{cursor} = Log::Unrotate::Cursor::File->new($posfile, { lock => $self->{lock}, rollback_period => $self->{rollback_period} });
        }
    }

    my $pos = $self->{cursor}->read();
    if ($pos) {
        my $logfile = delete $pos->{LogFile};
        if ($self->{log}) {
            die "logfile mismatch: $logfile ne $self->{log}" if $self->{check_log} and $logfile and $self->{log} ne $logfile;
        } else {
            $self->{log} = $logfile or die "'logfile:' not found in cursor $self->{cursor} and log not specified";
        }
    }

    $self->_set_last_log_number();
    $self->_set_eof();

    if ($pos) {
        my $found = eval {
            $self->_find_log($pos);
            1;
        };
        unless ($found) {
            if ($self->{autofix_cursor}) {
                warn $@;
                warn "autofix_cursor is enabled, cleaning $self->{cursor}";
                $self->{cursor}->clean();
                $self->_start();
            }
            else {
                die $@;
            }
        }
    } else {
        $self->_start();
    }

    return $self;
}

sub _seek_end_pos ($$) {
    my $self = shift;
    my ($handle) = @_;

    seek $handle, -1, SEEK_END;
    read $handle, my $last_byte, 1;
    if ($last_byte eq "\n") {
        return tell $handle;
    }

    my $position = tell $handle;
    while (1) {
        # we have reached beginning of the file and haven't found "\n"
        return 0 if $position == 0;

        my $read_portion = 1024;
        $read_portion = $position if ($position < $read_portion);
        seek $handle, -$read_portion, SEEK_CUR;
        my $data;
        read $handle, $data, $read_portion;
        if ($data =~ /\n(.*)\z/) { # match *last* \n
            my $len = length $1;
            seek $handle, $position, SEEK_SET;
            return $position - $len;
        }
        seek $handle, -$read_portion, SEEK_CUR;
        $position -= $read_portion;
    }
}

sub _find_end_pos ($$) {
    my $self = shift;
    my ($handle) = @_;

    my $tell = tell $handle;
    my $end = $self->_seek_end_pos($handle);
    seek $handle, $tell, SEEK_SET;
    return $end;
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
        $position = $self->_seek_end_pos($handle);
    }

    my $backstep = 256; # 255 + "\n"
    $backstep = $position if $backstep > $position;
    seek $handle, -$backstep, SEEK_CUR;
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
    $self->{LogNumber} = 0;
    if ($self->{start} eq 'end') { # move to the end of file
        $self->_reopen(0);
        $self->_seek_end_pos($self->{Handle}) if $self->{Handle};
    } elsif ($self->{start} eq 'begin') { # move to the beginning of last file
        $self->_reopen(0);
    } elsif ($self->{start} eq 'first') { # find oldest file
        $self->{LogNumber} = $self->{LastLogNumber};
        $self->_reopen(0);
    } else {
        die; # impossible
    }
}

sub _reopen ($$)
{
    my ($self, $position) = @_;

    my $log = $self->_log_file();

    if (open my $FILE, "<$log") {
        my @stat = stat $FILE;
        return 0 if $stat[7] < $position;
        return 0 if $stat[7] == 0 and $self->{LogNumber} == 0 and $self->{end} eq 'fixed';
        seek $FILE, $position, SEEK_SET;
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
    my $cursor = $self->{cursor};
    return "Cursor: $cursor, LogFile: $logfile, Inode: $inode, Position: $position, LastLine: $lastline";
}

# look through .log .log.1 .log.2, etc., until we'll find log with correct inode and/or checksum.
sub _find_log ($$)
{
    my ($self, $pos) = @_;

    undef $self->{LastLine};
    $self->_set_last_log_number();

    for ($self->{LogNumber} = 0; $self->{LogNumber} <= $self->{LastLogNumber}; $self->{LogNumber}++) {
        next unless $self->_reopen($pos->{Position});
        next if ($self->{check_inode} and $pos->{Inode} and $self->{Inode} and $pos->{Inode} ne $self->{Inode});
        next if ($self->{check_lastline} and $pos->{LastLine} and $pos->{LastLine} ne $self->_last_line());
        while () {
            # check if we're at the end of file
            return 1 if $self->_find_end_pos($self->{Handle}) > tell $self->{Handle};

            while () {
                return 0 if $self->{LogNumber} <= 0;
                $self->{LogNumber}--;
                last if $self->_reopen(0);
            }
        }
    }

    die "unable to find the log: ", $self->_print_position($pos);
}

################################################# Public methods ######################################################

=item B<< read() >>

Read a string from the file I<log>.

=cut
sub read($)
{
    my ($self) = @_;

    my $getline = sub {
        my $fh = shift;
        my $line = <$fh>;
        return unless defined $line;
        unless ($line =~ /\n$/) {
            seek $fh, - length $line, SEEK_CUR;
            return undef;
        }
        return $line;
    };

    my $line;
    while (1) {
        my $FILE = $self->{Handle};
        return undef unless defined $FILE;
        if (defined $self->{EOF} and $self->{LogNumber} == 0) {
            my $position = tell $FILE;
            return undef if $position >= $self->{EOF};
        }
        $line = $getline->($FILE);
        last if defined $line;
        return undef unless $self->_find_log($self->position());
    }

    $self->{LastLine} = $line;
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
        $pos->{LogFile} = $self->{log}; # always .log, not .log.N
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
    $pos ||= $self->position();
    return unless defined $pos->{Position}; # pos is missing and log either => do nothing

    $self->{cursor}->commit($pos);
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
        last if $number <= 0;
        $number--;
    }

    $lag -= tell $self->{Handle};
    return $lag;
}

=item B<< log_number() >>

Get current log number.

=cut
sub log_number {
    my ($self) = @_;
    return $self->{LogNumber};
}

=item B<< log_name() >>

Get current log name. Doesn't contain C<< .N >> postfix even if cursor points to old log file.

=cut
sub log_name {
    my ($self) = @_;
    return $self->{log};
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

Copyright (c) 2006-2010 Yandex LTD. All rights reserved.

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See <http://www.perl.com/perl/misc/Artistic.html>

=cut

1;
