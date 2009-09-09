#!/usr/bin/perl
# vim: syn=perl
use strict;
use warnings;

use Yandex::Logger ({Path => '-', Text => q{
    log4perl.appender.Log = Yandex::Appender::File
    log4perl.appender.Log.filename = tfiles/unrotate.log
    log4perl.appender.Log.layout = PatternLayout
    log4perl.appender.Log.layout.ConversionPattern = %d: %p: %c: %m%n
    log4perl.logger = INFO, Log
}});

package LogWriter;

use IO::Handle;
use Yandex::X qw(xopen xclose xsystem xprint);

sub new ($;$) {
    my ($class, $props) = @_;
    $props ||= {};
    my $self = {
        LogFile => "tfiles/test.log",
        %$props,
    };

    unless ($self->{PosFile}) {
        $self->{PosFile} = $self->{LogFile};
        $self->{PosFile} =~ s/\.log$/.pos/ or $self->{PosFile} =~ s/$/.pos/;
    }

    bless $self => $class;
}

sub logfile ($;$) {
    my ($self, $n) = @_;
    my $log = $self->{LogFile};
    $log .= ".$n" if $n;
    return $log;
}

sub posfile ($) {
    my ($self) = @_;
    return $self->{PosFile};
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
    my @logs = sort { $b <=> $a } map { /\.(\d+)$/ and $1 or 0 } glob("$self->{LogFile}*");
    for (@logs) {
        xsystem("mv " . $self->logfile($_) . " " . $self->logfile($_ + 1)); 
    }
}

sub remove ($;$) {
    my ($self, $n) = @_;
    my $log = $self->logfile($n);
    xsystem("rm -f $log");
    
}

sub clear ($) {
    my ($self) = @_;
    xsystem("rm -f $self->{LogFile}* $self->{PosFile}");
}

sub DESTROY ($) {
    my ($self) = @_;
    $self->clear();
}

1;

package Yandex::Unrotate::test;

use strict;
use warnings;
use lib qw(lib);

use Test::More tests => 52;
use Test::Exception;
use IO::Handle;
use Yandex::Logger;
use Yandex::X qw(xsystem xqx);

xsystem('rm -rf tfiles && mkdir tfiles');

BEGIN {
    use_ok('Log::Unrotate');
}

sub reader ($;$) {
    my ($writer, $opts) = @_;
    $opts ||= {};

    return new Log::Unrotate({
        LogFile => $writer->logfile(),
        PosFile => $writer->posfile(),
        %$opts,
    });
}

# missing log (3)
{
    my $writer = new LogWriter;
    my $reader = reader($writer);
    lives_ok(sub { $reader->position() }, "Backstep successful on missing log");
    my $line = $reader->readline();
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
    my $line = $reader->readline();
    is($line, undef, "Reading from an empty file");
}

# simple readline (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test1\n", "Read one line from file");
    $line = $reader->readline;
    is($line, undef, "Reading at the end of file");
}

# commit and readline (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2\n", "Read second line after commit");
}

# commit twice (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $reader = reader($writer);
    lives_ok(sub { $reader->commit() }, "Commit without a preceding readline");
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2\n", "Read second line after commit twice");
}

# commit position (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    my $reader = reader($writer);
    $reader->readline();
    my $pos = $reader->position();
    $reader->readline();
    $reader->commit($pos);
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2\n", "Read after commiting nondefault position");
}

# readline and rotation (3)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2\n", "Read line from a rotated file");
    $line = $reader->readline();
    is($line, undef, "Reading at the end of a rotated file");
    $reader->commit();
    $writer->write("test3");
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test3\n", "Go on reading after a rotated file is over");

}

# commit, rotate and readline (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $writer->write("test3");
    lives_ok( sub { $reader = reader($writer) }, "Commited state successfully found after rotation");
    my $line = $reader->readline();
    is($line, "test2\n", "Read from commited state after rotation");
}

# empty log rotation (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $writer->rotate();
    $writer->touch();
    $writer->rotate();
    $writer->write("test2");
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2\n", "Empty files skipped");
}

# position 0 issue (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, undef, "Empty line from empty file");
    $reader->commit();
    $writer->write("test2");
    $writer->rotate();
    $writer->write("test3");
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test2\n", "Position 0 handled properly");
}

# CheckInode flag (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test2");
    $reader = reader($writer, {CheckInode => 1});
    my $line = $reader->readline();
    is($line, "test1\n", "CheckInode saves from LastLine collision");
    
    $writer->clear();
    $writer->write("test1");
    $writer->write("test2");
    $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    my $log = $writer->logfile();
    xsystem("cp $log $log.1 && mv $log.1 $log"); # change inode
    $reader = reader($writer, {CheckInode => 0});
    $line = $reader->readline();
    is($line, "test2\n", "Skip inode check when CheckInode is off");
}


# EndPos => "fixed" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {EndPos => "fixed"});
    $reader->readline();
    $writer->write("test2");
    my $line = $reader->readline();
    is($line, undef, "Ignore what was written to the log after it was opened");
}

# EndPos => "future" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {EndPos => "future"});
    $reader->readline();
    $writer->write("test2");
    my $line = $reader->readline();
    is($line, "test2\n", "Read what was written to the log after it was opened");
}

