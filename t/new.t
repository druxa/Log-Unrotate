#!/usr/bin/perl

use strict;
use warnings;

package LogWriter;

use t::Utils;
use IO::Handle;

sub new ($;$) {
    my ($class, $props) = @_;
    $props ||= {};
    my $self = {
        log => "tfiles/test.log",
        %$props,
    };

    unless ($self->{pos}) {
        $self->{pos} = $self->{log};
        $self->{pos} =~ s/\.log$/.pos/ or $self->{pos} =~ s/$/.pos/;
    }

    bless $self => $class;
}

sub logfile ($;$) {
    my ($self, $n) = @_;
    my $log = $self->{log};
    $log .= ".$n" if $n;
    return $log;
}

sub posfile ($) {
    my ($self) = @_;
    return $self->{pos};
}

sub write_raw ($$;$) {
    my ($self, $line, $n) = @_;
    my $fh = xopen(">>", $self->logfile($n));
    xprint($fh, $line);
    $fh->flush();
    xclose($fh);
}

sub write ($$;$) {
    my ($self, $line, $n) = @_;
    $line .= "\n" unless $line =~ /\n$/;
    $self->write_raw($line, $n);
}

sub touch ($;$) {
    my ($self, $n) = @_;
    $self->write_raw("", $n);
}

sub rotate ($) {
    my ($self) = @_;
    for (reverse 0..10) {
        if (-e $self->logfile($_)) {
            rename $self->logfile($_), $self->logfile($_ + 1) or die "rename failed: $!";
        }
    }
}

sub remove ($;$) {
    my ($self, $n) = @_;
    my $log = $self->logfile($n);
    if (-e $log) {
        unlink $log or die "Can't unlink $log: $!";
    }
}

sub clear ($) {
    my ($self) = @_;
    for my $file ($self->{pos}, glob("$self->{log}*")) {
        if (-e $file) {
            unlink $file or die "Can't unlink $file: $!";
        }
    }
}

sub DESTROY ($) {
    my ($self) = @_;
    $self->clear();
}

1;

package Log::Unrotate::test;

use strict;
use warnings;
use lib qw(lib);

use Test::More tests => 71;
use Test::Exception;
use File::Copy qw();
use IO::Handle;
use t::Utils;

BEGIN {
    use_ok('Log::Unrotate');
}

sub reader ($;$) {
    my ($writer, $opts) = @_;
    $opts ||= {};

    return new Log::Unrotate({
        log => $writer->logfile(),
        pos => $writer->posfile(),
        %$opts,
    });
}

# missing log (3)
{
    my $writer = new LogWriter;
    my $reader = reader($writer);
    lives_ok(sub { $reader->position() }, "Backstep successful on missing log");
    my $line = $reader->read();
    is($line, undef, "Reading from a missing file");
    $reader->commit();
    ok(not (-e $writer->posfile()), "Fake commit when missing logfile");
}

# empty log (2)
{
    my $writer = new LogWriter;
    $writer->touch();
    my $reader = reader($writer);
    lives_ok(sub { $reader->position() }, "Backstep successful on missing previous log");
    my $line = $reader->read();
    is($line, undef, "Reading from an empty file");
}

# open failures (2)
{
    my $writer = new LogWriter;
    $writer->write('test1');
    chmod 0000, $writer->logfile or die "chmod failed: $!";
    throws_ok(sub { reader($writer) }, qr/exists but is unreadable/, 'constructor fails when log is unreadable');
    chmod 0644, $writer->logfile or die "chmod failed: $!";
    undef $writer;

    $writer = new LogWriter;
    $writer->write('test1');
    my $reader = reader($writer);
    $reader->commit;

    chmod 0000, $writer->posfile or die "chmod failed: $!";
    throws_ok(sub { reader($writer) }, qr/Can't open '.*.pos'/, 'constructor fails when pos is unreadable');
    chmod 0644, $writer->posfile or die "chmod failed: $!";
}

# simple read (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test1\n", "Read one line from file");
    $line = $reader->read;
    is($line, undef, "Reading at the end of file");
}

