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

sub _read_file {
    my ($self, $file) = @_;

    return unless -e $file;

    open my $fh, '<', $file or die "Can't open '$file': $!";
    my $pos = {};
    my $content = do {local $/; <$fh>};
    $content =~ /position:\s*(\d+)/ and $pos->{Position} = $1;
    die "missing 'position:' in $file" unless defined $pos->{Position};
    $content =~ /inode:\s*(\d+)/ and $pos->{Inode} = $1;
    $content =~ /lastline:\s(.*)/ and $pos->{LastLine} = $1;
    $content =~ /logfile:\s(.*)/ and $pos->{LogFile} = $1;
    $content =~ /time:\s*(\d+)/ and $pos->{CommitTime} = $1;
    return $pos;
}

sub read {
    my $self = shift;

    return $self->_read_file($self->{file});
}

sub commit($$) {
    my ($self, $pos) = @_;

    return unless defined $pos->{Position}; # pos is missing and log either => do nothing
    return $self->_commit_with_backups($pos) if ($self->{rollback});

    $self->_write_pos_file($pos);
}

sub _write_pos_file {
    my ($self, $pos) = @_;

    my $fh = File::Temp->new(DIR => dirname($self->{file}));

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
        $fh->print("time: $pos->{CommitTime}\n");
    }
    $fh->flush;
    if ($fh->error) {
        die 'print into '.$fh->filename.' failed';
    }

    chmod(0644, $fh->filename) or die "Failed to chmod ".$fh->filename.": $!";
    rename($fh->filename, $self->{file}) or die "Failed to commit pos $self->{file}: $!";
    $fh->unlink_on_destroy(0);
}

sub _commit_with_backups($$) {
    my ($self, $pos) = @_;

    my $time = time;
    my @times = ();
    my $old_pos = $self->read();
    if ($old_pos) {
        push @times,  $time - ($old_pos->{CommitTime} || $time);
        my $step = 1;
        while ($old_pos = $self->_read_file("$self->{file}.$step")) {
            push @times, $time - ($old_pos->{CommitTime} || $time);
            $step++;
        }
    }

    if (scalar @times) {
        if ($times[0] > $self->{rollback} || scalar @times == 1) {
            unlink("$self->{file}.*") if scalar @times > 1;
            copy($self->{file}, "$self->{file}.1");
        } elsif ($times[1] <= $self->{rollback}) {

        } elsif ($times[1] > $self->{rollback}) {
            copy("$self->{file}.1", "$self->{file}.2");
            copy($self->{file}, "$self->{file}.1");
        }
    }
    $self->_write_pos_file($pos);
}

sub rollback {
    my ($self) = @_;
    return 0 unless $self->{rollback};

    my $file = $self->{file};

    return 0 unless -e $file;
    return 0 unless -e "$file.1";

    rename("$file.1", $file);
    for my $step ( sort { $a <=> $b } map {$_ =~ /\.(\d+)$/; $1} glob "$file.*" ) {
        rename("$file.$step", "$file.".($step - 1));
    }

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