# incomplete lines (5)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->write_raw("test2");
    $writer->rotate();
    $writer->write("test3");
    $writer->write_raw("test4");
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test2", "Read incomplete lines from rotated logs");
    $reader->readline();
    $line = $reader->readline();
    is($line, undef, "Ignore incomplete line at the end of the last log");
    $reader->commit();
    $writer->write_raw("\n");
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test4\n", "Correctly backstep after meeting an incomplete line");
    $reader->commit();
    $writer->write_raw("test5");
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, undef, "Ignore incomplete line at the end of the last non-empty log");
    $writer->write_raw("\n", 1);
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test5\n", "Correctly backstep after meeting an incomplete line in an rotated log");
}

# 'unable to find' exception (2)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer);
    $reader->readline();
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
    $reader->readline();
    $reader->commit();
    
    $writer->rotate();
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test1");
    $writer->remove(2);
    throws_ok(sub {$reader = reader($writer, {CheckInode => 1})}, qr/unable to find/, "Die if proper Inode is missing");
}

# position() issues (4)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    $writer->rotate();
    $writer->touch();
    $reader = reader($writer);
    $reader->readline();
    is_deeply($reader->position(), $reader->position(), "Call to position() does not spoil self");

    $reader->readline();
    $reader->commit();
    $writer->write("test3", 1);
    $reader = reader($writer);
    my $line = $reader->readline();
    is($line, "test3\n", "A rotated log may be updated till the new log is empty");
    
    $reader->readline();
    $reader->commit();
    $writer->write("test4");
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test4\n", "Calculate position correctly when read nothing");
    $reader->commit();

    $reader = reader($writer);
    $reader->commit();
    $writer->write("test5");
    $reader = reader($writer);
    $line = $reader->readline();
    is($line, "test5\n", "Calculate position correctly without a call to readline()");
}

# StartPos flag (3)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->rotate();
    $writer->write("test2");
    my $reader = reader($writer, {StartPos => "begin"});
    my $line = $reader->readline();
    is($line, "test2\n", "StartPos => 'begin' interpreted properly");
    $reader = reader($writer, {StartPos => "first"});
    $line = $reader->readline();
    is($line, "test1\n", "StartPos => 'first' interpreted properly");
    $reader = reader($writer, {StartPos => "end", EndPos => "future"});
    $writer->write("test3");
    $line = $reader->readline();
    is($line, "test3\n", "StartPos => 'end' interpreted properly");
}

# showlag (2)
{
    my $writer = new LogWriter;
    $writer->write("test0");
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    $writer->write("test4");
    $writer->write("test5");
    my $reader = reader($writer);
    $reader->readline();
    is($reader->showlag(), 5*6, "showlag() is correct on a single log");
    $reader->commit();
    $writer->rotate();
    $writer->write("test6");
    $writer->write("test7");
    $writer->rotate();
    $writer->write("test8");
    $reader = reader($writer);
    is($reader->showlag(), 8*6, "showlag() is correct on a multiple logs");
}

# exceptions (4)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    $writer->write("test2");
    $writer->write("test3");
    my $reader = reader($writer);
    $reader->readline();
    $reader->readline();
    $reader->commit();
    my $logfile = $writer->logfile();
    xsystem("echo test4 >$logfile");
    throws_ok(sub {$reader = reader($writer, {CheckInode => 1, CheckLastLine => 0})}, qr/unable to find/, "Check for too big Position");
    my $posfile = $writer->posfile();
    xsystem("echo 'LastLine: test1' >$posfile");
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file mandatory fields");
    xsystem("echo blah >$posfile");
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file syntax");
    xsystem("echo >$posfile");
    throws_ok(sub {$reader = reader($writer)}, qr/missing/, "Check .pos file is not empty");
}

# PosFile => "-" (1)
{
    my $writer = new LogWriter;
    $writer->write("test1");
    my $reader = reader($writer, {PosFile => "-"});
    $reader->readline();
    $reader->commit();
    $reader = reader($writer, {PosFile => "-"});
    my $line = $reader->readline();
    is($line, "test1\n", 'PosFile "-" ignores commits');
}

# LogFile => "-" (1)
{
    my $test1 = xqx(q#echo test1 | perl -Ilib -e '
    use Log::Unrotate;
    $reader = new Log::Unrotate({PosFile => "-", LogFile => "-", EndPos=>"future"});
    print $reader->readline()'#);
    is ($test1, "test1\n", 'LogFile => "-" reads stdin');
}

# loooooong lines (2)
{
    my $writer = new LogWriter;
    $writer->write("test1"x10000);
    $writer->write("test2"x10000);
    my $reader = reader($writer);
    $reader->readline();
    $reader->commit();
    my $posfile = $writer->posfile();
    my @posstat = stat $posfile;
    cmp_ok($posstat[7], "<", 1000, "LastLine is trancated to a reasonable size");
    $reader = reader($writer);
    my $line = $reader->readline();
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
    my $reader = reader($writer, {Filter => $filter});
    my $line = $reader->readline();
    is($line, "246", 'Filter works');
    throws_ok(sub {$reader->readline()}, qr/^!!!111/, 'Filter exceptions are passed through');
    is($reader->readline(), "10", "Filter exceptions do not break reading if catched");
    is($reader->readline()->{something}, "special", "Filter can return hashref");
}

