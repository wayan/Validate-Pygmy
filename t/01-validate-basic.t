use common::sense;
use Test::More;

use Validate::Pygmy
    qw(validate array_check record_check is_required_check if_supplied);

my @checks = (
    customer => record_check( [ id => is_required_check(), ] ),
    name => sub {
        my ($v) = @_;
        my $minlen = 6;
        return
            length($v) < $minlen
            ? "Value too short, must be at least $minlen chars"
            : undef;
    },
    addresses => array_check(
        record_check(
            [   city    => is_required_check(),
                street  => is_required_check(),
                country => if_supplied(
                    sub {
                        my ($country) = @_;
                        return $country eq 'Czech republic'
                            ? undef
                            : "Only Czech republic is allowed";
                    }
                )
            ]
        )
    ),
);

is_deeply(
    validate(
        {   customer  => {},
            name      => 'me',
            addresses => [
                {   city   => 'Brno',
                    street => 'Lerchova',
                },
                {   city    => 'Brno',
                    street  => 'Axmanova',
                    country => 'Andorra',
                },
                'Brno, Pellicova 67',
            ],
        },
        \@checks,
    ),
    {   errors => [
            {   message => "Value is required",
                path    => "\$['customer']['id']"
            },
            {   message => "Value too short, must be at least 6 chars",
                path    => "\$['name']",
            },
            {   message => "Only Czech republic is allowed",
                path    => "\$['addresses'][1]['country']",
            },
            {   message => "Value not a record",
                path    => "\$['addresses'][2]"
            },
        ],
        success => 0,
    }
);


is_deeply(
    validate(
        {   customer  => { id => 101 },
            name      => 'Proper Long name',
            addresses => [
                {   city   => 'Brno',
                    street => 'Lerchova',
                },
                {   city    => 'Brno',
                    street  => 'Axmanova',
                    country => 'Czech republic',
                },
            ],
            field_to_be_omitted => 1
        },
        \@checks,
    ),
    {   data => {
            addresses => [
                { city => "Brno", street => "Lerchova" },
                {   city    => "Brno",
                    country => "Czech republic",
                    street  => "Axmanova"
                },
            ],
            customer            => { id => 101 },
            field_to_be_omitted => 1,
            name                => "Proper Long name",
        },
        success => 1,
    }
);

done_testing();
