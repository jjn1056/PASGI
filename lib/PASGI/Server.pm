package PASGI::Server;
use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Listener;
use IO::Async::Stream;
use Future;
use HTTP::Parser::XS qw(parse_http_request);
use Encode qw(decode_utf8);

# Clean configuration
my @VALID_CONFIG_KEYS = qw(
    host port unix_socket backlog
    ssl_cert ssl_key ssl_ca
    root_path
    timeout worker_timeout
    keepalive_timeout
    max_request_size
    debug
    loop
);

sub new ($class, $app, %config) {
    # Validate config
    for my $key (keys %config) {
        unless (grep { $_ eq $key } @VALID_CONFIG_KEYS) {
            warn "Unknown config key: $key";
        }
    }
    
    # Set defaults
    %config = (
        host => '127.0.0.1',
        port => 8080,
        backlog => 100,
        timeout => 30,
        keepalive_timeout => 5,
        max_request_size => 16 * 1024 * 1024, # 16MB
        debug => 0,
        %config,
    );
    
    my $self = bless {
        app => $app,
        config => \%config,
        state => {},
        loop => $config{loop} // IO::Async::Loop->new,
        listener => undef,
        _started => 0,
        _shutdown_future => undef,
    }, $class;
    
    return $self;
}

sub loop { shift->{loop} }
sub config { shift->{config} }

# Main entry point - handles everything
async sub serve ($self) {
    await $self->bind() unless $self->{_started};
    
    # Set up signal handlers
    $self->_setup_signal_handlers();
    
    if ($self->config->{debug}) {
        my $config = $self->config;
        my $addr = $config->{unix_socket} // "$config->{host}:$config->{port}";
        warn "PASGI server listening on $addr";
    }
    
    # Create shutdown future for clean stopping
    $self->{_shutdown_future} = Future->new;
    
    # Wait for shutdown
    await $self->{_shutdown_future};
}

# For testing without running the event loop
async sub bind ($self) {
    return $self if $self->{_started};
    
    # Create listener
    $self->{listener} = IO::Async::Listener->new(
        on_stream => sub ($listener, $stream) {
            $self->_handle_connection($stream);
        },
    );
    
    # Add listener to loop
    $self->loop->add($self->{listener});
    
    # Trigger lifespan startup
    await $self->_handle_lifespan_startup();
    
    # Start listening
    my $config = $self->config;
    
    if ($config->{unix_socket}) {
        # Unix socket
        await $self->{listener}->listen(
            addr => {
                family => "unix",
                socktype => "stream",
                path => $config->{unix_socket},
            },
            on_listen_error => sub ($listener, $errno, $errstr) {
                die "Listen error: $errstr";
            },
        );
    } else {
        # TCP socket - use 'ip' not 'host'!
        await $self->{listener}->listen(
            addr => {
                family => "inet",
                socktype => "stream",
                ip => $config->{host},
                port => $config->{port},
            },
            on_listen_error => sub ($listener, $errno, $errstr) {
                die "Listen error: $errstr";
            },
        );
    }
    
    $self->{_started} = 1;
    return $self;
}

# Get bound address (useful for tests with port 0)
sub bound_address ($self) {
    return unless $self->{listener};
    my $socket = $self->{listener}->read_handle;
    return {
        host => $socket->sockhost,
        port => $socket->sockport,
        family => $socket->sockdomain,
    };
}

# Clean shutdown
async sub shutdown ($self) {
    return unless $self->{_started};
    
    # Stop accepting new connections
    $self->{listener}->close if $self->{listener};
    
    # Handle lifespan shutdown
    await $self->_handle_lifespan_shutdown();
    
    # Complete shutdown
    $self->{_shutdown_future}->done if $self->{_shutdown_future};
    $self->{_started} = 0;
}

sub _setup_signal_handlers ($self) {
    $self->loop->watch_signal(TERM => sub { $self->shutdown() });
    $self->loop->watch_signal(INT => sub { $self->shutdown() });
}

# Handle lifespan.startup event
async sub _handle_lifespan_startup ($self) {
    my %scope = (
        type  => 'lifespan',
        pasgi => { version => '0.1', spec_version => '0.1' },
        state => $self->{state},
    );
    
    my @events = ({ type => 'lifespan.startup' });
    
    my $receive = async sub {
        shift @events;
    };
    
    my $send = async sub ($event) {
        if ($event->{type} eq 'lifespan.startup.complete') {
            return;
        }
        elsif ($event->{type} eq 'lifespan.startup.failed') {
            my $message = $event->{message} // 'Application startup failed';
            die "Lifespan startup error: $message";
        }
    };
    
    eval { await $self->{app}->(\%scope, $receive, $send) } || do {
        my $error = $@;
        warn "Note: Application doesn't support lifespan protocol: $error"
            if $self->config->{debug};
        $self->{_no_lifecycle_support} = 1;
    };
}