# commit and read (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Read second line after commit");
}

# commit twice (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $reader = reader($writer);
    lives_ok(sub { $reader->commit() }, "Commit without a preceding read");
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Read second line after commit twice");
}

# commit position (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    my $reader = reader($writer);
    $reader->read();
    my $pos = $reader->position();
    $reader->read();
    $reader->commit($pos);
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Read after commiting nondefault position");
}

# read and rotation (3)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Read line from a rotated file");
    $line = $reader->read();
    is($line, undef, "Reading at the end of a rotated file");
    $reader->commit();
    $writer->write("test3");
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test3\n", "Go on reading after a rotated file is over");

}

# commit, rotate and read (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->write("test3");
    lives_ok( sub { $reader = reader($writer) }, "Commited state successfully found after rotation");
    my $line = $reader->read();
    is($line, "test2\n", "Read from commited state after rotation");
}

# empty log rotation (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $writer->rotate();
    $writer->touch();
    $writer->rotate();
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Empty files skipped");
}

# ignoring files with garbage after log number (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    { # fill non-log file
        my $fh = xopen('>', $writer->logfile(1).'.trash');
        print {$fh} "abc\n";
        xclose($fh);
    }
    $writer->rotate();
    $writer->touch();
    $writer->rotate();
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2\n", "Trash log skipped");
}

# position 0 issue (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, undef, "Empty line from empty file");
    $reader->commit();
    $writer->write("test2");
    $writer->rotate();
    $writer->write("test3");
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test2\n", "Position 0 handled properly");
}

# check_inode flag (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test2");
    $reader = reader($writer, {check_inode => 1});
    my $line = $reader->read();
    is($line, "test1\n", "check_inode saves from LastLine collision");

    $writer->clear();
    $writer->write("test1");
    $writer->write("test2");
    $reader = reader($writer);
    $reader->read();
    $reader->commit();
    my $log = $writer->logfile();

    # change inode
    File::Copy::copy($log, "$log.1") or die "Copy failed: $!";
    rename("$log.1", $log) or die "Rename failed: $!";

    $reader = reader($writer, {check_inode => 0});
    $line = $reader->read();
    is($line, "test2\n", "Skip inode check when check_inode is off");
}


# end => "fixed" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {end => "fixed"});
    $reader->read();
    $writer->write("test2");
    my $line = $reader->read();
    is($line, undef, "Ignore what was written to the log after it was opened");
}

# end => "future" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {end => "future"});
    $reader->read();
    $writer->write("test2");
    my $line = $reader->read();
    is($line, "test2\n", "Read what was written to the log after it was opened");
}

# incomplete lines (5)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->write_raw("test2");
    $writer->rotate();
    $writer->write("test3");
    $writer->write_raw("test4");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test2", "Read incomplete lines from rotated logs");
    $reader->read();
    $line = $reader->read();
    is($line, undef, "Ignore incomplete line at the end of the last log");
    $reader->commit();
    $writer->write_raw("\n");
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test4\n", "Correctly backstep after meeting an incomplete line");
    $reader->commit();
    $writer->write_raw("test5");
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    $line = $reader->read();
    is($line, undef, "Ignore incomplete line at the end of the last non-empty log");
    $writer->write_raw("\n", 1);
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test5\n", "Correctly backstep after meeting an incomplete line in an rotated log");
}

# 'unable to find' exception (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->write("test2");
    $writer->rotate();
    $writer->write("test3");
    $writer->remove(2);
    throws_ok(sub {$reader = reader($writer)}, qr/unable to find/, "Die if proper LastLine is missing");

    $writer->clear();
    $writer->write("test1");
    $reader = reader($writer);
    $reader->read();
    $reader->commit();

    $writer->rotate();
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test1");
    $writer->remove(2);
    throws_ok(sub {$reader = reader($writer, {check_inode => 1})}, qr/unable to find/, "Die if proper Inode is missing");
}

