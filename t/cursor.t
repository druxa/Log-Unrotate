#!/usr/bin/perl

use strict;
use warnings;

package Log::Unrotate::Cursor::test;

use strict;
use warnings;
use lib qw(lib);

use Test::More tests => 93;
use Test::NoWarnings;
use t::Utils;

BEGIN {
    use_ok('Log::Unrotate::Cursor::File');
}

sub cursor (;$) {
    my ($opts) = @_;
    $opts ||= {};
    my $file = delete $opts->{file} || 'tfiles/cursor.pos';

    return Log::Unrotate::Cursor::File->new(
        $file, {
            lock => 'none',
            %$opts,
        },
    );
}

sub default_pos (;$) {
    my ($opts) = @_;
    $opts ||= {};

    return {
        Position => 100,
        LogFile => 'tfiles/log.log',
        Inode => 123,
        LastLine => 'some line',
        CommitTime => time - 4,
        %$opts,
    };
}

sub fields {
    return qw/Position LogFile Inode LastLine/;
}

# locks are tested in t/new.t

# read empty (2)
{
    unlink 'tfiles/cursor.pos';
    my $c = cursor();
    my $pos = $c->read();
    is($pos, undef, "Read before commits");

    $pos = $c->read();
    is($pos, undef, "Reread cursor before commits");
}

# commit & clean & read (1)
{
    my $c = cursor();
    $c->commit(default_pos());
    $c->clean();

    my $pos = $c->read();
    is($pos, undef, "Read after clean");
}

# commit & read (6)
{
    my $c = cursor();
    my $def_pos = default_pos();
    $c->commit($def_pos);

    my $pos = $c->read();

    ok(defined $pos, "Read commited position");
    for my $field (fields()) {
        is($pos->{$field}, $def_pos->{$field}, "Read commited '$field' value");
    }
    my @extra_fields = ();
    for my $field (keys %$pos) {
        push @extra_fields, $field
            unless (grep { $field eq $_ } fields());
    }
    is(scalar @extra_fields, 0, "No extra fields in position")
        or diag "Extra fields: @extra_fields";
}

# commit & read rollbackable (7)
{
    my $c = cursor({rollback_period => 5});
    my $def_pos = default_pos();
    $c->commit($def_pos);

    my $pos = $c->read();

    ok(defined $pos, "Read commited position");
    for my $field ((fields(), 'CommitTime')) {
        is($pos->{$field}, $def_pos->{$field}, "Read commited '$field' value");
    }
    my @extra_fields = ();
    for my $field (keys %$pos) {
        push @extra_fields, $field
            unless (grep { $field eq $_ } (fields(), 'CommitTime'));
    }
    is(scalar @extra_fields, 0, "No extra fields in position")
        or diag "Extra fields: @extra_fields";
}

# 2 commits (5)
{
    my $c = cursor();

    my $def_pos = default_pos();
    $c->commit($def_pos);

    my $other_pos = default_pos({
        Position => 110,
        LastLine => 'some other line',
        CommitTime => time - 2,
    });
    $c->commit($other_pos);

    my $pos = $c->read();
    ok(defined $pos, "Read commited position");
    for my $field (fields()) {
        is($pos->{$field}, $other_pos->{$field}, "Read commited '$field' value");
    }
}

# rollback unrollbackable (4)
{
    my $c = cursor();

    $c->commit(default_pos);
    is($c->read()->{Position}, 100, "Position after first commit");

    $c->commit(default_pos({
        Position => 110,
        CommitTime => time - 3,
    }));
    is($c->read()->{Position}, 110, "Position after second commit");

    my $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 110, "Position after failed rollback");
}

# rollback after clean (6)
{
    my $c = cursor({rollback_period => 5});

    $c->commit(default_pos);
    is($c->read()->{Position}, 100, "Position after first commit");

    $c->commit(default_pos({
        Position => 110,
        CommitTime => time - 3,
    }));
    is($c->read()->{Position}, 110, "Position after second commit");

    $c->clean();
    is($c->read(), undef, 'Position after clean');

    my $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read(), undef, "Position after clean and failed rollback");
}

# rollback to previous commit (6)
{
    my $c = cursor({rollback_period => 5});

    $c->commit(default_pos);
    is($c->read()->{Position}, 100, "Position after first commit");

    $c->commit(default_pos({
        Position => 110,
        CommitTime => time - 3,
    }));
    is($c->read()->{Position}, 110, "Position after second commit");

    my $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 100, "Position after rollback");

    $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 100, "Position after failed rollback");
}

# rollback and new commit (11)
{
    my $c = cursor({rollback_period => 5});

    $c->commit(default_pos);
    is($c->read()->{Position}, 100, "Position after first commit");

    $c->commit(default_pos({
        Position => 110,
        CommitTime => time - 3,
    }));
    is($c->read()->{Position}, 110, "Position after second commit");

    my $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 100, "Position after rollback");

    $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 100, "Position after failed rollback");

    $c->commit(default_pos({
        Position => 120,
        CommitTime => time - 2,
    }));
    is($c->read()->{Position}, 120, "Position after recommit");

    $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 100, "Position after new rollback");

    $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 100, "Position after failed rollback");
}

