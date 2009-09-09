package Log::Unrotate;

use strict;
use warnings;

our $VERSION = '1.00';

=head1 NAME

Log::Unrotate - Reader of rotated logs.

=head1 SYNOPSIS

  use Log::Unrotate;
  my $reader = Log::Unrotate->new({
      LogFile => 'xxx.log',
      PosFile => 'xxx.pos',
  });
  $reader->readline();
  $reader->readline();
  $reader->readline();
  $reader->commit();
  my $position = $reader->position();
  $reader->readline();
  $reader->readline();
  $reader->commit($position); #rollback the last 2 readline
  my $lag = $reader->lag();

=head1 DESCRIPTION

The C<Log::Unrotate> is a class that allows incremental reading of a log file correctly handling logrotates.

The logrotate config should not use the "compress" option to make that function properly.

=head1 METHODS

=over

=cut

use File::Basename;
use File::Temp;
use Digest::MD5 qw(md5_hex);

sub _defaults ($) {
    my ($class) = @_;
    return {
        StartPos => 'begin',
        EndPos => 'fixed',
        CheckInode => 0,
        CheckLastLine => 1,
        CheckLogFile => 0,
    };
}

our %_is_start_pos = map { $_ => 1 } qw(begin end first);
our %_is_end_pos = map { $_ => 1 } qw(fixed future);

=item C<< new >>

Creates new unrotate object.

=over

=item B<PosFile>

Name of file to store log reading position. Will be created automatically if missing.

Value '-' means not use C<PosFile>. That is pretend it doesn't exist at start and ignore commit calls.

=item B<LogFile>

Name of log file. Value '-' means standard input stream.

=item B<StartPos>

Describes behavior when C<PosFile> doesn't exist. Allowed values: C<begin> (default), C<end>, C<first>.

=over 3

=item *

When B<StartPos> is C<begin>, we'll read current B<LogFile> from beginning.

=item *

When B<StartPos> is C<end>, we'll put current position in B<LogFile> at the end. (useful for big files when some new script don't need to read everything).

=item *

When B<StartPos> is C<first>, C<Unrotate> will find oldest log file and read everything.

=back

=item B<EndPos>

Describes behavior when the log is asynchronously appended while read. Allowed values: C<fixed> (default), C<future>.

=over 3

=item *

When B<EndPos> is C<fixed>, the log is read up to the position it had when the reader object was created.

=item *

When B<EndPos> is C<future>, it allows reading the part of the log that was appended after the reader creation. (useful for reading from stdin).

=back

=item B<CheckInode>

  This flag is set by default. It enables inode checks when detecting log rotations.
  This option should be disabled when retrieving logs via rsync or some other way which modifies inodes.

=item B<CheckChecksum>

  This flag is deprecated, use CheckLastline insead.
  It enables md5 checksum checks when detecting log rotations.

=item B<CheckLastline>

  This flag is set by default. It enables content checks when detecting log rotations.
  There is actually no reason to disable this option.

=item B<Filter>

  You can specify subroutine ref here to filter each line.
  If subroutine will throw exception, it will be passed through to readline() caller.
  Subroutine can transform line to any scalar, including hashrefs or objects.

=back

