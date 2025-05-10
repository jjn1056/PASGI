package PASGI::Server;
use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP::Server;
use HTTP::Response;
use Future;

# Constructor: takes a PASGI app coderef and options (e.g., port)
sub new ($class, $app, %params) {
    my $self = bless {
        app => $app,
        params => \%params,
        state => {}, # Shared state for lifespan
        loop => $params{loop} // IO::Async::Loop->new,
        server => undef, # Will be initialized in setup()
    }, $class;
    
    # Create the server
    $self->{server} = Net::Async::HTTP::Server->new(
        on_request => sub ($server, $request) {
            $self->handle_request($request);
        },
    );
    
    return $self;
}

sub server { shift->{server} }
sub loop { shift->{loop} }

# Initialize the server (separate from running it)
async sub setup ($self) {
    # Add server to loop
    $self->loop->add($self->server);
    
    # Trigger lifespan startup
    await $self->handle_lifespan_startup();
    
    return $self;
}

# For testing: direct access to lower-level server methods
sub listen ($self, @args) {
    $self->server->listen(@args);
}

sub read_handle ($self) {
    $self->server->read_handle;
}

# Run the server (async)
async sub run ($self) {
    # Setup if not already done
    await $self->setup();
    
    # Listen on provided port (default 8080) with error handling
    my $port = $self->{params}{port} // 8080;
    $self->server->listen(
        addr => {
            family   => "inet6",
            socktype => "stream",
            port     => $port,
        },
        on_listen_error => sub ($listener, $errno, $errstr) {
            die "Failed to listen on port $port: $errstr";
        },
    );
    
    # Setup a signal handler for graceful shutdown
    $self->loop->watch_signal(TERM => sub {
        $self->handle_lifespan_shutdown()->get;
        $self->loop->stop;
    });
    
    # Start event loop
    await $self->loop->run;
}

# Shutdown the server gracefully
async sub shutdown ($self) {
    await $self->handle_lifespan_shutdown();
}

# Handle lifespan.startup event
async sub handle_lifespan_startup ($self) {
    my %scope = (
        type  => 'lifespan',
        pasgi => { version => '0.1', spec_version => '0.1' },
        state => $self->{state}, # Shared state namespace
    );
    
    my @events = ({ type => 'lifespan.startup' });
    
    my $receive = async sub {
        shift @events;
    };
    
    my $send = async sub ($event) {
        if ($event->{type} eq 'lifespan.startup.complete') {
            # Startup complete, continue
            return;
        }
        elsif ($event->{type} eq 'lifespan.startup.failed') {
            my $message = $event->{message} // 'Application startup failed';
            die "Lifespan startup error: $message";
        }
    };
    
    # Try to invoke the app with lifespan scope
    eval {
        await $self->{app}->(\%scope, $receive, $send);
    } or do {
        my $error = $@;
        # If the application doesn't support lifespan, just continue
        # This allows compatibility with apps that don't handle lifespan
        warn "Note: Application doesn't support lifespan protocol: $error";
    };
}

# Handle lifespan.shutdown event
async sub handle_lifespan_shutdown ($self) {
    my %scope = (
        type  => 'lifespan',
        pasgi => { version => '0.1', spec_version => '0.1' },
        state => $self->{state}, # Share the same state namespace
    );
    
    my @events = ({ type => 'lifespan.shutdown' });
    
    my $receive = async sub {
        shift @events;
    };
    
    my $send = async sub ($event) {
        if ($event->{type} eq 'lifespan.shutdown.complete') {
            # Shutdown complete, continue
            return;
        }
        elsif ($event->{type} eq 'lifespan.shutdown.failed') {
            my $message = $event->{message} // 'Application shutdown failed';
            warn "Lifespan shutdown error: $message";
        }
    };
    
    # Try to invoke the app with lifespan scope
    my $f = Future->new;
    eval {
        $f = $self->{app}->(\%scope, $receive, $send);
        await $f;
    } or do {
        my $error = $@;
        # If the application doesn't support lifespan, just continue
        warn "Note: Application doesn't handle lifespan shutdown: $error";
    };
    
    return $f;
}

# Internal: translate Net::Async request to PASGI and invoke app
async sub handle_request ($self, $request) {
    # Extract client information
    my $client_host = $request->stream->read_handle->peerhost // '127.0.0.1';
    my $client_port = $request->stream->read_handle->peerport // 0;
    
    # Extract server information
    my $server_host = $request->stream->read_handle->sockhost // '0.0.0.0';
    my $server_port = $request->stream->read_handle->sockport // 
                      ($self->{params}{port} // 8080);
    
    # Build PASGI scope
    my %scope = (
        type         => 'http',
        method       => $request->method,
        path         => $request->path,
        query_string => $request->query_string // '',
        headers      => [ map { [ lc($_), scalar $request->header($_) ] } $request->headers ],
        pasgi        => { version => '0.1', spec_version => '0.1' },
        # Add HTTP version - extract from request or default to 1.1
        http_version => (($request->protocol =~ m{HTTP/(\d\.\d)}i) ? $1 : '1.1'),
        # Add scheme (detect https if needed)
        scheme       => ($self->{params}{ssl} ? 'https' : 'http'),
        # Add root_path (for mounted applications)
        root_path    => $self->{params}{root_path} // '',
        # Add client information
        client       => [ $client_host, $client_port ],
        # Add server information
        server       => [ $server_host, $server_port ],
        # Add state from lifespan if supported
        state        => $self->{state},
    );
    
    # Prepare bodies
    my @events = (
        { type => 'http.request', body => ($request->body // ''), more => 0 }
    );
    
    # Capture request in a stable lexical for closure
    my $req = $request;
    
    # receive() callback closure
    my $receive = async sub {
        my $event = shift @events;
        # If no more events and the app calls receive again, 
        # return a disconnect event instead of undef
        return { type => 'http.disconnect' } unless $event;
        return $event;
    };
    
    # send() callback closure
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            my $status   = $event->{status} // 200;
            my @res_hdrs = map { @$_ } @{ $event->{headers} // [] };
            $req->{__res} = HTTP::Response->new($status, undef, [ @res_hdrs ]);
        }
        elsif ($event->{type} eq 'http.response.body') {
            $req->{__res}->add_content($event->{body} // '');
            $req->{__res}->content_length(length $req->{__res}->content);
            $req->respond($req->{__res}) unless $event->{more};
        }
    };
    
    # Invoke user app with closures and handle errors
    eval {
        await $self->{app}->(\%scope, $receive, $send);
    } or do {
        my $error = $@;
        warn "Application error: $error";
        # Send 500 response if none sent yet
        unless ($req->{__res}) {
            $req->respond(HTTP::Response->new(
                500, 
                "Internal Server Error",
                ['Content-Type' => 'text/plain'],
                "Internal Server Error"
            ));
        }
    };
}

1;