# Handle lifespan.shutdown event
async sub _handle_lifespan_shutdown ($self) {
    return if $self->{_no_lifecycle_support};
    
    my %scope = (
        type  => 'lifespan',
        pasgi => { version => '0.1', spec_version => '0.1' },
        state => $self->{state},
    );
    
    my @events = ({ type => 'lifespan.shutdown' });
    
    my $receive = async sub {
        shift @events;
    };
    
    my $send = async sub ($event) {
        if ($event->{type} eq 'lifespan.shutdown.complete') {
            return;
        }
        elsif ($event->{type} eq 'lifespan.shutdown.failed') {
            my $message = $event->{message} // 'Application shutdown failed';
            warn "Lifespan shutdown error: $message";
        }
    };
    
    my $f = Future->new;
    eval {
        $f = $self->{app}->(\%scope, $receive, $send);
        await $f;
    } or do {
        my $error = $@;
        warn "Note: Application doesn't handle lifespan shutdown: $error"
            if $self->config->{debug};
    };
    
    return $f;
}

# Handle a new connection
async sub _handle_connection ($self, $stream) {
    # Set up connection handler
    $stream->configure(
        on_read => sub ($stream, $buffer, $eof) {
            $self->_handle_connection_data($stream, $buffer, $eof);
        },
        on_read_eof => sub ($stream) {
            # Connection closed by client
        },
    );
    
    # Add to loop
    $self->loop->add($stream);
    
    # Initialize connection state
    $stream->{pasgi_state} = {
        buffer => '',
        parsing_headers => 1,
        request => undef,
        content_length => 0,
        body_received => 0,
        chunked => 0,
        app_future => undef,
        receive_queue => [],
        disconnected => 0,
    };
}

# Handle incoming data on a connection
sub _handle_connection_data ($self, $stream, $buffer, $eof) {
    my $state = $stream->{pasgi_state};
    $state->{buffer} .= $$buffer;  # ACTUALLY DEREFERENCE THE BUFFER!!!
    
    # Handle disconnection
    if ($eof) {
        $state->{disconnected} = 1;
        if ($state->{app_future} && !$state->{app_future}->is_ready) {
            # Push disconnect event if app is still running
            push @{$state->{receive_queue}}, { type => 'http.disconnect' };
        }
        return;
    }
    
    # Parse headers if we haven't yet
    if ($state->{parsing_headers}) {
        my $header_end = index($state->{buffer}, "\r\n\r\n");
        return if $header_end < 0; # Need more data
        
        my $header_data = substr($state->{buffer}, 0, $header_end);
        $state->{buffer} = substr($state->{buffer}, $header_end + 4);
        
        # Parse HTTP request line and headers
        my %headers;
        my ($method, $path, $version) = $self->_parse_request_line($header_data, \%headers);
        return unless $method; # Invalid request
        
        $state->{request} = {
            method => $method,
            path => $path,
            version => $version,
            headers => \%headers,
        };
        
        # Check for Content-Length or Transfer-Encoding
        my $content_length = $headers{'content-length'};
        my $transfer_encoding = $headers{'transfer-encoding'} || '';
        
        if ($transfer_encoding =~ /chunked/i) {
            $state->{chunked} = 1;
        } elsif (defined $content_length) {
            $state->{content_length} = $content_length;
        }
        
        $state->{parsing_headers} = 0;
        
        # Start handling the request
        $state->{app_future} = $self->_handle_http_request($stream);
    }
    
    # Handle body data (simplified non-chunked)
    if (!$state->{parsing_headers} && !$state->{chunked}) {
        my $remaining = $state->{content_length} - $state->{body_received};
        
        if (length($state->{buffer}) > 0 && $remaining > 0) {
            my $chunk_size = $remaining < length($state->{buffer}) ? $remaining : length($state->{buffer});
            my $chunk = substr($state->{buffer}, 0, $chunk_size);
            $state->{buffer} = substr($state->{buffer}, $chunk_size);
            $state->{body_received} += $chunk_size;
            
            my $more = $state->{body_received} < $state->{content_length} ? 1 : 0;
            
            # Push body chunk to receive queue
            push @{$state->{receive_queue}}, {
                type => 'http.request',
                body => $chunk,
                more => $more,
            };
        }
    }
}

# Parse HTTP request line and headers
sub _parse_request_line ($self, $header_data, $headers) {
    my @lines = split(/\r\n/, $header_data);
    my $request_line = shift @lines;
    
    # Parse request line: METHOD PATH HTTP/VERSION
    my ($method, $path, $version) = split(/\s+/, $request_line, 3);
    return unless $method && $path && $version;
    
    # Extract version number
    ($version) = $version =~ m{HTTP/(.+)};
    
    # Parse headers
    for my $line (@lines) {
        my ($name, $value) = split(/:\s*/, $line, 2);
        next unless defined $name && defined $value;
        $headers->{lc($name)} = $value;
    }
    
    return ($method, $path, $version);
}

