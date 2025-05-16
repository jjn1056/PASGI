use v5.36;
use feature 'signatures';
no warnings 'experimental::signatures';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Test;
use Future::AsyncAwait;
use Future;
use PASGI::Server;
use IO::Socket::INET;

my $CRLF = "\x0d\x0a";
my $loop = IO::Async::Loop->new();
testing_loop($loop);

# App that demonstrates streaming request body handling
async sub streaming_app ($scope, $receive, $send) {

    warn 11111;

    die "Unsupported protocol type: @{[ $scope->{type} ]}" 
        unless $scope->{type} eq 'http';

    my @body_chunks;
    my $total_length = 0;
    
    # Collect all body chunks
    while (1) {
        my $event = await $receive->();
        last if $event->{type} eq 'http.disconnect';
        
        if ($event->{type} eq 'http.request') {
            push @body_chunks, $event->{body};
            $total_length += length($event->{body});
            last unless $event->{more};
        }
    }
    
    # Send response
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });
    
    await $send->({
        type => 'http.response.body',
        body => "Received " . scalar(@body_chunks) . " chunks, total length: $total_length",
        more => 0,
    });
}

# Create server
my $server = PASGI::Server->new(
    \&streaming_app,
    port => 0,
    loop => $loop,
);

# Set up the server without running the event loop
$server->setup->get;

$server->listener->listen(
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
my $host = $server->listener->read_handle->sockhost;
my $port = $server->listener->read_handle->sockport;

subtest 'Streaming Request Body' => sub {
    my $socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => 2,
    ) or die "Cannot connect: $@";
    
    # Send request with chunked transfer encoding
    my $request_headers = join($CRLF,
        "POST /test HTTP/1.1",
        "Host: localhost:$port",
        "Transfer-Encoding: chunked",
        "Content-Type: text/plain",
        "",
        ""
    );
    
    $socket->syswrite($request_headers);
    warn 2222;
    # Send chunked body
    my @chunks = ("Hello ", "streamed ", "world!");
    for my $chunk (@chunks) {
        warn 3333;
        my $chunk_size = sprintf("%x", length($chunk));
        $socket->syswrite("$chunk_size$CRLF$chunk$CRLF");
        sleep 0.1; # Small delay to ensure chunks are separate
    }
    
    # End chunks
    $socket->syswrite("0$CRLF$CRLF");
    warn 4444;
    # Read response
    my $response_buffer = "";
    while (my $bytes_read = $socket->sysread(my $buffer, 4096)) {
        warn 5555;
        $response_buffer .= $buffer;
        last if $response_buffer =~ /$CRLF$CRLF/;
    }
    
    # Read response body
    if ($response_buffer =~ /Content-Length: (\d+)/i) {
        my $content_length = $1;
        my $current_body_length = 0;
        
        if ($response_buffer =~ /$CRLF$CRLF(.*)$/s) {
            $current_body_length = length($1);
        }
        
        while ($current_body_length < $content_length) {
            my $bytes_read = $socket->sysread(my $buffer, $content_length - $current_body_length);
            last unless $bytes_read;
            $response_buffer .= $buffer;
            $current_body_length += $bytes_read;
        }
    }
    
    $socket->close;
    
    # Check response
    like $response_buffer, qr/HTTP\/1\.1 200 OK/, 'Got 200 response';
    like $response_buffer, qr/Received \d+ chunks/, 'Response mentions chunks';
    like $response_buffer, qr/total length: \d+/, 'Response mentions total length';
};

subtest 'Large Request Body' => sub {
    my $socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => 5,
    ) or die "Cannot connect: $@";
    
    # Create a large body (larger than typical buffer size)
    my $large_body = "X" x 10000;
    
    my $request = join($CRLF,
        "POST /large HTTP/1.1",
        "Host: localhost:$port",
        "Content-Type: text/plain",
        "Content-Length: " . length($large_body),
        "",
        $large_body
    );
    
    $socket->syswrite($request);
    
    # Read response
    my $response_buffer = "";
    while (my $bytes_read = $socket->sysread(my $buffer, 4096)) {
        $response_buffer .= $buffer;
        last if $response_buffer =~ /$CRLF$CRLF.*total length: \d+/s;
    }
    
    $socket->close;
    
    # Check response
    like $response_buffer, qr/HTTP\/1\.1 200 OK/, 'Got 200 response for large body';
    like $response_buffer, qr/total length: 10000/, 'Received full large body';
};

# Cleanup
eval { $server->shutdown->get; };

done_testing;