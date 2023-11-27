use strict;
use warnings;

use Test2::V0;
use Test2::Tools::Compare qw{is U};

InternalTimer(time()+1, sub() {
    my %hash;
    $hash{TEMPORARY} = 1;
    $hash{NAME}  = q{Voltego};
    $hash{TYPE}  = q{Voltego};
    $hash{STAE}  = q{???};

    subtest "Demo Test checking define" => sub {
        $hash{DEF}   = "11 1234567890ß 6000";
        plan(2);
        my $ret = Voltego_Define(\%hash,qq{$hash{NAME} $hash{TYPE}});
        like ($ret, qr/syntax error: define <name> Voltego <client_id> <client_secret> [Interval]/, 
        'check error message Voltego_Define');

        $ret = Voltego_Define(\%hash,qq{$hash{NAME} $hash{TYPE} $hash{DEF}});
        is ($ret, U(), 'check returnvalue Voltego_Define');
    };

    done_testing();
    exit(0);

}, 0);

1;