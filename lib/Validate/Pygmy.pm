package Validate::Pygmy;

# ABSTRACT: Field validator for nested structures

use common::sense;
use Carp qw(confess);

use Exporter qw(import);
our @EXPORT_OK = (
    # validation
    'validate',
    'validate_record',
    'validate_any',
    'validate_array',

    # nested checks
    'array_check',
    'record_check',

    # validation result without validation
    'validation_success',
    'validation_failure',

    # apply check only when value is supplied
    'if_supplied',
);

use Ref::Util qw(is_arrayref is_hashref is_ref is_coderef);
use List::Util qw(pairkeys pairmap pairgrep);

*validate = \&validate_record;

# returns data as validation success
sub validation_success {
    my ($data) = @_;
    return { success => 1, data => $data };
}

# converts error to failed validation result
sub validation_failure {
    my ($errors_arg) = @_;

    my $errors
        = is_arrayref($errors_arg) ? $errors_arg
        : is_hashref($errors_arg)
        ? [ map { +{ path => _rec_jpath($_), message => $errors_arg->{$_}, } } sort keys %$errors_arg ]
        : !is_ref($errors_arg)
        && defined($errors_arg) ? [{ path => '$', message => $errors_arg }]
        : confess "Invalid errors for validation_failure";
    return { success => 0, errors => $errors };
}

# runs the check only when the value is supplied
# so far field is not supplied only if $data is a hash
# and there is no field with given name
sub if_supplied {
    my ($check_arg) = @_;

    return _wrap_check(
        sub {
            my ($check) = @_;
            return sub {
                my ( $v, $data, $field ) = @_;
                return is_hashref($data) && !exists $data->{$field}
                    ? undef
                    : $check->( @_ );
            };
        },
        $check_arg
    );
}

sub validate_record {
    my ( $data, @args ) = @_;

    return validate_any( $data, record_check(@args));
}

sub validate_array {
    my ( $data, @args ) = @_;

    return validate_any( $data, array_check(@args));
}