=cut
sub new ($$)
{
    my ($class, $args) = @_;
    my $self = {
        %{$class->_defaults()},
        %$args,
    };

    die "unknown StartPos value: $self->{StartPos}" unless $_is_start_pos{$self->{StartPos}};
    die "unknown EndPos value: $self->{EndPos}" unless $_is_end_pos{$self->{EndPos}};
    die "Filter should be subroutine ref" if $self->{Filter} and ref($self->{Filter}) ne 'CODE';
    die "either CheckInode or CheckLastLine should be on" unless $self->{CheckInode} or $self->{CheckLastLine};

    bless($self, $class);

    $self->{LogNumber} = 0;
    my $pos;

    if ($self->{PosFile} ne '-' and open my $POSFILE, $self->{PosFile}) {

        my $posfile = do {local $/; <$POSFILE>};
        $posfile =~ /position:\s*(\d+)/ and $pos->{Position} = $1;
        die "missing 'position:' in $self->{PosFile}" unless defined $pos->{Position};
        $posfile =~ /inode:\s*(\d+)/ and $pos->{Inode} = $1;
        $posfile =~ /lastline:\s(.*)/ and $pos->{LastLine} = $1;
        $posfile =~ /logfile:\s(.*)/ and my $logfile = $1;
        if ($self->{LogFile}) {
            die "logfile mismatch: $logfile ne $self->{LogFile}" if $self->{CheckLogFile} and $logfile and $self->{LogFile} ne $logfile;
        } else {
            $self->{LogFile} = $logfile or die "'logfile:' not found in PosFile $self->{PosFile} and LogFile not specified";
        }

    } else {
        die "PosFile $self->{PosFile} not found and LogFile not specified" unless $self->{LogFile};
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
        open $handle, $log or return ""; # missing prev log
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

# PosFile не найден, читаем лог в первый раз
sub _start($)
{
    my $self = shift;
    if ($self->{StartPos} eq 'end') { # встать в конец файла
        $self->_reopen(0, 2);
    } elsif ($self->{StartPos} eq 'begin') { # начало файла
        $self->_reopen(0);
    } elsif ($self->{StartPos} eq 'first') { # найти самый старый файл
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

    if (open my $FILE, $log) {

        my @stat = stat $FILE;
        return 0 if $from == 0 and $stat[7] < $position;
        return 0 if $stat[7] == 0 and $self->{LogNumber} == 0 and $self->{EndPos} eq 'fixed';
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
    my $log = $self->{LogFile};
    my @numbers = sort { $b <=> $a } map { /\.(\d+)$/ ? $1 : () } glob "$log.*";
    $self->{LastLogNumber} = $numbers[0] || 0;
}

sub _set_eof ($)
{
    my ($self) = @_;
    return unless $self->{EndPos} eq 'fixed';
    my @stat = stat $self->{LogFile};
    my $eof = $stat[7];
    $self->{EOF} = $eof || 0;
}

sub _log_file ($;$)
{
    my ($self, $number) = @_;
    $number = $self->{LogNumber} unless defined $number;
    my $log = $self->{LogFile};
    $log .= ".$number" if $number;
    return $log;
}

sub _print_position ($$)
{
    my ($self, $pos) = @_;
    my $lastline = defined $pos->{LastLine} ? $pos->{LastLine} : "[unknown]";
    my $inode = defined $pos->{Inode} ? $pos->{Inode} : "[unknown]";
    my $position = defined $pos->{Position} ? $pos->{Position} : "[unknown]";
    my $logfile = $self->{LogFile};
    my $posfile = $self->{PosFile};
    return "PosFile: $posfile, LogFile: $logfile, Inode: $inode, Position: $position, LastLine: $lastline";
}

# Перебираем .log .log.1 .log.2 и т.д. пока не найдем лог с правильными inode и/или checksum.
sub _find_log ($$)
{
    my ($self, $pos) = @_;

    for ($self->{LogNumber} = 0; $self->{LogNumber} <= $self->{LastLogNumber}; $self->{LogNumber}++) {

        next unless $self->_reopen($pos->{Position});
        next if ($self->{CheckInode} and $pos->{Inode} and $self->{Inode} and $pos->{Inode} ne $self->{Inode});
        next if ($self->{CheckLastLine} and $pos->{LastLine} and $pos->{LastLine} ne $self->_last_line());
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

=item C<< $self->readline() >>

Read a string from the file B<LogFile>.

=cut
sub readline($)
{
    #TODO: use some $self->{Parser} to process a line
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
    $line = $self->{Filter}->($line) if $self->{Filter};
    return $line;
}

=item C<< $self->position() >>

Get your current position in B<LogFile> as an object passible to commit.

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

Save current position in the file B<PosFile>. You can also save some other position, previosly taken with C<position>.

=cut
sub commit($;$)
{
    my ($self, $pos) = @_;
    return if $self->{PosFile} eq '-';
    $pos = $self->position() unless $pos;

    return unless defined $pos->{Position}; # PosFile is missing and LogFile either => do nothing

    my $fh = File::Temp->new(DIR => dirname($self->{PosFile}));

    print {$fh} ("logfile: $self->{LogFile}\n") or die "print failed:  $!";
    print {$fh} ("position: $pos->{Position}\n") or die "print failed: $!";
    print {$fh} ("inode: $pos->{Inode}\n") or die "print failed: $!" if $pos->{Inode};
    print {$fh} ("lastline: $pos->{LastLine}\n") or die "print failed: $!" if $pos->{LastLine};

    rename($fh->filename, $self->{PosFile}) or die "Failed to commit PosFile $self->{PosFile}: $!";
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

=item C<< $self->showlag() >>

Deprecated alias of lag method.

=cut
sub showlag ($)
{
    goto &lag;
}

=back

=cut

1;
