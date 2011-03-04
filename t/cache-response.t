use strict;
use warnings;
use Test::More;
use Plack::Middleware::Cache::Response;
use DateTime;
use DateTime::Duration;
use DateTime::Format::HTTP;
use Data::Dumper;


my $hour = DateTime::Duration->new(hours=>1);
my $now = DateTime->now;
my $hourago = $now - $hour;
my $hourlater = $now + $hour;
sub hd { DateTime::Format::HTTP->format_datetime(@_) }

sub res { Plack::Middleware::Cache::Response->new(@_) }

{
    my $r = res( 200, [], [] );

    $r->expires( $hourlater );
    is $r->header('Expires'), hd($hourlater), 'set Expires header';
    is $r->expires, $hourlater, 'get Expires header';

    $r->etag( '0xDEADBEEF' );
    is $r->header('ETag'), '0xDEADBEEF', 'set ETag header';
    is $r->etag, '0xDEADBEEF', 'get ETag header';
    
    $r->vary( '1,2,3,4' );
    is $r->header('Vary'), '1,2,3,4', 'set Vary header';
    is $r->vary, '1,2,3,4', 'get Vary header';

    $r->last_modified( 'my wedding day' );
    is $r->header('Last-Modified'), 'my wedding day', 'set Last-Modified';
    is $r->last_modified, 'my wedding day', 'get Last-Modified header';

    ok ! defined $r->header('Date') &&
       ! defined $r->header('Age')  && $r->age == 0,
        'age is 0 if Age and Date headers missing';

    $r->date( $hourlater );
    is $r->header('Date'), hd($hourlater), 'set Date header with DateTime';
    is $r->date, $hourlater, 'get Date header';

    ok $r->age == 0, 'age is 0 if Date is in the future';

    $r->date( $hourago );
    ok $r->age >= 3600, 'calculate age from Date header and current time';

    $r->age( 1800 );
    is $r->header('Age'), 1800, 'set Age header';
    ok $r->age == 1800, 'get Age and use over Date';
}

{
    my $r = res( 200, [ 'Cache-Control' => 'aaa, bbb, ccc' ], [] );
    ok ! $r->is_must_revalidate, 'detect Cache-Control must-revalidate';
    
    my $r = res( 200, [ 'Cache-Control' => 'must-revalidate, aaa' ], [] );
    ok $r->is_must_revalidate, 'detect Cache-Control must-revalidate';
    
    for (
        'must-revalidate',
        'must-revalidate ,bbb',
        'aaa,must-revalidate,bbb',
        'aaa, must-revalidate ,bbb',
        'aaa , must-revalidate , bbb',
        'aaa ,, must-revalidate , bbb',
    ) {
        my $r = res( 200, [ 'Cache-Control' => $_ ], [] );
        ok $r->is_must_revalidate, 'parse Cache-Control variations';
    }
}

{
    my $r = res( 200, [ 'Cache-Control' => 'proxy-revalidate' ], [] );
    ok $r->is_must_revalidate, 'detect Cache-Control proxy-revalidate';
}

{
    my $r = res( 200, [ 'Cache-Control' => 'private' ], [] );
    ok ! $r->is_cacheable, 'not cacheable: Cache-Control private';
}


{
    my $r = res( 200, ['Cache-Control' => 'max-age=200'], [] );
    ok $r->max_age == 200, 'Cache-Control max-age defines max age';
    
    my $r = res( 200, ['Cache-Control' => 's-maxage=200'], [] );
    ok $r->max_age == 200, 'Cache-Control s-maxage defines max age';
}

{
    my $r = res( 200, [ 'Expires' => hd($now) ], [] );
    ok $r->max_age == 0, 'Expires alone defined max age';

    $r->date( $hourago );
    ok $r->max_age == 3600, 'Max age is seconds from Date to Expires';
}

{
    my $r = res( 200, [], [] );
    ok ! $r->is_validateable, 'need validator';

    $r->last_modified( 'whateva' );
    ok $r->is_validateable, 'Last-Modified is a validator';
}

{
    my $r = res( 200, ['ETag'=>'xxx'], [] );
    ok $r->is_validateable, 'ETag is a validator';
}

{
    my $etag = ['ETag' => 'xxx'];

    ok res( 200, $etag, [] )->is_cacheable, '200 is cacheable';
    ok res( 203, $etag, [] )->is_cacheable, '203 is cacheable';
    ok res( 300, $etag, [] )->is_cacheable, '300 is cacheable';
    ok res( 301, $etag, [] )->is_cacheable, '301 is cacheable';
    ok res( 302, $etag, [] )->is_cacheable, '302 is cacheable';
    ok res( 404, $etag, [] )->is_cacheable, '404 is cacheable';
    ok res( 410, $etag, [] )->is_cacheable, '410 is cacheable';
    ok ! res( 201, $etag, [] )->is_cacheable, '201 is not cacheable';
    ok ! res( 303, $etag, [] )->is_cacheable, '303 is not cacheable';
    ok ! res( 510, $etag, [] )->is_cacheable, '510 is not cacheable';
    ok ! res( 500, $etag, [] )->is_cacheable, '500 is not cacheable';
}

done_testing;
