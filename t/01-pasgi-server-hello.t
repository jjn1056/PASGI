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


# A simple echo app
async sub helloworld_app ($scope, $receive, $send) {

  die "Invalid scope type" if $scope->{type} ne 'http';

  await $send->({
      type    => 'http.response.start',
      status  => 200,
      headers => [[ 'content-type', 'text/plain; charset=utf-8' ]],
  });
  
  await $send->({
      type  => 'http.response.body',
      body  => 'Hello ',
      more  => 1,
  });

  await $send->({
      type  => 'http.response.body',
      body  => 'World!',
      more  => 0,
  });

}

# Setup
my $CRLF = "\x0d\x0a";
my $loop = IO::Async::Loop->new();
testing_loop($loop);

# Create server with our test loop
my $server = PASGI::Server->new(
    \&helloworld_app,  # Use the middleware-wrapped app
    port => 0,     # Use dynamic port
    loop => $loop,
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
subtest 'Hello World' => sub {
    my $res = make_request('GET', '/');
    is $res->code, 200, 'Status 200 OK';
    like $res->content, qr/Hello World!/, 'Contains expected content';
};

done_testing;
