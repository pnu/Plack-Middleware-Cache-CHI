package Plack::Middleware::Cache;
use strict;
use warnings;
use parent qw/Plack::Middleware/;

use Plack::Util::Accessor qw( chi rules scrub );
use Data::Dumper;

sub call {
    my $self = shift;
    my $env  = shift;

    return $self->app->($env)
        if ( ref $env eq 'CODE' or
        $env->{REQUEST_METHOD} ne 'GET' );

    my $res = $self->_handle_cache($env);

    return $res
        if ( $res and $res->[0] >= 200
        and $res->[0] < 300 );

    return $self->app->($env);
}

sub _handle_cache {
    my($self, $env) = @_;

    my $path;
    my $opts;

    my @rules = @{ $self->rules || [] };
    while ( @rules || return ) {
        my $match = shift @rules;
        $opts = shift @rules;
        $path = $env->{PATH_INFO};
        last if 'CODE' eq ref $match ? $match->($path) : $path =~ $match;
    }
    return if not defined $opts;

    my $cachekey = 
        $env->{REQUEST_METHOD}.' '.$env->{PATH_INFO}.' '.
        $env->{SERVER_PROTOCOL}.' '.$env->{HTTP_HOST};
    
    local $env->{PATH_INFO} = $path; # rewrite PATH

    if ( length $env->{QUERY_STRING} ) {
        $self->chi->remove( $cachekey );
        return $self->app->($env);
    }

    my $compute = sub {
        my $res = $self->app->($env);
        $self->_scrub_headers( $res );

        my $body;
        Plack::Util::foreach( $res->[2], sub {
            $body .= $_[0] if $_[0];
        });

        return [ $res->[0], $res->[1], [$body] ];
    };

    return $self->chi->compute( $cachekey, $compute, $opts );
}

sub _scrub_headers {
    my($self, $res) = @_;

    foreach ( @{ $self->scrub || [] } ) {
        Plack::Util::header_remove( $res->[1], $_ );
    }
}

1;
