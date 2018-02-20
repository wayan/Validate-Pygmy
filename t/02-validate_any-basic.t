use common::sense;
use Test::More;
use Ref::Util qw(is_hashref);

use Validate::Pygmy
    qw(validate array_check record_check if_supplied validate_any);

sub is_required_check {
    return sub {
        my ($v, $data, $field) = @_;
        if ( is_hashref($data) && $field ) {
            exists $data->{$field} or return "Value is required";
        }
        return;
    };
}

sub is_record_check {
    return sub {
        my ($v ) = @_;
        return is_hashref($v) ? undef: "Value not a record";
    };
}

is_deeply(
    validate_any(
        [],
        is_record_check()
    ),
    {   errors => [
            {   message => "Value not a record",
                path    => "\$"
            },
        ],
        success => 0,
    }
);

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
    validate_any(
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
        record_check(\@checks),
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


done_testing();
