package Plack::Middleware::Cache::Response;
#use strict;
#use warnings;
use parent qw(Plack::Response);
use Data::Dumper;
use DateTime;
use DateTime::Format::HTTP

our $VERSION = '0.02';


# Just like Plack::Response::new, but extract the cache_control
# header to a hash first.

sub new {
    my $self = shift->SUPER::new(@_);
    
    my $str = $self->headers->header('Cache-Control');
    my $cc;
    foreach my $kv ( split m{\s*,\s*}, $str ) {
        next if $kv eq '';
        my ($k,$v) = split '=', lc $kv;
        $cc->{$k} = $v;
    }

    $self->{cache_control} = $cc;
    $self->{now} = DateTime->now;
    $self;
}


# Just like Plack::Response::finalize, but bake in the cache_control
# hash values into headers first.

sub finalize {
    my $self = shift;

    my $cc = $self->{cache_control};
    my $str = join ', ', map {
        ($cc->{$_} ? $_.'='.$cc->{$_} : $_)
    } keys %$cc;

    $self->headers->header( 'Cache-Control', $str ) if $str;
    $self->SUPER::finalize;
}


# Get/set the Expires and Date headers as a DateTime object.

sub date { shift->_header_date('Date',@_) }
sub expires { shift->_header_date('Expires',@_) }


# Get/set ETag, Vary and Last-Modified headers as-is
# Note: last_modified is NOT a DateTime object and must
# be compared by string equality vs. If-Modified-Since!

sub etag { shift->headers->header('ETag',@_) }
sub vary { shift->headers->header('Vary',@_) }
sub last_modified { shift->headers->header('Last-Modified',@_) }


# Age of the response in seconds. From Age header, or difference
# between Date header and now.

sub age {
    my $self = shift;
    
    my $age = $self->headers->header('Age',@_);
    return $age if defined $age;
    return 0 if not defined $self->date;
    
    $age = $self->{now}
        ->subtract_datetime_absolute($self->date)
        ->in_units('seconds');

    return $age > 0 ? $age : 0;
}


# The number of seconds after the time specified in the response's Date
# header when the the response should no longer be considered fresh. First
# check for a s-maxage directive, then a max-age directive, and then fall
# back on an expires header; return nil when no maximum age can be
# established.

sub max_age {
    my $self = shift;

    my $max_age = $self->{cache_control}->{'s-maxage'} ||
                  $self->{cache_control}->{'max-age'};
    
    return $max_age if $max_age;

    my $expires = $self->expires;
    return if not defined $expires;

    my $date = $self->date || $self->{now};
    return $expires
        ->subtract_datetime_absolute($date)
        ->in_units('seconds');
}


# The response's time-to-live in seconds, or undef when no freshness
# information is present in the response. When the responses #ttl
# is <= 0, the response may not be served from cache without first
# revalidating with the origin.

# Set the response's time-to-live for shared caches to the specified number
# of seconds. This adjusts the Cache-Control/s-maxage directive.

sub ttl {
    my ($self,$seconds) = @_;
    if ($seconds) {
        $self->{cache_control}->{'s-maxage'} = $self->age + $seconds;
    } else {
        my $max_age = $self->max_age;
        return if not defined $max_age;
        return $max_age - $self->age;
    }
}


# Determine if the response is "fresh". Fresh responses may be served from
# cache without any interaction with the origin. A response is considered
# fresh when it includes a Cache-Control/max-age indicator or Expiration
# header and the calculated age is less than the freshness lifetime.

sub is_fresh {
    my $self = shift;

    my $ttl = $self->ttl;
    return if not defined $ttl;

    return $ttl > 0;
}


# Determine if the response includes headers that can be used to validate
# the response with the origin using a conditional GET request.

sub is_validateable {
    my $self = shift;
    
    return $self->last_modified || $self->etag;
}


# Determine if the response is worth caching under any circumstance. Responses
# marked "private" with an explicit Cache-Control directive are considered
# uncacheable.
#
# Responses with neither a freshness lifetime (Expires, max-age) nor cache
# validator (Last-Modified, ETag) are considered uncacheable.

sub is_cacheable {
    my $self = shift;

    # Status codes of responses that MAY be stored by a cache or used in reply
    # to a subsequent request. http://tools.ietf.org/html/rfc2616#section-13.4
    my @cacheable_codes = qw( 200 203 300 301 302 404 410 ); 

    return if not grep { $_ eq $self->status } @cacheable_codes;
    return if $self->{cache_control}->{'no-store'};
    return if $self->{cache_control}->{'private'};

    return $self->is_validateable || $self->is_fresh;
}


# Indicates that the cache must not serve a stale response in any
# circumstance without first revalidating with the origin. When present,
# the TTL of the response should not be overriden to be greater than
# the value provided by the origin.

sub is_must_revalidate {
    my $self = shift;

    return exists $self->{cache_control}->{'must-revalidate'} ||
           exists $self->{cache_control}->{'proxy-revalidate'};
}


# Mark the response stale by setting the Age header to be equal to the
# maximum age of the response.

sub expire {
    my $self = shift;
    $self->age( $self->max_age ) if $self->is_fresh;
}


# Modify the response so that it conforms to the rules defined for
# '304 Not Modified'. This sets the status, removes the body, and
# discards any headers that MUST NOT be included in 304 responses.
#
# http://tools.ietf.org/html/rfc2616#section-10.3.5

sub make_not_modified {
    my $self = shift;

    # Headers that MUST NOT be included with 304 Not Modified responses.
    # http://tools.ietf.org/html/rfc2616#section-10.3.5
    my @not_modified_omit = qw(
        Allow Content-Encoding Content-Language Content-Length
        Content-MD5 Content-Type Last-Modified
    );
    
    $self->status(304);
    $self->body('');
    $self->headers->remove_header( @not_modified_omit );
}


#######################

# Internal get/set helper method for manipulating date-based headers.
# (Expires and Date)

sub _header_date {
    my ($self,$name,$value) = @_;

    if ($value) {
        my $d = DateTime::Format::HTTP->format_datetime($value);
        return $self->headers->header($name => $d);
    }

    my $d = $self->headers->header($name);
    return if not defined $d;

    DateTime::Format::HTTP->parse_datetime($d);
}


1;