# position() issues (4)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    $reader->read();
    is_deeply($reader->position(), $reader->position(), "Call to position() does not spoil self");

    $reader->read();
    $reader->commit();
    $writer->write("test3", 1);
    $reader = reader($writer);
    my $line = $reader->read();
    is($line, "test3\n", "A rotated log may be updated till the new log is empty");

    $reader->read();
    $reader->commit();
    $writer->write("test4");
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test4\n", "Calculate position correctly when read nothing");
    $reader->commit();

    $reader = reader($writer);
    $reader->commit();
    $writer->write("test5");
    $reader = reader($writer);
    $line = $reader->read();
    is($line, "test5\n", "Calculate position correctly without a call to read()");
}

# start flag (3)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test2");
    my $reader = reader($writer, {start => "begin"});
    my $line = $reader->read();
    is($line, "test2\n", "start => 'begin' interpreted properly");
    $reader = reader($writer, {start => "first"});
    $line = $reader->read();
    is($line, "test1\n", "start => 'first' interpreted properly");
    $reader = reader($writer, {start => "end", end => "future"});
    $writer->write("test3");
    $line = $reader->read();
    is($line, "test3\n", "start => 'end' interpreted properly");
}

# lag (3)
{
    my $writer = new LogWriter;
    $writer->write("test0");
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    $writer->write("test4");
    $writer->write("test5");
    my $reader = reader($writer);
    $reader->read();
    is($reader->lag(), 5*6, "lag() is correct on a single log");
    $reader->commit();
    $writer->rotate();
    $writer->write("test6");
    $writer->write("test7");
    $writer->rotate();
    $writer->write("test8");
    $reader = reader($writer);
    is($reader->lag(), 8*6, "lag() is correct on a multiple logs");

    $writer->clear;
    $reader = reader($writer);
    throws_ok(sub { $reader->lag() }, qr/lag failed/, "can't get lag() when log is missing");
}

# exceptions (4)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    my $reader = reader($writer);
    $reader->read();
    $reader->read();
    $reader->commit();
    my $logfile = $writer->logfile();
    xecho("test4", $logfile);
    throws_ok(sub {$reader = reader($writer, {check_inode => 1, check_lastline => 0})}, qr/unable to find/, "Check for too big Position");
    my $posfile = $writer->posfile();
    xecho('LastLine: test1', $posfile);
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file mandatory fields");
    xecho("blah", $posfile);
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file syntax");
    xecho("", $posfile);
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file is not empty");
}

# constructor (6)
{
    my $writer = new LogWriter;
    throws_ok(sub { reader($writer, { start => 'blah' }) }, qr/unknown start value/, 'constructor checks start value');
    throws_ok(sub { reader($writer, { end => 'blah' }) }, qr/unknown end value/, 'constructor checks end value');
    throws_ok(sub { reader($writer, { lock => 'blah' }) }, qr/unknown lock value/, 'constructor checks lock value');
    throws_ok(sub { reader($writer, { filter => 'blah' }) }, qr/filter should be subroutine ref/, 'constructor checks filter value');
    throws_ok(sub { reader($writer, { check_inode => 0, check_lastline => 0 }) }, qr/either check_inode or check_lastline/, 'constructor checks that one of check flags is on');

    throws_ok(sub { Log::Unrotate->new({ pos => '-' }) }, qr/Position file .* not found and log not specified/, 'constructor croaks if not enough parameters specified');
}

# pos => "-" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {pos => "-"});
    $reader->read();
    $reader->commit();
    $reader = reader($writer, {pos => "-"});
    my $line = $reader->read();
    is($line, "test1\n", 'pos "-" ignores commits');
}

