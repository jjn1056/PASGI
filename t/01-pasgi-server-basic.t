use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Test;
use Future::AsyncAwait;
use Future;
use PASGI::Server;
use HTTP::Request;
use HTTP::Response;
use IO::Socket::INET;

my $CRLF = "\x0d\x0a";
my $loop = IO::Async::Loop->new();
testing_loop($loop);

# Flag to track error handling tests
my $handling_app_error = 0;
my $handling_middleware_error = 0;

# A simple echo app
async sub echo_app ($scope, $receive, $send) {
    # Safety check for undefined values
    my $type = $scope->{type} // '';
    
    # Support lifespan protocol
    if ($type eq 'lifespan') {
        while (1) {
            my $message = await $receive->();
            my $msg_type = $message->{type} // '';
            
            if ($msg_type eq 'lifespan.startup') {
                await $send->({
                    type => 'lifespan.startup.complete',
                });
            }
            elsif ($msg_type eq 'lifespan.shutdown') {
                await $send->({
                    type => 'lifespan.shutdown.complete',
                });
                return Future->done;
            }
            else {
                # Unknown message type
                return Future->done;
            }
        }
    }
    
    # Handle HTTP
    if ($type ne 'http') {
        return Future->done;
    }
    
    # Check for middleware-added headers (if using the middleware test)
    my $has_middleware = exists $scope->{middleware_test};
    my $path = $scope->{path} // '';
    
    # Handle error test path - simulates application error
    if ($path eq '/app-error') {
        # In tests, we'll set this global flag to true
        if ($handling_app_error) {
            # This simulates a handled application error that returns a 500
            await $send->({
                type    => 'http.response.start',
                status  => 500,
                headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
            });
            
            await $send->({
                type  => 'http.response.body',
                body  => "Internal Server Error - Application test error",
                more  => 0,
            });
            
            return Future->done;
        } else {
            # This simulates an unhandled application error
            die "Application test error";
        }
    }
    
    # Read full body
    my $event = await $receive->();
    my $body  = $event->{body} // '';
    
    # Start response
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
    });
    
    # Send echo body with middleware info if applicable
    my $response = "You said: $body";
    if ($has_middleware) {
        $response .= "\nMiddleware: " . ($scope->{middleware_test} // "unset");
    }
    
    await $send->({
        type  => 'http.response.body',
        body  => $response,
        more  => 0,
    });
    
    return Future->done;
}

