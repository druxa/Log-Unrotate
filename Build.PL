use 5.008;
use Module::Build;

if ($^O =~ /MSWin|cygwin/) {
    die "OS unsupported";
}

my $mb = Module::Build->new(
    module_name     => 'Log::Unrotate',
    license         => 'perl',
    dist_author     => ['Andrei Mishchenko <druxa@yandex-team.ru>', 'Vyacheslav Matjukhin <mmcleric@yandex-team.ru>'],
    script_files => ['bin/unrotate'],
    requires        => {
        'Module::Build' => 0.2805,
        'Test::More'    => 0,
        'File::Temp' => '0.15',
    },
    build_requires => {
        'Test::More'     => 0,
        'Test::Exception' => 0,
    },
    add_to_cleanup => ['tfiles', 'cover_db'],
);

$mb->create_build_script;