sub record_check {
    my ( $checks_arg) = @_;

    my @checks = _expand_field_checks($checks_arg);

    return if_supplied sub {
        my ($data) = @_;

        is_hashref($data) or return "Value not a record";

        my ( %failed, @errors, $data_cp );
    CHECK: for my $row (@checks) {
            my ( $field, $check ) = @$row;

            # first error on every field
            next CHECK if $failed{$field};
            my $res = $check->(
                ( $data_cp // $data )->{$field},
                $data_cp // $data, $field
            );
            next CHECK if !defined $res;
            if ( !is_ref($res) ) {

                # plain error message
                push @errors, { message => $res, path => _rec_jpath($field) };
                $failed{$field} = 1;
            }
            elsif ( is_validation_success($res) ) {

                # copy on write
                ${ $data_cp //= +{%$data} }{$field} = $res->{data};
            }
            elsif ( is_validation_failure($res) ) {
                push @errors, map {
                    +{  %$_,
                        path =>
                            _nested_jpath( _rec_jpath($field), $_->{path} ),
                    };
                } @{ $res->{errors} };
                $failed{$field} = 1;
            }
            else {
                confess
                    "Check for field '$field' returned unexpected value: '$res'";
            }
        }
        return
              %failed ? { success => 0, errors => \@errors }
            : $data_cp ? { success => 1, data => ( $data_cp // $data ) }
            :            undef;
    };
}

# perform check for each value in array
sub array_check {
    my ($check_arg) = @_;

    my @checks = _expand_checks($check_arg);

    return if_supplied sub {
        my ($data) = @_;
        is_arrayref($data) or return "Value not an array";

        my ( $data_cp, $nok, @errors );
    ELEM: for ( my $i = 0; $i < @$data; $i++ ) {
        CHECK: for my $check (@checks) {
                my $res = $check->(
                    ( $data_cp // $data )->[$i],
                    $data_cp // $data, $i
                );
                next CHECK if !defined($res);
                if ( !is_ref($res) ) {

                    # plain error message
                    push @errors, { message => $res, path => _ary_jpath($i) };
                    $nok = 1;
                    next ELEM;
                }
                elsif ( is_validation_failure($res) ) {
                    push @errors, map {
                        +{  %$_,
                            path =>
                                _nested_jpath( _ary_jpath($i), $_->{path} ),
                        };
                    } @{ $res->{errors} };
                    $nok = 1;
                    next ELEM;
                }
                elsif ( is_validation_success($res) ) {
                    ${ $data_cp //= +[@$data] }[$i] = $res->{data};
                }
                else {
                    confess
                        "Check for element '$i' returned unexpected value: '$res'";
                }
            }
        }
        return
              $nok     ? { success => 0, errors => \@errors }
            : $data_cp ? { success => 1, data   => $data_cp }
            :            undef;
    };
}

sub validate_any {
    my ( $data, $check_arg ) = @_;

    my @checks = _expand_checks($check_arg);

    my ( $nok, @errors );
CHECK: for my $check (@checks) {
        next CHECK if $nok;
        my $res = $check->($data);
        defined($res) or next CHECK;

        if ( !is_ref($res) ) {
            push @errors, { message => $res, path => _scalar_jpath() };
            $nok = 1;
            last CHECK;
        }
        elsif ( is_validation_failure($res) ) {
            push @errors, @{ $res->{errors} };
            $nok = 1;
            last CHECK;
        }
        elsif ( is_validation_success($res) ) {
            $data = $res->{data};
        }
        else {
            confess "Check returned unexpected value: '$res'";
        }
    }
    return $nok
        ? { success => 0, errors => \@errors }
        : { success => 1, data => $data };
}

sub is_validation_success {
    my ($v) = @_;
    return is_hashref($v) && $v->{success} && exists( $v->{data} );
}

sub is_validation_failure {
    my ($v) = @_;
    return
           is_hashref($v)
        && exists( $v->{success} )
        && !$v->{success}
        && exists( $v->{errors} );
}

sub is_required_check {
    my ($message) = @_;

    $message //= 'Value is required';
    return sub {
        my ( $v, $data, $field ) = @_;
        return exists $data->{$field} ? undef : $message;
    };
}

sub is_array_check {
    my ($message) = @_;

    $message //= 'Value not an array';
    return sub {
        my ( $v, $data, $field ) = @_;
        return !is_arrayref($v)
            ? $message
            : undef;
    };
}

sub is_record_check {
    my ($message) = @_;

    $message //= 'Value not a record';
    return sub {
        my ($v) = @_;
        return !is_hashref($v) ? $message : undef;
    };
}

sub is_nonempty_array_check {
    my ($nonempty_message) = @_;

    $nonempty_message //= 'Array must have at least one element';
    return [
        is_array_check(),
        sub {
            my ($v) = @_;
            return !@$v ? $nonempty_message : undef;
        }
    ];
}

# working with "json" path
sub _ary_jpath {
    my ($idx) = @_;

    return "\$[$idx]";
}

sub _rec_jpath {
    my ($field) = @_;

    # TO DO - quoting
    return qq{\$['$field']};
}

sub _scalar_jpath { return '$' }

sub _nested_jpath {
    my ($top, $bottom) = @_;

    return $top if ! $bottom || $bottom eq '$';
    $bottom =~ s/^\$//;
    return "$top$bottom";
}

sub _expand_checks {
    my ($arg) = @_;

    return ($arg) if is_coderef($arg);
    return map { _expand_checks($_) } @$arg if is_arrayref($arg);
    confess "Invalid check ('$arg'), must be a coderef or arrayref (of coderefs)";
}

sub _expand_field {
    my ($arg) = @_;
    return ($arg) if !is_ref($arg);
    return map { _expand_field($_) } @$arg if is_arrayref($arg);
    confess "Invalid field ('$arg'), must be a string or arrayref (of strings)";
}

# expand multiple_field into multiple checks
sub _expand_field_checks {
    my ($arg) = @_;

    my @field_checks;
    for(my $i = 0; $i < @$arg; $i += 2){
        my @fields = _expand_field($arg->[$i]);
        my @checks = _expand_checks($arg->[$i+1]);
        for my $field ( @fields ){
            for my $check ( @checks){
                push @field_checks, [$field, $check];
            }
        }
    }
    return @field_checks;
}

sub _wrap_check {
    my ($wrapper, $check_arg) = @_;

    my @checks = map { $wrapper->($_) } _expand_checks($check_arg);
    return @checks == 1? $checks[0]: \@checks;
}

1;

__END__

=head1 SYNOPSIS

    use common::sense;

    use Validate::Pygmy
        qw(validate array_check record_check is_required_check if_supplied);

    my @checks = (
        customer => record_check( [ id => is_required_check(), ] ),
        name => sub {
            my ($v) = @_;
            my $minlen = 6;
            return length($v) < $minlen
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

    my $v_res = validate(
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
    );
    # yields

     {
       errors  => [
                    { message => "Value is required", path => "\$['customer']['id']" },
                    {
                      message => "Value too short, must be at least 6 chars",
                      path => "\$['name']",
                    },
                    {
                      message => "Only Czech republic is allowed",
                      path => "\$['addresses'][1]['country']",
                    },
                    { message => "Value not a record", path => "\$['addresses'][2]" },
                  ],
       success => 0,
     }


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
        },
        \@checks,
    );

    # yields:
     {
       data => {
         addresses => [
           { city => "Brno", street => "Lerchova" },
           { city => "Brno", country => "Czech republic", street => "Axmanova" },
         ],
         customer => { id => 101 },
         name => "Proper Long name",
       },
       success => 1,
     }



    my $v_res = validate(
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
        { all_fields => 1, }
    );

    # yields:
     {
       data => {
         addresses => [
           { city => "Brno", street => "Lerchova" },
           { city => "Brno", country => "Czech republic", street => "Axmanova" },
         ],
         customer => { id => 101 },
         field_to_be_omitted => 1,
         name => "Proper Long name",
       },
       success => 1,
     }

=hea1 DESCRIPTION

C<Validate::Pygmy> is a simple validator inspired by Validate::Tiny.
It can validate nested structures and report each error together with address
of input structure where the error occured.


=head2 Validation result

Every validation function returns a validation result. It is a plain hashref with key C<success>
indicating the success of validation.

If C<success> is true, validation result contains another key C<data> with an arbitrary value.

Example of validation success:

    {   success => 1,
        data    => {
            id   => 200,
            name => 'Some name'
        }
    }

If C<success> is false, key C<errors> contains an array of errors which occured during validation.
Every error is a plain hashref containing at least keys

=over 4

=item message

Textual description of the error

=item path

The closest part of the structure where the error occured. The path is in JSON path format.
If the error occured "at top level", the value of C<path> is C<< $ >>.


=back

Examples of validation failures:

    {
      errors  => [
        { message => "Value not a record", path => '$' },
      ],
      success => 0,
    }

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
            { message => "Value not a record", path => "\$['addresses'][2]" },
        ],
        success => 0,
    }


=head1 Functions

=head2 validate

=head2 validate_record

    my $v_res = validate($data, \@field_checks);

Validates record (hashref) by applying user defined checks to individual fields of the hash.
C<< @fields_checks >> is an array of C<< $field => $check >> pairs. Instead of C<< $field >>, resp. C<< $check >>
an array ref of fields or refs can be used and those arrays are naturally expanded.

For every C<< $field => $check >> pair, the check is called: C<< $check->($data->{$field}, $data, $field >>.
The returned value is evaluated like this:

=over 4

=item undef

Check is considered success.

=item $message (where message is a string)

Check is considered failure, an error reported on the fields is collected. Example

   { path => '$["name"]', message => 'Value too long }

=item validation success (hashref)

Check is considered success. More over the content of validation success (under C<< data >> key) replaces
the field value for subsequent field tests and also in return value of validate_record. This functionality
work like filters from C<< Validate::Tiny >>.

=item validation failure (hashref)

Check is considered failure, all errors from the failure are collected with the name of field prepended
to their paths.

=back

Any check suitable for Validate::Tiny validation can be used for Validate::Pygmy too.

If check for a field failed no subsequent check for the same field is run.

If any check failed C<< validate_record >> returns validation failure with all collected errors.

If all checks succeeded and none of them returns validation success, C<< validate_record >>
returns validation success with data being the original structure.

If all checks succeeded and any of them returns validation success, C<< validate_record >>
returns validation success with data being the copy of the original structure, with some
fields set to values returned by checks.

=head2 validate_any

  my $v_res = validate_any($value, $check);

Call the check C<< $check->($value) >> and normalizes the return value to either validation success or validation failure.

    validate_any( "X",
        sub { length( shift() ) < 4 ? "Value too short" : undef } )

    # yields
    {   success => 0,
        errors  => [ { path => '$', message => 'Value too short' } ]
    }

    # while
    validate_any( "Adam",
        sub { length( shift() ) < 4 ? "Value too short" : undef } )

    # yields
    {   success => 1,
        data  => "Adam",
    }

The C<< $check >> can be an arrayref of checks. In such case all checks (or until the first fails) are applied to value.
If any check return a validation success, the value is changed for every subsequent check (and for the value returned
from C<< validate_any >>.

    use Validate::Pygmy qw(validate_any validation_success);
    use Ref::Util qw(is_arrayref);

    my $v_res = validate_any(
        'Adam',
        [   sub {
                my ($v) = @_;
                return is_arrayref($v)
                    ? undef
                    : validation_success( [$v] );
            },
            sub {
                my ($names) = @_;
                return @$names > 3 ? "Too many names" : undef;
            }
        ]
    );

    # yields
    { data => ["Adam"], success => 1 }

=head2 validate_array

     validate_array(\@data, $check);

Apply check on every element of the array, returns validation result.


=head2 validation_success

    validation_success($data)

Turns a value into validation success. Data is value of any type. Basically:

   { success => 1, data => $data }

=head2 validation_failure

     validation_failure($arg)

Turns a value into validation failure. The argument can be:

=over 4

=item string

Reports the error as it occured on top level:

    validation_failure("Customer was already deleted");

    # yields
    {
      errors  => [{ message => "Customer was already deleted", path => "\$" }],
      success => 0,
    }


=item arrayref

Reports the errors without change:

=item hashref of strings

Reports the errors as they were errors of fields of a hash.

    validation_failure( { id => 'Not a number', name => 'Too long' } );

    # yields
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


=back

=head2 record_check

    record_check(\@field_checks)

Check to be used for validating nested structures. Works like validate_record.
C<< validate_record($data, $field_checks) >> is actually implemented like
C<< validate_any($data, record_check($field_checks)) >>.

=head2 array_check

    array_check($check)

Check function applying the C<< $check >> on every element of the array.
C<< validate_array($data, $check) >> is actually C<< validate_any($data, array_check($check) >>.


=cut