# Handle HTTP request with PASGI app
async sub _handle_http_request ($self, $stream) {
    my $state = $stream->{pasgi_state};
    my $req = $state->{request};
    my $config = $self->config;
    
    # Extract connection info
    my $client_host = $stream->read_handle->peerhost // '127.0.0.1';
    my $client_port = $stream->read_handle->peerport // 0;
    my $server_host = $stream->read_handle->sockhost // '0.0.0.0';
    my $server_port = $stream->read_handle->sockport // $config->{port};
    
    # Parse URL components
    my ($path, $query_string) = split(/\?/, $req->{path}, 2);
    $query_string //= '';
    
    # Build PASGI scope
    my %scope = (
        type         => 'http',
        method       => $req->{method},
        path         => decode_utf8($path, Encode::FB_CROAK),
        query_string => $query_string,
        headers      => [
            map { [lc($_), $req->{headers}{lc($_)}] } 
            keys %{$req->{headers}}
        ],
        pasgi        => { version => '0.1', spec_version => '0.1' },
        http_version => $req->{version},
        scheme       => ($config->{ssl_cert} ? 'https' : 'http'),
        root_path    => $config->{root_path} // '',
        client       => [$client_host, $client_port],
        server       => [$server_host, $server_port],
        state        => $self->{state},
    );
    
    # Add initial empty body event if no body expected
    if (!exists $req->{headers}{'content-length'} && 
        !($req->{headers}{'transfer-encoding'} && $req->{headers}{'transfer-encoding'} =~ /chunked/i)) {
        push @{$state->{receive_queue}}, {
            type => 'http.request',
            body => '',
            more => 0,
        };
    }
    
    # Create receive callback
    my $receive = async sub {
        while (!@{$state->{receive_queue}} && !$state->{disconnected}) {
            # Wait a bit for more data
            await $self->loop->delay_future(after => 0.001);
        }
        
        return shift @{$state->{receive_queue}} // { type => 'http.disconnect' };
    };
    
    # Create HTTP compliant send callback with chunked encoding support
    my $response_started = 0;
    my $is_chunked = 0;
    
    my $send = async sub ($event) {
        if ($event->{type} eq 'http.response.start') {
            my $status = $event->{status} // 200;
            my @response_headers = @{$event->{headers} // []};
            
            # Store headers but don't send yet - we need to see if it's streaming
            $state->{response_status} = $status;
            $state->{response_headers} = \@response_headers;
            $response_started = 1;
        }
        elsif ($event->{type} eq 'http.response.body') {
            if (!$response_started) {
                die "Must send http.response.start before http.response.body";
            }
            
            my $body = $event->{body} // '';
            
            # On first body chunk, determine response mode and send headers
            unless ($state->{headers_sent}) {
                my @headers = @{$state->{response_headers}};
                
                if ($event->{more}) {
                    # Streaming response - use chunked encoding
                    push @headers, ['transfer-encoding', 'chunked'];
                    $is_chunked = 1;
                } else {
                    # Single response - use content-length
                    push @headers, ['content-length', length($body)];
                }
                
                # Send status line and headers
                my $response = "HTTP/$req->{version} $state->{response_status} OK\r\n";
                for my $header (@headers) {
                    $response .= "$header->[0]: $header->[1]\r\n";
                }
                $response .= "\r\n";
                $stream->write($response);
                $state->{headers_sent} = 1;
            }
            
            # Send body
            if ($is_chunked) {
                if (length($body) > 0) {
                    # Send chunk: hex-length + CRLF + data + CRLF
                    my $chunk_size = sprintf("%x", length($body));
                    $stream->write("$chunk_size\r\n$body\r\n");
                }
                
                # Send final chunk if done
                unless ($event->{more}) {
                    $stream->write("0\r\n\r\n");  # End chunked encoding
                    $stream->close_when_empty;
                }
            } else {
                # Non-chunked response (single body)
                $stream->write($body);
                $stream->close_when_empty unless $event->{more};
            }
        }
    };
    
    # Invoke the application
    eval {
        await $self->{app}->(\%scope, $receive, $send);
    } or do {
        my $error = $@;
        warn "Application error: $error" if $config->{debug};
        
        # Send 500 response if none sent yet
        unless ($response_started) {
            my $error_response = "HTTP/$req->{version} 500 Internal Server Error\r\n" .
                                "Content-Type: text/plain\r\n" .
                                "Content-Length: 21\r\n" .
                                "\r\n" .
                                "Internal Server Error";
            $stream->write($error_response);
            $stream->close_when_empty;
        }
    };
}

# Factory function for common use cases  
package PASGI {
    # Works in both sync and async contexts
    sub run ($app, %config) {
        my $server = PASGI::Server->new($app, %config);
        return $server->serve;  # Return the Future - caller decides blocking vs async
    }
}

1;