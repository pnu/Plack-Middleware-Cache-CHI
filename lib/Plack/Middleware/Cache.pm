package Plack::Middleware::Cache;
use strict;
use warnings;
use parent qw/Plack::Middleware/;

use Plack::Util::Accessor qw( chi rules );
use Data::Dumper;

sub call {
    my $self = shift;
    my $env  = shift;

    if ( $env->{REQUEST_METHOD} eq 'GET' ) {

        my $res = $self->_handle_cache($env);
        if ( $res and $res->[0] >= 200 and $res->[0] < 300 ) {
            return $res;
        }

    }
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

    my $compute = sub { warn 'going to app'; $self->app->($env) };

    return $self->chi->compute( $cachekey, $compute, $opts );
}

1;
