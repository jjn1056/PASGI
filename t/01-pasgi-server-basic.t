use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Test;
use Future::AsyncAwait;
use PASGI::Server;
use HTTP::Request;
use HTTP::Response;
use IO::Socket::INET;

my $CRLF = "\x0d\x0a";
my $loop = IO::Async::Loop->new();
testing_loop($loop);

# A simple echo app
async sub echo_app ($scope, $receive, $send) {
    # Support lifespan protocol
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $message = await $receive->();
            
            if ($message->{type} eq 'lifespan.startup') {
                await $send->({
                    type => 'lifespan.startup.complete',
                });
            }
            elsif ($message->{type} eq 'lifespan.shutdown') {
                await $send->({
                    type => 'lifespan.shutdown.complete',
                });
                return;
            }
            else {
                # Unknown message type
                return;
            }
        }
    }
    
    # Handle HTTP
    return unless $scope->{type} eq 'http';
    
    # Read full body
    my $event = await $receive->();
    my $body  = $event->{body} // '';
    
    # Start response
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
    });
    
    # Send echo body
    await $send->({
        type  => 'http.response.body',
        body  => "You said: $body",
        more  => 0,
    });
}

# Create server with our test loop
my $server = PASGI::Server->new(
    \&echo_app, 
    port => 0,  # Use dynamic port
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

my $C = IO::Socket::INET->new(
   PeerHost => $host,
   PeerPort => $port,
) or die "Cannot connect - $@";

subtest 'Basic Echo' => sub {
    my $request = HTTP::Request->new(
        POST => '/', 
        ['Content-Type' => 'text/plain; charset=UTF-8', 'Content-Length' => 3], 
        "abc"
    );
    $request->protocol('HTTP/1.1');
    
    my $string = $request->as_string($CRLF);
    $C->syswrite($string);
    
    my $buffer = "";
    wait_for_stream { length $buffer >= length "You said: abc" } $C => $buffer;
    
    ok my $res = HTTP::Response->parse($buffer);
    is $res->content, 'You said: abc';
};

# Clean up - important to trigger lifespan.shutdown
$server->shutdown->get;

done_testing;
