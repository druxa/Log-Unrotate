package Log::Unrotate;

use strict;
use warnings;

=head1 NAME

Log::Unrotate - Reader of rotated logs.

=head1 VERSION

Version 1.00

=cut

our $VERSION = '1.00';

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

The C<Log::Unrotate> is a class that allows incremental reading of a log file correctly handling logrotates.

The logrotate config should not use the "compress" option to make that function properly.

=cut

use Carp;

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

=item C<< new >>

Creates new unrotate object.

=over

=item B<pos>

Name of file to store log reading position. Will be created automatically if missing.

Value '-' means not use position file. I.e., pretend it doesn't exist at start and ignore commit calls.

=item B<log>

Name of log file. Value '-' means standard input stream.

=item B<start>

Describes behavior when position file doesn't exist. Allowed values: C<begin> (default), C<end>, C<first>.

=over 3

=item *

When B<start> is C<begin>, we'll read current B<log> from beginning.

=item *

When B<start> is C<end>, we'll put current position in B<log> at the end. (useful for big files when some new script don't need to read everything).

=item *

When B<start> is C<first>, C<Unrotate> will find oldest log file and read everything.

=back

=item B<end>

Describes behavior when the log is asynchronously appended while read. Allowed values: C<fixed> (default), C<future>.

=over 3

=item *

When B<end> is C<fixed>, the log is read up to the position it had when the reader object was created.

=item *

When B<end> is C<future>, it allows reading the part of the log that was appended after the reader creation. (useful for reading from stdin).

=back

=item B<check_inode>

This flag is set by default. It enables inode checks when detecting log rotations. This option should be disabled when retrieving logs via rsync or some other way which modifies inodes.

=item B<check_lastline>

This flag is set by default. It enables content checks when detecting log rotations. There is actually no reason to disable this option.

=item B<filter>

You can specify subroutine ref here to filter each line. If subroutine will throw exception, it will be passed through to read() caller. Subroutine can transform line to any scalar, including hashrefs or objects.

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
        open $self->{lock_fh}, '>>', "$self->{pos}.lock" or die "Can't open $self->{pos}.lock: $!";
        if ($self->{lock} eq 'blocking') {
            flock $self->{lock_fh}, LOCK_EX or die "Failed to obtain lock: $!";
        }
        elsif ($self->{lock} eq 'nonblocking') {
            flock $self->{lock_fh}, LOCK_EX | LOCK_NB or die "Failed to obtain lock: $!";
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

    if (open my $FILE, '<', $log) {

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

=item C<< $self->read() >>

Read a string from the file B<log>.

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

    $self->{LastLine} = $line if defined $line;
    $line = $self->{filter}->($line) if $self->{filter};
    return $line;
}

=item C<< $self->position() >>

Get your current position in B<log> as an object passible to commit.

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

=item C<< $self->commit(;$) >>

Save current position in the file B<pos>. You can also save some other position, previosly taken with C<position>.

Position file gets commited using temporary file, so it'll not be lost if disk space is depleted.

=cut
sub commit($;$)
{
    my ($self, $pos) = @_;
    return if $self->{pos} eq '-';
    $pos = $self->position() unless $pos;

    return unless defined $pos->{Position}; # pos is missing and log either => do nothing

    my $fh = File::Temp->new(DIR => dirname($self->{pos}));

    print {$fh} ("logfile: $self->{log}\n") or die "print failed:  $!";
    print {$fh} ("position: $pos->{Position}\n") or die "print failed: $!";
    print {$fh} ("inode: $pos->{Inode}\n") or die "print failed: $!" if $pos->{Inode};
    print {$fh} ("lastline: $pos->{LastLine}\n") or die "print failed: $!" if $pos->{LastLine};

    rename($fh->filename, $self->{pos}) or die "Failed to commit pos $self->{pos}: $!";
    $fh->unlink_on_destroy(0);
}

=item C<< $self->lag() >>

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

=head1 SEE ALSO

L<File::LogReader> - another implementation of the same idea.

=cut

1;
