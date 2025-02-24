package PASGI::Server;

use strict;
use warnings;
use IO::Async::Loop;
use IO::Async::Listener;
use IO::Async::Stream;
use Future;

sub new {
    my ($class, %args) = @_;
    my $self = {
        app  => $args{app}  || sub { die "No ASGI app provided" },
        host => $args{host} || '127.0.0.1',
        port => $args{port} || 8080,
        loop => IO::Async::Loop->new,
    };
    bless $self, $class;
    return $self;
}

sub start {
    my ($self) = @_;
    my $app = $self->{app};

    my $listener = IO::Async::Listener->new(
        on_stream => sub {
            my ($listener, $stream) = @_;
            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;
                    if ($eof) {
                        $stream->close_when_empty();
                        return 0;
                    }
                    # Very basic HTTP GET parsing.
                    if ($$buffref =~ m/^GET\s+([^\s]+)\s+HTTP\/1\.1/) {
                        my $path = $1;
                        # Build a minimal ASGI scope.
                        my $scope = {
                            type   => 'http',
                            method => 'GET',
                            path   => $path,
                        };
                        # Dummy $receive callback.
                        my $receive = sub { return Future->done };
                        # $send callback writes response events back to the client.
                        my $send = sub {
                            my (%event) = @_;
                            if ($event{type} eq 'http.response.start') {
                                my $status = $event{status} // 200;
                                $stream->write("HTTP/1.1 $status OK\r\n");
                                for my $header (@{ $event{headers} // [] }) {
                                    $stream->write("$header->[0]: $header->[1]\r\n");
                                }
                                $stream->write("\r\n");
                            }
                            elsif ($event{type} eq 'http.response.body') {
                                $stream->write($event{body});
                            }
                            return Future->done;
                        };
                        # Invoke the ASGI application.
                        $app->($scope, $receive, $send)
                            ->on_done(sub { $stream->close_when_empty() })
                            ->on_fail(sub { warn "Application error: @_"; $stream->close_when_empty() });
                    }
                    $$buffref = '';  # Clear the buffer.
                    return 0;
                },
            );
            $self->{loop}->add($stream);
        },
    );

    # Add the listener to the loop before calling listen.
    $self->{loop}->add($listener);
    $self->{listener} = $listener;

    $listener->listen(
        addr => { family => "inet", socktype => "stream", port => $self->{port}, ip => $self->{host} },
        on_listen_error => sub { die "Cannot listen on port $self->{port} - $!" },
    );

    print "PASGI Server running on http://$self->{host}:$self->{port}/\n";
    $self->{loop}->run;
}

sub stop {
    my ($self) = @_;
    $self->{loop}->stop;
}

1;
