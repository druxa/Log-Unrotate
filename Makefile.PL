use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Log::Unrotate',
    VERSION_FROM => 'lib/Log/Unrotate.pm',
    ABSTRACT_FROM       => 'lib/Log/Unrotate.pm',
    PREREQ_PM         => {
        'Test::More' => 0,
        'Test::Exception' => 0,
    },
    AUTHOR         => 'Andrei Mishchenko <druxa@yandex-team.ru>, Vyacheslav Matjukhin <mmcleric@yandex-team.ru>',
    EXE_FILES      => ['bin/unrotate'],
    clean => { FILES => ['tfiles', 'cover_db'] },
);

