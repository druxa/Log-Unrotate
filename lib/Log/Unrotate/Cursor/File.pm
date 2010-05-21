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

our %_lock_values = map { $_ => 1 } qw(none blocking nonblocking);

=over

=item B<new($file, $options)>

=item B<new($file)>

Construct cursor from file.

C<$options> is an optional hashref.
Only one option I<lock> is supported, describing locking behaviour. See C<Log::Unrotate> for details.

=cut
sub new {
    my ($class, $file, $options) = @_;
    croak "No file specified" unless defined $file;

    my $lock = 'none';
    if ($options) {
        $lock = $options->{lock};
    }
    croak "unknown lock value: '$lock'" unless $_lock_values{$lock};

    my $self = bless { file => $file } => $class;

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

sub read {
    my $self = shift;
    return unless -e $self->{file};

    open my $fh, '<', $self->{file} or die "Can't open '$self->{file}': $!";
    my $pos = {};
    my $content = do {local $/; <$fh>};
    $content =~ /position:\s*(\d+)/ and $pos->{Position} = $1;
    die "missing 'position:' in $self->{file}" unless defined $pos->{Position};
    $content =~ /inode:\s*(\d+)/ and $pos->{Inode} = $1;
    $content =~ /lastline:\s(.*)/ and $pos->{LastLine} = $1;
    $content =~ /logfile:\s(.*)/ and $pos->{LogFile} = $1;
    return $pos;
}

sub commit($$) {
    my ($self, $pos) = @_;

    return unless defined $pos->{Position}; # pos is missing and log either => do nothing

    my $fh = File::Temp->new(DIR => dirname($self->{file}));

    $fh->print("logfile: $pos->{LogFile}\n");
    $fh->print("position: $pos->{Position}\n");
    if ($pos->{Inode}) {
        $fh->print("inode: $pos->{Inode}\n");
    }
    if ($pos->{LastLine}) {
        $fh->print("lastline: $pos->{LastLine}\n");
    }
    $fh->flush;
    if ($fh->error) {
        die 'print into '.$fh->filename.' failed';
    }

    chmod(0644, $fh->filename) or die "Failed to chmod ".$fh->filename.": $!";
    rename($fh->filename, $self->{file}) or die "Failed to commit pos $self->{file}: $!";
    $fh->unlink_on_destroy(0);
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

