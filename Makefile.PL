use 5.006;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Log::Unrotate',
    PREREQ_PM         => {},
    AUTHOR         => 'Andrei Mishchenko <druxa@yandex-team.ru>',
    EXE_FILES      => ['bin/unrotate'],
    clean => { FILES => 'tfiles' },
);

