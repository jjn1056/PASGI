package PASGI::Server;

use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP::Server;
use HTTP::Response;

# Constructor: takes a PASGI app coderef and options (e.g., port)
sub new ($class, $app, %params) {
    my $self;
    $self = bless {
      app => $app,
      params => \%params,
      server =>  Net::Async::HTTP::Server->new(
        on_request => sub ($server, $request) {
            $self->handle_request($request); 
        },
      ),
    }, $class;
    return $self;
}

sub server { shift->{server} }

# Run the server (async)
async sub run ($self) {
    my $loop = IO::Async::Loop->new;
    $loop->add($self->server);
    # Listen on provided port (default 8080) with error handling
    $self->server->listen(
        addr => {
          family   => "inet6",
          socktype => "stream",
          port     => 0 ? 8443 : 8080,
        },
        on_listen_error => sub ($listener, $errno, $errstr) {
            die "Failed to listen on port " . ($self->{params}{port} // 8080) . ": $errstr";
        },
    );
    # Start event loop
    await $loop->run;
}

# Internal: translate Net::Async request to PASGI and invoke app
async sub handle_request ($self, $request) {
    # Build PASGI scope
    my %scope = (
        type         => 'http',
        method       => $request->method,
        path         => $request->path,
        query_string => $request->query_string // '',
        headers      => [ map { [ lc($_), scalar $request->header($_) ] } $request->headers ],
        asgi         => { version => '0.1', spec_version => '0.1' },
    );

  # Prepare bodies: Right now Net::Async::HTTP::Server buffers the full body into
  # an instance of HTTP::Request, but in the end we'll need to be able to handle
  # streaming inputs.

  my @events = (
        { type => 'http.request', body => ($request->body // ''), more_body => 0 }
    );

    # Capture request in a stable lexical for closure
    my $req = $request;

    # receive() callback closure
    my $receive = async sub {
        shift @events;
    };

    # send() callback closure
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            my $status   = $event->{status} // 200;
            my @res_hdrs = map { @$_ } @{ $event->{headers} // [] };

            $req->{__res} = HTTP::Response->new($status, undef, [ @res_hdrs ]);
        }
        elsif ($event->{type} eq 'http.response.body') {
          $req->{__res}->add_content( $event->{body} );
          $req->{__res}->content_length( length $req->{__res}->content );

          $req->respond($req->{__res}) unless $event->{more_body};
        }
    };

    # Invoke user app with closures
    await $self->{app}->(\%scope, $receive, $send);
}

1;