# rollback points updatesi - all in 5 seconds (8)
{
    my $c = cursor({rollback_period => 5});

    $c->commit(default_pos);
    is($c->read()->{Position}, 100, "Position after 1st commit");

    $c->commit(default_pos({
        Position => 120,
        CommitTime => time - 3,
    }));
    is($c->read()->{Position}, 120, "Position after 2nd commit");

    $c->commit(default_pos({
        Position => 130,
        CommitTime => time - 2,
    }));
    is($c->read()->{Position}, 130, "Position after 3rd commit");

    $c->commit(default_pos({
        Position => 140,
        CommitTime => time - 1,
    }));
    is($c->read()->{Position}, 140, "Position after 4th commit");

    my $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 100, "Position after rollback");

    $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 100, "Position after failed rollback");

}

# rollback points updates - 2 rollback points - short and long (10)
{
    my $c = cursor({rollback_period => 5});

    $c->commit(default_pos({
        Position => 20,
        CommitTime => time - 8,
    }));
    is($c->read()->{Position}, 20, "Position after 1st commit");

    $c->commit(default_pos({
        Position => 30,
        CommitTime => time - 7,
    }));
    is($c->read()->{Position}, 30, "Position after 2nd commit");

    $c->commit(default_pos({
        Position => 80,
        CommitTime => time - 2,
    }));
    is($c->read()->{Position}, 80, "Position after 3rd commit");

    $c->commit(default_pos({
        Position => 90,
        CommitTime => time - 1,
    }));
    is($c->read()->{Position}, 90, "Position after 4th commit");

    my $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 80, "Position after rollback");

    $res = $c->rollback();
    is($res, 1, "Rollback done");
    is($c->read()->{Position}, 30, "Position after rollback");

    $res = $c->rollback();
    is($res, 0, "Rollback failed");
    is($c->read()->{Position}, 30, "Position after failed rollback");

}

# rollback points updates - with sleeps (26)
{
    my $c1 = cursor({rollback_period => 1, file => 'tfiles/c1.pos',});
    my $c3 = cursor({rollback_period => 3, file => 'tfiles/c3.pos',});
    my $c5 = cursor({rollback_period => 5, file => 'tfiles/c5.pos',});
    my $c9 = cursor({rollback_period => 9, file => 'tfiles/c9.pos',});
    my $c11 = cursor({rollback_period => 11, file => 'tfiles/c11.pos',});

    diag "Now commiting with sleeps (10s)";

    for my $i (0 .. 5) {
        for my $c ($c1, $c3, $c5, $c9, $c11) {
            $c->commit(default_pos({
                Position => $i * 20,
                CommitTime => time,
            }));
        }
        sleep 2 unless $i == 5;
    }

    my $res = $c1->rollback();
    is($res, 1, "Rollback done");
    is($c1->read()->{Position}, 80, "c1 Position after rollback");

    $res = $c1->rollback();
    is($res, 0, "Rollback failed");
    is($c1->read()->{Position}, 80, "c1 Position after failed rollback");

    $res = $c3->rollback();
    is($res, 1, "Rollback done");
    is($c3->read()->{Position}, 80, "c3 Position after rollback");

    $res = $c3->rollback();
    is($res, 1, "Rollback done");
    is($c3->read()->{Position}, 60, "c3 Position after second rollback");

    $res = $c3->rollback();
    is($res, 0, "Rollback failed");
    is($c3->read()->{Position}, 60, "c3 Position after failed rollback");

    $res = $c5->rollback();
    is($res, 1, "Rollback done");
    is($c5->read()->{Position}, 80, "c5 Position after rollback");

    $res = $c5->rollback();
    is($res, 1, "Rollback done");
    is($c5->read()->{Position}, 40, "c5 Position after second rollback");

    $res = $c5->rollback();
    is($res, 0, "Rollback failed");
    is($c5->read()->{Position}, 40, "c5 Position after failed rollback");

    $res = $c9->rollback();
    is($res, 1, "Rollback done");
    is($c9->read()->{Position}, 80, "c9 Position after rollback");

    $res = $c9->rollback();
    is($res, 1, "Rollback done");
    is($c9->read()->{Position}, 0, "c9 Position after second rollback");

    $res = $c9->rollback();
    is($res, 0, "Rollback failed");
    is($c9->read()->{Position}, 0, "c9 Position after failed rollback");

    $res = $c11->rollback();
    is($res, 1, "Rollback done");
    is($c11->read()->{Position}, 0, "c11 Position after rollback");

    $res = $c11->rollback();
    is($res, 0, "Rollback failed");
    is($c11->read()->{Position}, 0, "c11 Position after failed rollback");
}


