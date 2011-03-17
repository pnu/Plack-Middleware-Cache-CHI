package Plack::Middleware::Cache;
use strict;
use warnings;
use parent qw/Plack::Middleware/;

use Plack::Util::Accessor qw( storage ttl scrub allow_reload );
use Data::Dumper;
use Plack::Request;
use Plack::Response;
use Time::HiRes qw( gettimeofday );

our @trace;
our $timer_call;
our $timer_pass;

sub _uinterval {
    my ( $t0, $t1 ) = ( @_, [gettimeofday] );
    ($t1->[0] - $t0->[0]) * 1_000_000 + $t1->[1] - $t0->[1];
}

## call: the call hook for the Plack stack.
## Take one parameter (the env) and return a reponse tuple.
##
sub call {
    my ($self,$env) = @_;

    ## Pass-thru streaming responses
    return $self->app->($env)
        if ( ref $env eq 'CODE' );

    ## Localize trace for this request
    local @trace = ();
    local $timer_pass = undef;
    local $timer_call = [gettimeofday];

    my $req = Plack::Request->new($env);
    my $r = $self->handle($req);
    my $res = Plack::Response->new(@$r);

    ## Add trace and cache key to response headers
    $timer_call = _uinterval($timer_call);
    my $trace = join q{, }, @trace;
    my $key = $self->cachekey($req);

    ## The subrequest is timed separately
    if ( $timer_pass ) {
        $timer_call -= $timer_pass;
        $res->headers->push_header(
            'X-Plack-Cache-Time-Pass' => "$timer_pass us",
        );
    }

    $res->headers->push_header(
        'X-Plack-Cache' => $trace,
        'X-Plack-Cache-Key' => $key,
        'X-Plack-Cache-Time' => "$timer_call us",
    );

    $res->finalize;
}

## handle: take request and decide if we should pass it thru,
## try to lookup from cache, or invalidate and pass thru.
## Return the response tuple that should be sent back to the client.
##
sub handle {
    my ($self,$req) = @_;

    if ( $req->method eq 'GET' or $req->method eq 'HEAD' ) {
        if ( $req->headers->header('Expect') ) {
            push @trace, 'expect';
            $self->pass($req);
        } elsif ( $req->cache_control->{'no-cache'} && $self->allow_reload ) {
            push @trace, 'reload';
            $self->fetch($req);
        } else {
            $self->lookup($req);
        }
    } else {
        $self->invalidate($req);
    }
}

## pass: delegate request to the backend and return
## the response. A separate timer is recorded for logging
## purposes.
##
sub pass {
    my ($self,$req) = @_;
    push @trace, 'pass';
    
    $timer_pass = [gettimeofday];
    my $res = $self->app->($req->env);
    $timer_pass = _uinterval($timer_pass);
    
    return $res;
}

## invalidate: remove any matching entries from cache
## storage and pass thru the request.
##
sub invalidate {
    my ($self,$req) = @_;
    push @trace, 'invalidate';
    
    $self->storage->remove( $self->cachekey($req) );
    $self->pass($req);
}

## ttl: determine the configured ttl (or acceptable range of ttl, TODO) for
## a given request. If return value is a positive scalar, it's ttl in seconds,
## negative value means must that the entry referenced by req (that maybe
## rewritten during match processing in this method) must be invalidated from
## cache. If return value is an array ref, the ttl should be adjusted to that
## range [min,max]. Undef in a range means "no limit", or that normal rules
## should be applied.
##
sub ttl {
    my ($self, $req) = @_;

    my $path, $ttl;
    my @rules = @{ $self->rules || [] };
    while ( @rules || return ) {
        my $match = shift @rules;
        $ttl = shift @rules;
        $path = $req->path_info;
        last if 'CODE' eq ref $match ? $match->($path) : $path =~ $match;
    }
    $req->env->{PATH_INFO} = $path;

    return $ttl;
}

## lookup:  try to serve the response from cache. When a matching cache entry is
## found and is fresh, use it as the response without forwarding any
## request to the backend. When a matching cache entry is found but is
## stale, attempt to validate the entry with the backend using conditional
## GET. When no matching cache entry is found, trigger miss processing.
##
sub lookup {
    my ($self, $req) = @_;
    push @trace, 'lookup';

    ## Determine the default ttl (if defined in configuration)
    ## TODO: apply it to the cached response
    my $ttl = $self->ttl($req);
    return $self->invalidate($req) if ( $ttl < 0 );

    ## Get response from the cache storage
    my $entry = $self->get( $req );
    if ( defined $entry ) {
        push @trace, 'hit';
        $self->refurbish($req,$entry,$ttl) ||
        $self->validate($req,$entry,$ttl);
    } else {
        push @trace, 'miss';
        $self->fetch($req,$ttl);
    }
}