# log => "-" (1)
{
    my $test1 = xqx(q#echo test1 | #.$^X.q# -Ilib -e '
    use Log::Unrotate;
    $reader = new Log::Unrotate({pos => "-", log => "-", end => "future"});
    print $reader->read()'#);
    is ($test1, "test1\n", 'log => "-" reads stdin');
}

# loooooong lines (2)
{
    my $writer = new LogWriter;
    $writer->write("test1"x10000);
    $writer->write("test2"x10000);
    my $reader = reader($writer);
    $reader->read();
    $reader->commit();
    my $posfile = $writer->posfile();
    my @posstat = stat $posfile;
    cmp_ok($posstat[7], "<", 1000, "LastLine is trancated to a reasonable size");
    $reader = reader($writer);
    my $line = $reader->read();
    is($line =~ s/test2//g, 10000, "Long lines are read correctly");
}

# filtering (4)
{
    my $writer = new LogWriter;
    $writer->write(123);
    $writer->write(111);
    $writer->write(5);
    $writer->write("special");
    my $filter = sub {
        my $line = shift;
        chomp $line;
        die "!!!111" if $line eq '111';
        return {something => 'special'} if $line eq 'special';
        return $line * 2;
    };
    my $reader = reader($writer, {filter => $filter});
    my $line = $reader->read();
    is($line, "246", 'filter works');
    throws_ok(sub {$reader->read()}, qr/^!!!111/, 'filter exceptions are passed through');
    is($reader->read(), "10", "filter exceptions do not break reading if catched");
    is($reader->read()->{something}, "special", "filter can return hashref");
}

# locks (5)
{
    my $writer = new LogWriter();
    my $reader = reader($writer, { lock => 'blocking' });

    lives_ok(sub { reader($writer) }, 'constructing second writer without locks lives');
    lives_ok(sub { reader($writer, { lock => 'none' }) }, "constructing second writer without locks, explicitly specifying that we don't need lock");

    SKIP: {
        skip "solaris flock behavior is different from linux (FIXME - it should be tested anyway)" => 1 if $^O =~ /solaris/i;
        skip "irix flock behavior is different from linux (FIXME - it should be tested anyway)" => 1 if $^O =~ /irix/i;
        dies_ok(sub { reader($writer, { lock => 'nonblocking' }) }, 'constructing second writer with lock dies');
    }

    undef $reader;
    lives_ok(sub { reader($writer, { lock => 'nonblocking' }) }, 'destructor releases lock');

    chmod 0000, 'tfiles/test.pos.lock' or die "can't chmod lock file: $!";
    throws_ok(sub { reader($writer, { lock => 'nonblocking' }) }, qr/Can't open /, "constructor fails when lock can't be written");
    chmod 0644, 'tfiles/test.pos.lock' or die "chmod failed: $!";
}

# caching log in pos (4)
{
    my $writer = new LogWriter();
    $writer->write('abc');
    my $reader = reader($writer);
    $reader->commit;
    File::Copy::copy($writer->logfile, "tfiles/another.log") or die "copy failed: $!";
    lives_ok(sub { reader($writer, { log => 'tfiles/another.log' }) }, "without check_log, it's ok to change log file");
    throws_ok(sub { reader($writer, { log => 'tfiles/another.log', check_log => 1 }) }, qr/logfile mismatch/, "with check_log, it's not ok");

    lives_ok(sub { Log::Unrotate->new({ pos => $writer->posfile }) }, 'loading logfile from posfile if log not specified');

    # remove logfile line from posfile
    my $pos_fh = xopen('<', $writer->posfile);
    my $new_pos_fh = xopen('>', 'tfiles/new.pos');
    while (<$pos_fh>) {
        next if /^logfile:/;
        print {$new_pos_fh} $_;
    }
    xclose($pos_fh);
    xclose($new_pos_fh);
    rename('tfiles/new.pos', $writer->posfile);

    throws_ok(sub { Log::Unrotate->new({ pos => $writer->posfile }) }, qr/log not specified/, "constructor dies if no log specified and pos file doesn't contain log name");
}

