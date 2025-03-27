package PASGI::Server;

use strict;
use warnings;
use IO::Async::Loop;
use IO::Async::Listener;
use IO::Async::Stream;
use Future;
use curry;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        app  => $args{app}  || $class->curry::no_asgi_app,
        host => $args{host} || '127.0.0.1',
        port => $args{port} || 8080,
        loop => IO::Async::Loop->new,
    };
    bless $self, $class;
    return $self;
}

sub no_asgi_app { die "No ASGI app provided" }

sub start {
    my ($self) = @_;

    my $listener = IO::Async::Listener->new( on_stream => $self->curry::configure_stream );

    # Add the listener to the loop before calling listen.
    $self->{loop}->add($listener);
    $self->{listener} = $listener;

    $listener->listen(
        addr =>
          { family => "inet", socktype => "stream", port => $self->{port}, ip => $self->{host} },
        on_listen_error => $self->curry::handle_listen_error,
    );

    print "PASGI Server running on http://$self->{host}:$self->{port}/\n";
    $self->{loop}->run;
}

sub handle_listen_error {
    my ($self) = @_;
    die "Cannot listen on port $self->{port} - $!";
}

sub stop {
    my ($self) = @_;
    $self->{loop}->stop;
}

sub configure_stream {
    my ( $self, undef, $stream ) = @_;
    $stream->configure( on_read => $self->curry::handle_stream_read );
    $self->{loop}->add($stream);
}

sub handle_stream_read {
    my ( $self, $stream, $buffref, $eof ) = @_;
    if ($eof) {
        $self->close_stream($stream);
        return 0;
    }
    # Very basic HTTP GET parsing.
    if ( $$buffref =~ m/^GET\s+([^\s]+)\s+HTTP\/1\.1/ ) {
        my $path = $1;
        # Build a minimal ASGI scope.
        my $scope = {
            type   => 'http',
            method => 'GET',
            path   => $path,
        };
        # Invoke the ASGI application.
        $self->{app}
          ->( $scope, $self->curry::receive_body, $self->curry::send_stream_response($stream) )
          ->on_done( $self->curry::close_stream($stream) )
          ->on_fail( $self->curry::handle_stream_error($stream) );
    }
    $$buffref = '';    # Clear the buffer.
    return 0;
}

# Dummy receive callback.
sub receive_body { Future->done }

# writes response events back to the client.
sub send_stream_response {
    my ( $self, $stream, $event ) = @_;
    if ( $event->{type} eq 'http.response.start' ) {
        my $status = $event->{status} // 200;
        $stream->write("HTTP/1.1 $status OK\r\n");
        for my $header ( @{ $event->{headers} // [] } ) {
            $stream->write("$header->[0]: $header->[1]\r\n");
        }
        $stream->write("\r\n");
    }
    elsif ( $event->{type} eq 'http.response.body' ) {
        $stream->write( $event->{body} );
    }
    return Future->done;
}

sub close_stream {
    my ( $self, $stream ) = @_;
    $stream->close_when_empty();
}

sub handle_stream_error {
    my ( $self, $stream ) = @_;
    warn "Application error: @_";
    $self->close_stream($stream);
}

1;
