use common::sense;
use Test::More;
use Validate::Pygmy qw(validation_failure);

is_deeply(
    validation_failure("Customer was already deleted"),
    {   success => 0,
        errors  => [
            {   path    => '$',
                message => 'Customer was already deleted',
            }
        ]
    },
);
is_deeply(
    validation_failure( { id => 'Not a number', name => 'Too long' } ),
    {   success => 0,
        errors  => [
            {   path    => q{$['id']},
                message => 'Not a number',
            },
            {   path    => q{$['name']},
                message => 'Too long',
            }
        ]
    }
);
done_testing();
