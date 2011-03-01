package Plack::Middleware::Cache;
use strict;
use warnings;
use parent qw/Plack::Middleware/;

use Plack::Util::Accessor qw( chi rules scrub cachequeries trace );
use Data::Dumper;
use Plack::Request;
use Plack::Response;
use Time::HiRes qw( gettimeofday tv_interval );

our @trace;

sub call {
    my ($self,$env) = @_;

    ## Pass-thru streaming responses
    return $self->app->($env)
        if ( ref $env eq 'CODE' );

    ## Localize trace for this request
    local @trace = ();
    my $t0 = [gettimeofday];

    my $req = Plack::Request->new($env);
    my $r = $self->handle($req);
    my $res = Plack::Response->new(@$r);

    ## Add trace and cache key to response headers
    my $trace = join q{, }, @trace;
    my $key = $self->cachekey($req);

    $res->headers->push_header(
        'X-Plack-Cache' => $trace,
        'X-Plack-Cache-Key' => $key,
        'X-Plack-Cache-Time' => tv_interval($t0),
    );

    $res->finalize;
}

sub handle {
    my ($self,$req) = @_;

    if ( $req->method eq 'GET' or $req->method eq 'HEAD' ) {
        if ( $req->headers->header('Expect') ) {
            push @trace, 'expect';
            $self->pass($req);
        } else {
            $self->lookup($req);
        }
    } else {
        $self->invalidate($req);
    }
}

sub pass {
    my ($self,$req) = @_;
    push @trace, 'pass';
    $self->app->($req->env);
}

sub invalidate {
    my ($self,$req) = @_;
    push @trace, 'invalidate';
    $self->chi->remove( $self->cachekey($req) );
    $self->pass($req);
}

sub match {
    my ($self, $req) = @_;

    my $path;
    my $opts;

    my @rules = @{ $self->rules || [] };
    while ( @rules || return ) {
        my $match = shift @rules;
        $opts = shift @rules;
        $path = $req->path_info;
        last if 'CODE' eq ref $match ? $match->($path) : $path =~ $match;
    }
    return $opts;
}

sub lookup {
    my ($self, $req) = @_;
    push @trace, 'lookup';

    my $opts = $self->match($req);
    
    return $self->pass($req)
        if not defined $opts;

    return $self->invalidate($req)
        if ( $req->param and not $self->cachequeries );

    my $entry = $self->fetch( $req );
    my $res = [ 500, ['Content-Type','text/plain'], ['ISE'] ];

    if ( defined $entry ) {
        push @trace, 'hit';
        $res = $entry->[1];
        return $self->invalidate($req)
            if not $self->valid($req,$res);
    } else {
        push @trace, 'miss';
        $res = $self->delegate($req);
        $self->store($req,$res,$opts)
            if $self->valid($req,$res);
    }
    return $res;
}

sub valid {
    my ($self, $req, $res) = @_;

    my $res_status = $res->[0];

    return
        unless (
            $res_status == 200 or
            $res_status == 203 or
            $res_status == 300 or
            $res_status == 301 or
            $res_status == 302 or
            $res_status == 404 or
            $res_status == 410
        );
    
    return 1;
}

sub cachekey {
    my ($self, $req) = @_;

    my $uri = $req->uri->canonical;

    $uri->query(undef)
        if not $self->cachequeries;

    $uri->as_string;
}

sub fetch {
    my ($self, $req) = @_;
    push @trace, 'fetch';
    
    my $key = $self->cachekey($req);
    $self->chi->get( $key );
}

sub store {
    my ($self, $req, $res, $opts) = @_;
    push @trace, 'store';
    
    my $key = $self->cachekey($req);
    $self->chi->set( $key, [$req->headers,$res], $opts );
}

sub delegate {
    my ($self, $req, $opts) = @_;
    push @trace, 'delegate';

    my $res = $self->app->($req->env);
    foreach ( @{ $self->scrub || [] } ) {
        Plack::Util::header_remove( $res->[1], $_ );
    }

    my $body;
    Plack::Util::foreach( $res->[2], sub {
        $body .= $_[0] if $_[0];
    });

    return [ $res->[0], $res->[1], [$body] ];
}

1;
