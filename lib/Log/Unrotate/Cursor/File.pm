package Log::Unrotate::Cursor::File;

use strict;
use warnings;

use base qw(Log::Unrotate::Cursor);

use overload '""' => sub { shift()->{file} };

=head1 NAME

Log::Unrotate::Cursor::File - file keeping unrotate position

=head1 SYNOPSIS

    use Log::Unrotate::Cursor::File;
    $cursor = Log::Unrotate::Cursor::File->new($file, { lock => "blocking" });

=head1 METHODS

=cut

use Fcntl qw(:flock);
use Carp;
use File::Temp 0.15;
use File::Basename;
use File::Copy;

our %_lock_values = map { $_ => 1 } qw(none blocking nonblocking);
our %_text2field = (
    position => 'Position',
    logfile => 'LogFile',
    inode => 'Inode',
    lastline => 'LastLine',
    committime => 'CommitTime',
);

=over

=item B<new($file, $options)>

=item B<new($file)>

Construct cursor from file.

C<$options> is an optional hashref.
I<lock> option describes locking behaviour. See C<Log::Unrotate> for details.
I<rollback_period> option defines target rollback time in seconds.If 0,
rollback behaviour will be off.


=cut
sub new {
    my ($class, $file, $options) = @_;
    croak "No file specified" unless defined $file;

    my $lock = 'none';
    my $rollback = undef;
    if ($options) {
        $lock = $options->{lock};
        $rollback = $options->{rollback_period};
    }
    croak "unknown lock value: '$lock'" unless $_lock_values{$lock};
    croak "wrong rollback_period: '$rollback'" if ($rollback and $rollback !~ /^\d+$/);

    my $self = bless {
        file => $file,
        rollback => $rollback,
    } => $class;

    unless ($lock eq 'none') {
        # locks
        unless (open $self->{lock_fh}, '>>', "$self->{file}.lock") {
            delete $self->{lock_fh};
            croak "Can't open $self->{file}.lock: $!";
        }
        if ($lock eq 'blocking') {
            flock $self->{lock_fh}, LOCK_EX or croak "Failed to obtain lock: $!";
        }
        elsif ($lock eq 'nonblocking') {
            flock $self->{lock_fh}, LOCK_EX | LOCK_NB or croak "Failed to obtain lock: $!";
        }
    }
    return $self;
}

sub _read_file_fully {
    my ($self) = @_;

    my $file = $self->{file};
    return unless -e $file;

    open my $fh, '<', $file or die "Can't open '$file': $!";
    my $content = do {local $/; <$fh>};

    my @poss = ();
    my $pos = {};
    for my $line (split /\n/, $content) {
        if ($line =~ /^\s*(inode|committime|position):\s*(\d+)/) {
            my $field = $_text2field{$1};
            if (defined $pos->{$field}) {
                die "Some pos-file inconsistency: '$field' defined twice";
            }
            $pos->{$field} = $2;
        } elsif ($line =~ /^\s*(logfile|lastline):\s(.*)/) {
            my $field = $_text2field{$1};
            if (defined $pos->{$field}) {
                die "Some pos-file inconsistency: '$field' defined twice";
            }
            $pos->{$field} = $2;
        } elsif ($line =~ /^###$/) {
            die "missing 'position:' in $file" unless defined $pos->{Position};
            push @poss, $pos;
            $pos = {};
        }
    }
    if ($pos && scalar keys %$pos) {
        die "missing 'position:' in $file" unless defined $pos->{Position};
        push @poss, $pos;
    }
    die "missing 'position:' in $file" unless scalar @poss;

    return \@poss;
}

sub read {
    my $self = shift;

    my $res = $self->_read_file_fully();

    return undef unless defined $res;
    return $res->[0];
}

sub _write_file_fully {
    my ($self, $poss) = @_;

    my $fh = File::Temp->new(DIR => dirname($self->{file}));

    my $first = 1;
    for my $pos (@$poss) {
        $fh->print("###\n") unless $first;
        $first = 0;
        $fh->print("logfile: $pos->{LogFile}\n");
        $fh->print("position: $pos->{Position}\n");
        if ($pos->{Inode}) {
            $fh->print("inode: $pos->{Inode}\n");
        }
        if ($pos->{LastLine}) {
            $fh->print("lastline: $pos->{LastLine}\n");
        }
        if ($self->{rollback}) {
            $pos->{CommitTime} ||= time;
            $fh->print("committime: $pos->{CommitTime}\n");
        }
    }
    $fh->flush;
    if ($fh->error) {
        die 'print into '.$fh->filename.' failed';
    }

    chmod(0644, $fh->filename) or die "Failed to chmod ".$fh->filename.": $!";
    rename($fh->filename, $self->{file}) or die "Failed to commit pos $self->{file}: $!";
    $fh->unlink_on_destroy(0);
}

sub _write_file {
    my ($self, $pos) = @_;

    return $self->_write_file_fully([$pos]);
}

sub _commit_with_backups($$) {
    my ($self, $pos) = @_;

    my $time = time;

    my $poss = $self->_read_file_fully();

    unless ($poss) {
        $self->_write_file($pos);
        return;
    }

    my @times = map { $time - ($_->{CommitTime} || $time) } @$poss;
    my @new_poss = ();
    if ($times[0] > $self->{rollback} || scalar @times == 1) {
        @new_poss = ($pos, $poss->[0]);
    } elsif ($times[1] <= $self->{rollback}) {
        @new_poss = @$poss;
        $new_poss[0] = $pos;
    } elsif ($times[1] > $self->{rollback}) {
        @new_poss = ($pos, $poss->[0], $poss->[1]);
    }
    $self->_write_file_fully(\@new_poss);
}

sub commit($$) {
    my ($self, $pos) = @_;

    return unless defined $pos->{Position}; # pos is missing and log either => do nothing
    return $self->_commit_with_backups($pos) if ($self->{rollback});

    $self->_write_file($pos);
}

sub rollback {
    my ($self) = @_;
    return 0 unless $self->{rollback};

    my $file = $self->{file};

    return 0 unless -e $file;

    my $poss = $self->_read_file_fully();
    return 0 unless $poss;
    return 0 unless scalar @$poss > 1;

    shift @$poss;
    $self->_write_file_fully($poss);
    return 1;
}

sub clean($) {
    my ($self) = @_;
    return unless -e $self->{file};
    unlink $self->{file} or die "Can't remove $self->{file}: $!";
}

sub DESTROY {
    my ($self) = @_;
    if ($self->{lock_fh}) {
        flock $self->{lock_fh}, LOCK_UN;
    }
}

1;

