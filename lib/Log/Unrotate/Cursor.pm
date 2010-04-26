package Log::Unrotate::Cursor;

use strict;
use warnings;

=head1 NAME

Log::Unrotate::Cursor - abstract unrotate cursor

=head1 DECRIPTION

C<Log::Unrotate> keeps its position in persistent objects called cursors.

See C<Log::Unrotate::Cursor::File> for default cursor implementation.

=head1 METHODS

=over

=item B<read()>

Get hashref with position data.

Data usually contains I<Position>, I<Inode>, I<LastLine> and I<LogFile> keys.

=cut
sub read($) {
    die 'not implemented';
}

=item B<commit($position)>

Save new position into cursor.

=cut
sub commit($$) {
    die 'not implemented';
}

=item B<clean()>

Clean all data from cursor.

=cut
sub clean($) {
    die 'not implemented';
}

=back

=head1 AUTHOR

Vyacheslav Matjukhin <mmcleric@yandex-team.ru>

=cut

1;

