#!/usr/bin/perl
# vim: ft=perl

package Log::Unrotate::test;

use strict;
use warnings;
use lib qw(lib);

use Test::More tests => 57;
use Test::Exception;
use IO::Handle;

use t::Utils;

BEGIN {
    use_ok('Log::Unrotate');
}

xsystem('rm -rf tfiles && mkdir tfiles');

my $reader;
my $params;
my $line;

sub params()
{
    my $params = {
        pos => 'tfiles/test.pos',
        log => 'tfiles/test.log',
    };
    return $params;
}

$params = params();

sub print_log($;$$)
{
    my ($line, $file, $nonewline) = @_;
    $file ||= 'test.log';
    $nonewline ||= 0;
    diag("Print $line to log") if $ENV{DEBUG};

    open my $LOG, ">>tfiles/$file" or die;
    $LOG->autoflush(1);
    print $LOG $line;
    print $LOG "\n" unless $nonewline;
}

sub execute($)
{
    my $command = shift;
    diag("Execute $command") if $ENV{DEBUG};

    xsystem("cd tfiles; $command");
}

sub clear(;$)
{
    my $donotclear = shift || 0;
    execute('rm -f *') unless $donotclear;
}

sub prepare_three_logs(;$)
{
    my $donotclear = shift || 0;
    clear($donotclear);
    print_log('first', 'test.log.2');
    print_log('second', 'test.log.2');
    print_log('third', 'test.log.1');
    print_log('fourth', 'test.log.1');
    print_log('fifth', 'test.log');
    print_log('sixth', 'test.log');
}

xsystem('rm -rf tfiles && mkdir tfiles'); # both local and remote

# ============ tests ===========

execute('touch test.log');
$reader = new Log::Unrotate($params);
lives_ok(sub { $reader->position() }, "Backstep successful on missing previous log");
$line = $reader->read;
is($line, undef, "Empty line when read from empty file");


print_log("test1");
$reader = new Log::Unrotate($params);
$line = $reader->read;
$reader->commit;
is($line, "test1\n", "Read one line from file");


print_log("test2");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is($line, "test2\n", "Read second line after commit");


$line = $reader->read;
$reader->commit;
is($line, undef, "Read empty line again");

print_log("test3");
# rotate
execute('mv test.log test.log.1 && touch test.log');
$reader = new Log::Unrotate($params);
$line = $reader->read;
is($line, "test3\n", "Read line from rotated file");
$line = $reader->read;
is($line, undef, "Read empty line once again");
$reader->commit();
execute('mv test.log.1 test.log.2 && mv test.log test.log.1 && touch test.log');
print_log("test1");
print_log("test2");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is($line, "test1\n", "Handle position 0 poperly");
$line = $reader->read;
is($line, "test2\n", "Read one more line");
$reader->commit();

print_log("test3");
# rotate again
execute('mv test.log test.log.1');
 
print_log("test1");
print_log("test2"); # make checksum match
print_log("test4"); # make main log size > then rotated one 
# read
$params->{check_inode} = 1; # check_inode saves from LastLine collision
$reader = new Log::Unrotate($params);
$line = $reader->read;
is($line, "test3\n", "Read line from rotated file");
$line = $reader->read;
is($line, "test1\n", "Read next line from main file");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is($line, "test3\n", "Read line from rotated file again (commit didn't happened)");


$line = $reader->read;
$reader->commit;
is($line, "test1\n", "Read line from main file again");

$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test2\n", "Read next line from main file");
$line = $reader->read;
$reader->commit;
is ($line, "test4\n", "Read yet more line from main file");
$line = $reader->read;
is ($line, undef, "Read nothing after commit");

$params = params();
$params->{pos} = '-';
print_log("test5");
$reader = new Log::Unrotate($params);
$line = $reader->read;
$reader->commit;
is ($line, "test1\n", "Read first line from main file");


$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test1\n", "Read first line from main file (commit to '-' is ignored)");
$params = params();

print_log("test6");
print_log("test7");
$reader = new Log::Unrotate($params);
$line = $reader->read;
my $pos = $reader->position();
$line = $reader->read;
$reader->commit($pos);
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test6\n", "Read line after commit to special position");

$reader = new Log::Unrotate($params);
print_log("test8");
$reader->read;
$reader->read;
$line = $reader->read;
is ($line, undef, "Won't read what is written after opening file");
$reader->commit();

print_log("test9", "test.log", 1);
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test8\n");
$line = $reader->read;
is ($line, undef, "Won't read what has no newline");

execute('rm -f test.log*');
prepare_three_logs(1);

devnull_stderr();
devnull_stdout();
eval {
    $reader = new Log::Unrotate($params);
    $line = $reader->read;
};
my $exception = "$@";
restore_stderr();
restore_stdout();

like( $exception, qr/unable to find/, "Die if unknown inode" );

$params = params();
clear();
print_log("test1");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test1\n");
$reader->commit();
execute('mv test.log test.log.1 && touch test.log');
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, undef, "nothing to read from empty file");
is_deeply ($reader->position(), $reader->position(), "position method does not spoil self");
isnt ($reader->position()->{Position}, 0, "do not progress to an empty log");
$reader->commit();
eval {
    $reader = new Log::Unrotate($params);
};
is ($@, "", "calculate pos file correctly when read nothing");


