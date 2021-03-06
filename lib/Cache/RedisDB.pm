package Cache::RedisDB;

use 5.010;
use strict;
use warnings FATAL => 'all';
use Carp;
use RedisDB 2.14;
use Sereal qw(looks_like_sereal);

=head1 NAME

Cache::RedisDB - RedisDB based cache system

=head1 VERSION

Version 0.09

=head1 DESCRIPTION

This is just a warpper around RedisDB to have a single Redis object and connection per process. By default uses server 127.0.0.1:6379, but it may be overwritten by REDIS_CACHE_SERVER environment variable. It transparently handles forks.

=head1 COMPATIBILITY AND REQUIREMENTS

Redis 2.6.12 and higher strongly recommended.  Required if you want to use
extended options in ->set().

=cut

our $VERSION = '0.09';

=head1 SYNOPSIS

    use Cache::RedisDB;
    Cache::RedisDB->set("namespace", "key", "value");
    Cache::RedisDB->get("namespace", "key");

=head1 SUBROUTINES/METHODS

=head2 redis_server_info

Returns redis host and port separated by colon

=cut

sub redis_server_info {
    return $ENV{REDIS_CACHE_SERVER} || '127.0.0.1:6379';
}

=head2 redis_connection

Creates new connection to redis-server and returns corresponding RedisDB object.

=cut

sub redis_connection {
    my ($server, $port) = split /:/, redis_server_info();
    return RedisDB->new(
        host               => $server,
        port               => $port,
        reconnect_attempts => 3,
        on_connect_error   => sub {
            confess "Cannot connect to server $server:$port";
        });
}

=head2 redis

Returns RedisDB object connected to the correct redis server.

=cut

sub redis {
    state $redis;
    $redis //= redis_connection();
    return $redis;
}

=head2 get($namespace, $key)

Retrieve I<$key> value from the cache.

=cut

sub get {
    my ($self, $namespace, $key) = @_;
    my $res = redis->get(_cache_key($namespace, $key));
    if (looks_like_sereal($res)) {
        state $decoder = Sereal::Decoder->new();
        $res = $decoder->decode($res);
    }
    return $res;
}

=head2 set($namespace, $key, $value[, $exptime])

Assigns I<$value> to the I<$key>. I<$value> should be scalar value.
If I<$exptime> specified, it is expiration time in seconds.

=cut

sub set {
    my ($self, $namespace, $key, $value, $exptime, $callback) = @_;
    if (not defined $value or ref $value or Encode::is_utf8($value)) {
        state $encoder = Sereal::Encoder->new({
            freeze_callbacks => 1,
            protocol_version => 2
        });
        $value = $encoder->encode($value);
    }
    my $cache_key = _cache_key($namespace, $key);
    if (defined $exptime) {
        $exptime = int(1000 * $exptime);
        # PX milliseconds -- Set the specified expire time, in milliseconds
        return redis->set($cache_key, $value, "PX", $exptime, $callback // ());
    } else {
        return redis->set($cache_key, $value, $callback // ());
    }
}

=head2 set_nw($namespace, $key, $value[, $exptime])

Same as I<set> but do not wait confirmation from server. If server will return
error, there's no way to catch it.

=cut

sub set_nw {
    my ($self, $namespace, $key, $value, $exptime) = @_;
    return $self->set($namespace, $key, $value, $exptime, RedisDB::IGNORE_REPLY);
}

=head2 del($namespace, $key1[, $key2, ...])

Delete given keys and associated values from the cache. I<$namespace> is common for all keys.
Returns number of deleted keys.

=cut

sub del {
    my ($self, $namespace, @keys) = @_;
    return redis->del(map { _cache_key($namespace, $_) } @keys);
}

=head2 keys($namespace)

Return a list of all known keys in the provided I<$namespace>.

=cut

sub keys {
    my ($self, $namespace) = @_;
    my $prefix = _cache_key($namespace, undef);
    return [map { s/^$prefix//; $_ } @{redis->keys($prefix . '*')}];
}

=head2 ttl($namespace, $key)

Return the Time To Live (in seconds) of a key in the provided I<$namespace>.

=cut

sub ttl {
    my ($self, $namespace, $key) = @_;

    my $ms = redis->pttl(_cache_key($namespace, $key));
    # We pessimistically round to the start of the second where it
    # will disappear.  While slightly wrong, it is likely less confusing.
    # Nonexistent (or already expired) keys should return 0;
    return ($ms <= 0) ? 0 : int($ms / 1000);
}

sub _cache_key {
    my ($namespace, $key) = @_;
    $namespace //= '';
    $key       //= '';

    return $namespace . '::' . $key;
}

=head3 flushall

Delete all keys and associated values from the cache.

=cut

sub flushall {
    return redis->flushall();
}

=head1 AUTHOR

binary.com, C<< <rakesh at binary.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-cache-redisdb at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Cache-RedisDB>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Cache::RedisDB


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Cache-RedisDB>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Cache-RedisDB>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Cache-RedisDB>

=item * Search CPAN

L<http://search.cpan.org/dist/Cache-RedisDB/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2014 binary.com.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;    # End of Cache::RedisDB
