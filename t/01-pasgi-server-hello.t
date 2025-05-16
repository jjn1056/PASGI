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
use HTTP::Parser;

# A simple hello world app
async sub helloworld_app ($scope, $receive, $send) {
    die "Invalid scope type" unless $scope->{type} eq 'http';

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

# Create server with our test loop - much simpler now!
my $server = PASGI::Server->new(
    \&helloworld_app,
    host => '127.0.0.1',
    port => 0,     # Use dynamic port
    debug => 1,
    loop => $loop,
);

# Bind server without running the event loop
$server->bind->get;

# Get the actual bound address
my $bound = $server->bound_address;
my $host = $bound->{host};
my $port = $bound->{port};

# Helper function to make HTTP requests
sub make_request {
    my ($method, $path, $body) = @_;
    
    my $socket = IO::Socket::INET->new(
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
    $socket->syswrite($string);
    
    # Read the complete response
    my $response_data = '';
    eval {
        wait_for_stream { 
            # Read until we have complete headers
            return 0 unless $response_data =~ m|HTTP/1\.\d \d{3}|;  # Has status line
            return 0 unless $response_data =~ m|\r\n\r\n|;          # Has complete headers
            
            # Check if it's chunked or has content-length
            my ($chunked) = $response_data =~ m|Transfer-Encoding:\s*chunked|i;
            my ($content_len) = $response_data =~ m|Content-Length:\s*(\d+)|i;
            
            if ($chunked) {
                # For chunked responses, wait for the final "0\r\n\r\n"
                return $response_data =~ m|\r\n0\r\n\r\n|;
            } elsif (defined $content_len) {
                # For content-length responses, check we have enough data
                my $header_end = index($response_data, "\r\n\r\n");
                my $body_length = length($response_data) - ($header_end + 4);
                return $body_length >= $content_len;
            } else {
                # No explicit length - assume complete when headers done
                # (This handles cases where server closes connection)
                return 1;
            }
        } $socket => $response_data;
    };
    
    # Continue reading until connection closes (for non-chunked responses without content-length)
    unless ($response_data =~ m|Transfer-Encoding:\s*chunked|i || $response_data =~ m|Content-Length:|i) {
        while (my $bytes_read = $socket->sysread(my $more_data, 4096)) {
            $response_data .= $more_data;
        }
    }
    
    $socket->close;
    
    # Parse with HTTP::Response - this handles chunked encoding automatically!

    my $parser = HTTP::Parser->new(response => 1);
    $parser->add($response_data);
    my $response = $parser->object;

    
    # If parsing failed, create a basic response
    unless ($response) {
        $response = HTTP::Response->new(
            500, 
            "Parse Error", 
            ['Content-Type' => 'text/plain'],
            "Failed to parse response"
        );
    }
    
    return $response;
}

# Now the tests
subtest 'Hello World with Streaming' => sub {
    my $res = make_request('GET', '/');
    is $res->code, 200, 'Status 200 OK';
    is $res->content, 'Hello World!', 'Contains expected streaming content';
    is $res->header('Content-Type'), 'text/plain; charset=utf-8', 'Correct content type';
};

# Clean shutdown
$server->shutdown->get;

done_testing;