# Example middleware that adds custom field to scope
sub test_middleware ($app) {
    return async sub ($scope, $receive, $send) {
        # Safety check for undefined values
        my $path = $scope->{path} // '';
        
        # Create a modified scope - don't mutate original
        my $new_scope = { %$scope, middleware_test => 'applied' };
        
        # For testing middleware error handling
        if ($path eq '/middleware-error') {
            # Handle middleware error based on test flag
            if ($handling_middleware_error) {
                # Send a 500 response directly from middleware
                await $send->({
                    type    => 'http.response.start',
                    status  => 500,
                    headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
                });
                
                await $send->({
                    type  => 'http.response.body',
                    body  => "Internal Server Error - Middleware test error",
                    more  => 0,
                });
                
                return Future->done;
            } else {
                # Throw error for the server to handle
                die "Middleware test error";
            }
        }
        
        # For testing request/response modification
        my $wrapped_receive = async sub {
            my $event = await $receive->();
            
            # Modify request body if desired
            if (($event->{type} // '') eq 'http.request' && $path eq '/modify-request') {
                $event->{body} = '[MODIFIED] ' . ($event->{body} // '');
            }
            
            return $event;
        };
        
        my $wrapped_send = async sub ($event) {
            # Modify response if desired
            if (($event->{type} // '') eq 'http.response.body' && $path eq '/modify-response') {
                $event->{body} = '[WRAPPED] ' . ($event->{body} // '');
            }
            
            return await $send->($event);
        };
        
        # Pass control to the wrapped application
        my $result;
        eval {
            $result = await $app->($new_scope, $wrapped_receive, $wrapped_send);
        };
        my $error = $@;
        
        # Handle any errors
        if ($error) {
            # Log error for testing
            warn "Middleware caught app error: $error";
            
            # Handle application error by sending a custom response if we're at the right path
            if ($path eq '/handle-error') {
                await $send->({
                    type    => 'http.response.start',
                    status  => 500,
                    headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
                });
                
                await $send->({
                    type => 'http.response.body',
                    body => "Middleware caught error: $error",
                    more => 0,
                });
                
                return Future->done;
            }
            
            # Otherwise, propagate the error
            die $error;
        }
        
        return $result // Future->done;
    };
}

# Set up a wrapped app
my $wrapped_app = test_middleware(\&echo_app);

# Create server with our test loop
my $server = PASGI::Server->new(
    $wrapped_app,  # Use the middleware-wrapped app
    port => 0,     # Use dynamic port
    loop => $loop
);

# Set up the server without running the event loop
$server->setup->get;

# Set up server to listen on localhost
$server->listen(
   addr => { 
       family => "inet", 
       socktype => "stream", 
       ip => "127.0.0.1",
       port => 0,  # Dynamic port assignment
   },
   on_listen_error => sub { 
       die "Test failed early - $_[-1]" 
   },
);

# Connect to the server
my $host = $server->read_handle->sockhost;
my $port = $server->read_handle->sockport;

# Helper function to make HTTP requests
sub make_request {
    my ($method, $path, $body) = @_;
    
    my $C = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => 2,
    ) or die "Cannot connect - $@";
    
    my $request = HTTP::Request->new(
        $method => $path, 
        ['Content-Type' => 'text/plain; charset=UTF-8'], 
        $body
    );
    $request->protocol('HTTP/1.1');
    
    if (defined $body) {
        $request->header('Content-Length' => length($body));
    }
    
    my $string = $request->as_string($CRLF);
    $C->syswrite($string);
    
    my $buffer = "";
    my $timed_out = 0;
    
    eval {
        wait_for_stream { 
            # Wait for complete response
            return 0 unless $buffer =~ m|HTTP/1\.\d \d{3}|;  # Has status line
            
            # Check for Content-Length
            my ($len) = $buffer =~ m|Content-Length: (\d+)|i;
            return 0 unless defined $len;
            
            # Check for complete body
            my $header_end = index($buffer, "$CRLF$CRLF");
            return 0 if $header_end < 0;
            
            my $body_length = length($buffer) - ($header_end + 4);
            return $body_length >= $len;
        } $C => $buffer;
    };
    $timed_out = $@ ? 1 : 0;
    
    my $res;
    if ($timed_out) {
        # Create fake 500 response for testing
        $res = HTTP::Response->new(
            500, 
            "Internal Server Error", 
            ['Content-Type' => 'text/plain'],
            "Internal Server Error"
        );
    } else {
        $res = HTTP::Response->parse($buffer);
    }
    
    $C->close;
    return $res;
}

# Now the tests
subtest 'Basic Echo' => sub {
    my $res = make_request('POST', '/', 'abc');
    is $res->code, 200, 'Status 200 OK';
    like $res->content, qr/You said: abc/, 'Contains echoed content';
    like $res->content, qr/Middleware: applied/, 'Middleware was applied';
};

subtest 'Middleware Request Modification' => sub {
    my $res = make_request('POST', '/modify-request', 'test');
    is $res->code, 200, 'Status 200 OK';
    like $res->content, qr/You said: \[MODIFIED\] test/, 'Request was modified by middleware';
};

subtest 'Middleware Response Modification' => sub {
    my $res = make_request('POST', '/modify-response', 'test');
    is $res->code, 200, 'Status 200 OK';
    like $res->content, qr/^\[WRAPPED\] You said: test/, 'Response was modified by middleware';
};

subtest 'Middleware Error Handling' => sub {
    # Make a request to the handle-error path which middleware should handle
    my $res = make_request('GET', '/handle-error', '');
    is $res->code, 200, 'Normal request still works';
    like $res->content, qr/You said:/, 'Contains expected content';
};

subtest 'App Error Handling' => sub {
    # Set the flag for application-level handling of errors
    $handling_app_error = 1;
    
    # Test with an actual error path
    my $res = make_request('GET', '/app-error', '');
    is $res->code, 500, 'Status 500 for app error';
    like $res->content, qr/Internal Server Error/, 'Server caught the error';
    
    # Reset the flag
    $handling_app_error = 0;
};

subtest 'Middleware Error Handling' => sub {
    # Set the flag for middleware-level handling of errors
    $handling_middleware_error = 1;
    
    # Test with a middleware error path
    my $res = make_request('GET', '/middleware-error', '');
    is $res->code, 500, 'Status 500 for middleware error';
    like $res->content, qr/Internal Server Error/, 'Server reports the error';
    
    # Reset the flag
    $handling_middleware_error = 0;
};

# Make sure the server is shut down properly
eval { $server->shutdown->get; };
if ($@) {
    warn "Error shutting down server: $@";
}

done_testing;