clear();
$params->{check_inode} = 0;
$reader = new Log::Unrotate($params);
$reader->commit();
print_log("test1");
print_log("test2");
print_log("test3");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test1\n");
$reader->commit();
execute("cp test.log test.log.1 && rm test.log"); # change inode
print_log("test4");
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test2\n", "Correctly find log file not checking inode");
$reader->commit();
$reader = new Log::Unrotate($params);
$reader->commit();
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "test3\n", "Correctly commit without read");
$line = $reader->read;
is ($line, "test4\n");
$reader->commit();
$params = params();



clear();
$params = params();

prepare_three_logs();
$params->{start} = 'begin';
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "fifth\n", 'Read line, start = begin');

prepare_three_logs();
$params->{start} = 'end';
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, undef, 'Read line, start = end');

print_log('seventh', 'test.log');
$reader->commit;
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "seventh\n", 'Read line, start = end');

prepare_three_logs();
$params->{start} = 'first';
$reader = new Log::Unrotate($params);
$line = $reader->read;
is ($line, "first\n", 'Read line, start = first');


prepare_three_logs();
print_log('test line 1', 'test.log.2');
print_log('test line 2', 'test.log.2');
print_log('test line 3', 'test.log.2');
print_log('test line 4', 'test.log.2');
print_log('test line 5', 'test.log.1');
print_log('test line 6', 'test.log.1');
print_log('test line 7', 'test.log');
print_log('test line 8', 'test.log');
print_log('test line 9', 'test.log');
$params->{start} = 'first';
$reader = new Log::Unrotate($params);
$line = $reader->read;
$line = $reader->read;
$line = $reader->read;
is ($reader->lag(), 121, 'lag, start = first');
execute("rm test.log.1");
is ($reader->lag(), 84, 'lag once again, start = first');
$params->{start} = 'begin';
$reader = new Log::Unrotate($params);
is ($reader->lag(), 48, 'lag, start = begin');
$params->{start} = 'end';
$reader = new Log::Unrotate($params);
is ($reader->lag(), 0, 'lag, start = end');

$params = params();

clear();
print_log('line1');
print_log('line2');
print_log('line3');
print_log('line4');
$reader = new Log::Unrotate($params);
$line = $reader->read;
$line = $reader->read;
$line = $reader->read;
$reader->commit;
execute('echo line5 >test.log');
devnull_stderr();
devnull_stdout();
eval {
    $reader = new Log::Unrotate($params);
    $line = $reader->read;
};
$exception = "$@";
restore_stderr();
restore_stdout(); 
like ($exception, qr/unable to find/, 'Too big position in .pos file');


clear();
devnull_stderr();
devnull_stdout();
execute('echo blah > test.pos');
eval {
    $reader = new Log::Unrotate($params);
};
$exception = "$@";
restore_stderr();
restore_stdout();
like ($exception, qr/missing/, 'Die when bad posfile');

clear();
devnull_stderr();
devnull_stdout();
execute('echo "" > test.pos');
eval {
    $reader = new Log::Unrotate($params);
};
$exception = "$@";
restore_stderr();
restore_stdout();
like ($exception, qr/missing/, 'Die when empty posfile');

SKIP: {
    skip '/dev/stdin not found' => 1 unless -e '/dev/stdin';
    my $abc = xqx(q#echo abc | perl -Ilib -e '
        use Log::Unrotate;
        $u = new Log::Unrotate({pos => "-", log => "/dev/stdin", end => "future"});
        print $u->read()'#);
    is ($abc, "abc\n", 'log => "/dev/stdin"');
}

clear();
execute('echo ' . ('abc'x100) . ' >test.log');
execute('echo ' . ('123'x100) . ' >>test.log');
$reader = new Log::Unrotate(params());
$line = $reader->read();
is ($line, ('abc' x 100) . "\n", 'Long lines read correctly');
$reader->commit();
$reader = new Log::Unrotate(params());
$line = $reader->read();
is ($line, ('123' x 100) . "\n", 'Long lines correctly saved into the .pos file');

clear();
$params = params();
execute('echo "123" >>test.log');
execute('echo "111" >>test.log');
execute('echo "special" >>test.log');
execute('echo "5" >>test.log');
$params->{filter} = sub {
    my $line = shift;
    chomp $line;
    die "!!!111" if $line eq '111';
    return {something => 'special'} if $line eq 'special';
    return $line * 2;
};
$reader = new Log::Unrotate($params);
$line = $reader->read();
chomp $line;
is($line, "246", 'filter works');

throws_ok( sub {$reader->read()}, qr/^!!!111/, 'filter exceptions passes through');
is($reader->read()->{something}, "special", "filter can return hashref");
is($reader->read(), "10", "filter exceptions doesn't break reading if catched");


clear();
$params = params();
print_log("a");
print_log("b");
$reader = new Log::Unrotate($params);
is($reader->read(), "a\n");
$reader->commit();
execute("mv test.log test.log.1 && touch test.log");
$reader = new Log::Unrotate($params); 
is($reader->read(), "b\n");
is($reader->read(), undef);
$reader->commit();
print_log("c", "test.log.1"); # prev log may be updated till the new log is empty
$reader = new Log::Unrotate($params);
is($reader->read(), "c\n");
is($reader->read(), undef);
$reader->commit();
print_log("d");
$reader = new Log::Unrotate($params);
is($reader->read(), "d\n");