## refurbish: Given a storage entry, return the response
## with updated Age header.
##
sub refurbish {
    my ($self, $req, $entry, $ttl) = @_;
    my ($ereq,$eres) = @{$entry};
    push @trace, 'refurbish';

    return unless $self->is_fresh_enough($entry);

    Plack::Util::header_set($eres->[1], 'Age', 0); ## TODO
    $eres;
}

sub is_fresh_enough {
    my ($self, $entry) = @_;
    ## TODO
    return 1;
}

## validate: make a validation request to the backend. If 304 is returned,
## the stored response can be used (with few headers updated from the
## validation response). For other responses, enter it to the storage
## (if cacheable) and return it as is.
##
sub validate {
    my ($self, $req, $entry, $ttl) = @_;
    my ($ereq,$eres) = @{$entry};
    push @trace, 'validate';

    ## Make a new validation request based on the original req
    my $subreq = Plack::Request->new( $req );
    $subreq->method('GET');
    $subreq->headers->header('If-Modified-Since') = $eres->last_modified;

    ## ETags that client has, and etags we have..
    my %req_etag = map { $_ => 1 } split /\s*,\s*/,
        $subreq->headers->header('If-None-Match');
    my %store_etag = map { $_ => 1 } split /\s*,\s*/,
        Plack::Util::header_get($eres->[1], 'ETag');

    ## Any of these etags satisfy our validation request
    $subreq->headers->header( 'If-None-Match' =>
        join ', ', (keys %req_etag, keys %store_etag)
    );

    my $res = $self->pass( $subreq );
    
    if ( $res->[0] == 304 ) {
        push @trace, 'notmodified';
        
        ## Extract the ETags that this response validated
        my %res_etag = map { $_ => 1 } split /\s*,\s*/,
            Plack::Util::header_get($res->[1], 'ETag');

        ## Return the 304 as is if it validated something we don't have
        my $etag = Plack::Util::header_get($res->[1], 'ETag');
        return $res if $etag && $req_etag{$etag} && !$store_etag{$etag};

        ## Copy various caching related headers to the stored response.
        for ( qw( Date Expires Cache-Control ETag Last-Modified ) ) {
            my $val = Plack::Util::header_get( $res->[1], $_ );
            Plack::Util::header_set( $eres->[1], $val );
        }

        ## And return the stored response
        return $eres;
    }

    ## Store the response
    my $response = Plack::Middleware::Cache::Response->new($res);
    $self->set($req,$res,$ttl) if $response->is_cacheable;

    $res;
}

## fetch: The cache missed or a reload is required. Forward the request to the
## backend and determine whether the response should be stored.
##
sub fetch {
    my ($self, $req, $ttl) = @_;
    push @trace, 'fetch';

    ## Make a request based on the original req
    my $subreq = Plack::Request->new( $req );
    $subreq->method('GET');
    $subreq->headers->remove_header('If-Modified-Since','If-None-Match');
  
    my $res = Plack::Middleware::Cache::Response->new( $self->pass($subreq) );

    ## Mark the response as explicitly private if any of the private
    ## request headers are present and the response was not explicitly
    ## declared public.
    $res->cache_control->{private} = undef
        if $self->is_private($req) &&
        exists $res->cache_control->{public};

    # use our own ttl if defined, or use what's provided
    # cache control can disable the default ttl assigment.
    $ttl = $res->is_must_revalidate
        ? $res->ttl
        : $ttl || $res->ttl;

    ## Store the response
    my $response = $res->finalize;
    $self->set($req,$response,$ttl) if $res->is_cacheable;

    $response;
}

sub is_private {
    my ($self, $req) = @_;
        
    for ( @{ $self->private_headers } ) {
        return 1 if $req->headers->header($_);
    }

    return;
}

sub cachekey {
    my ($self, $req) = @_;

    my $uri = $req->uri->canonical;

    $uri->query(undef)
        if not $self->cachequeries;

    $uri->as_string;
}

sub get {
    my ($self, $req) = @_;
    push @trace, 'get';

    my $key = $self->cachekey($req);
    $self->storage->get( $key );
}

sub set {
    my ($self, $req, $res, $ttl) = @_;
    push @trace, 'set';
 
    ## Read in filehandle bodies and scrub the headers before storage
    my $key = $self->cachekey($req);
    my $response = $self->slurp($res);

    $self->storage->set( $key, [$req->headers,$response], $ttl );
}

sub slurp {
    my ($self, $res) = @_;

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
