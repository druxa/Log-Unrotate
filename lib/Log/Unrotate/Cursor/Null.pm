package Log::Unrotate::Cursor::Null;

use strict;
use warnings;

=head1 NAME

Log::Unrotate::Cursor::Null - dummy cursor

=head1 DESCRIPTION

This is a dummy cursor, commits to it go nowhere.

=head1 METHODS

=over

=cut

use base qw(Log::Unrotate::Cursor);

use overload '""' => sub { 'Null' };

=item B<new()>

Create null cursor.

=cut
sub new {
    return bless {} => shift;
}

=back

=cut

sub read { return }
sub commit { return }
sub clean { return }

1;

